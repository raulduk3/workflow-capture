"""
L7S Workflow Analysis Pipeline - Orchestrator

Main entry point that wires all pipeline stages together:
  1. Load converted MP4 sessions from workflow_sessions.csv
  2. Skip already-processed/rejected videos
  3. For each new video:
     a. Parse filename → metadata
     b. Get duration/size via ffprobe
     c. Check duration bounds (5s - 1hr)
     d. Upload video to Gemini → two-pass analysis
     e. Check Pass 2 quality (automation score, SOP steps, etc.)
     f. If high quality: save markdown + append to CSV
     g. If low quality: move to _misrecordings
     h. Mark as processed or rejected
  4. Print summary

Usage:
    python run_pipeline.py                          # Process all users
    python run_pipeline.py --user rcrane             # Single user
    python run_pipeline.py --limit 5                 # Process max 5 videos
    python run_pipeline.py --dry-run                 # Preview only
    python run_pipeline.py --metadata-only           # Skip Gemini, just extract file metadata
    python run_pipeline.py --report                  # Generate insights report after processing
"""

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

from config import (
    API_CALL_DELAY_SECONDS,
    CONVERSION_CSV,
    MAX_VIDEO_DURATION_SEC,
    MIN_VIDEO_DURATION_SEC,
    MP4_DIR,
    OUTPUT_DIR,
)
from csv_manager import (
    append_row,
    build_row,
    ensure_output_dir,
    get_csv_stats,
    load_processed_ids,
    load_rejected_ids,
    mark_processed,
    mark_rejected,
    move_to_misrecordings,
    save_analysis_markdown,
    update_workflow_sessions_status,
)
from filename_parser import load_converted_sessions
from frame_extractor import get_video_metadata
from gemini_analyzer import analyze_video


def run_pipeline(args: argparse.Namespace) -> dict:
    """
    Execute the full analysis pipeline.

    Returns:
        Summary dict with counts: total, processed, skipped, failed, errors.
    """
    start_time = datetime.now()
    stats = {
        "total": 0,
        "processed": 0,
        "skipped": 0,
        "rejected": 0,  # Videos filtered out (too short, too long, not useful)
        "failed": 0,
        "errors": [],
    }

    # --- Pre-flight ---
    print("=" * 60)
    print("L7S Workflow Analysis Pipeline")
    print("=" * 60)
    print(f"Source:      {args.source}")
    print(f"Sessions:    {args.sessions_csv}")
    print(f"Output:      {OUTPUT_DIR}")
    if args.user:
        print(f"Filter:      user = {args.user}")
    if args.limit:
        print(f"Limit:       {args.limit} videos")
    if args.dry_run:
        print(f"Mode:        DRY RUN")
    if args.metadata_only:
        print(f"Mode:        METADATA ONLY (no Gemini)")
    print("=" * 60)

    # Ensure output directories exist
    if not args.dry_run:
        ensure_output_dir()

    # --- Stage 1: Discover videos ---
    print("\n[Stage 1] Loading converted sessions...")
    videos = load_converted_sessions(args.sessions_csv, single_user=args.user)
    stats["total"] = len(videos)

    if not videos:
        print("  No videos found.")
        return stats

    print(f"  Found {len(videos)} video(s)")

    # --- Load processing and rejected logs for dedup ---
    processed_ids = load_processed_ids()
    rejected_ids = load_rejected_ids()
    print(f"  Previously processed: {len(processed_ids)} video(s)")
    print(f"  Previously rejected: {len(rejected_ids)} video(s)")

    # Filter to unprocessed and not rejected
    already_handled = processed_ids | rejected_ids
    to_process = [v for v in videos if v["video_id"] not in already_handled]
    stats["skipped"] = len(videos) - len(to_process)

    if not to_process:
        print("  All videos already processed. Nothing to do.")
        return stats

    # Apply limit
    if args.limit and args.limit > 0:
        to_process = to_process[:args.limit]

    print(f"  Will process: {len(to_process)} video(s) (skipping {stats['skipped']} already done)")

    # --- Stage 2-5: Process each video ---
    for i, video_meta in enumerate(to_process, 1):
        video_id = video_meta["video_id"]
        source_path = video_meta.get("source_path", "")
        mp4_path = video_meta.get("mp4_path", "")
        video_path = mp4_path if mp4_path else source_path
        filename = Path(video_path).name
        username = video_meta["username"]

        if not video_path:
            stats["failed"] += 1
            stats["errors"].append("Missing video path in sessions CSV")
            print("  ERROR: Missing video path in sessions CSV")
            continue

        print(f"\n[{i}/{len(to_process)}] {filename}")
        print(f"  User: {username} | Task: {video_meta['task_description']}")

        if args.dry_run:
            print(f"  DRY RUN: Would process this video")
            stats["processed"] += 1
            continue

        try:
            # --- Stage 2: Get video metadata ---
            print(f"  Getting video metadata...")
            file_metadata = get_video_metadata(video_path)
            duration = file_metadata['duration_sec']
            print(f"  Duration: {duration}s | Size: {file_metadata['file_size_mb']} MB")

            # --- Quality Check: Duration bounds ---
            if duration > 0:  # Only check if we got a valid duration
                if duration < MIN_VIDEO_DURATION_SEC:
                    reason = f"Too short: {duration}s"
                    print(f"  REJECTED: Video too short ({duration}s < {MIN_VIDEO_DURATION_SEC}s minimum)")
                    move_to_misrecordings(
                        source_path=video_meta.get("source_path", ""),
                        mp4_path=mp4_path,
                        reason=reason
                    )
                    mark_rejected(video_id, reason)
                    update_workflow_sessions_status(video_id, "Rejected", reason, args.sessions_csv)
                    stats["rejected"] += 1
                    continue

                if duration > MAX_VIDEO_DURATION_SEC:
                    reason = f"Too long: {duration}s"
                    print(f"  REJECTED: Video too long ({duration}s > {MAX_VIDEO_DURATION_SEC}s maximum)")
                    move_to_misrecordings(
                        source_path=video_meta.get("source_path", ""),
                        mp4_path=mp4_path,
                        reason=reason
                    )
                    mark_rejected(video_id, reason)
                    update_workflow_sessions_status(video_id, "Rejected", reason, args.sessions_csv)
                    stats["rejected"] += 1
                    continue

            gemini_result = None
            analysis_md_path = ""

            if not args.metadata_only:
                # --- Stage 3: Gemini two-pass analysis with quality check ---
                print(f"  Analyzing with Gemini (two-pass + quality check)...")
                gemini_result = analyze_video(
                    video_path=video_path,
                    task_description=video_meta["task_description"],
                    video_id=video_id,
                )

                if not gemini_result:
                    print(f"  ERROR: Gemini analysis failed - no results returned")
                    stats["failed"] += 1
                    stats["errors"].append(f"{filename}: Gemini analysis failed")
                    continue

                # Check if Pass 1 quality indicates useful workflow
                if not gemini_result.get("is_useful", False):
                    reason = gemini_result.get("rejection_reason", "Low quality analysis results")
                    print(f"  REJECTED: {reason}")
                    move_to_misrecordings(
                        source_path=video_meta.get("source_path", ""),
                        mp4_path=mp4_path,
                        reason=reason
                    )
                    mark_rejected(video_id, reason)
                    update_workflow_sessions_status(video_id, "Rejected", reason, args.sessions_csv)
                    stats["rejected"] += 1
                    # Add delay before next video
                    if i < len(to_process):
                        print(f"  Waiting {API_CALL_DELAY_SECONDS:.0f}s before next video...")
                        time.sleep(API_CALL_DELAY_SECONDS)
                    continue

                # --- Stage 4: Save per-video markdown ---
                structured = gemini_result["structured"]
                print(f"  Primary app: {structured['primary_app']}")
                print(f"  Automation score: {structured['automation_score']}")
                print(f"  SOP steps: {structured['sop_step_count']}")
                print(f"  Top automation candidate: {structured['top_automation_candidate']}")

                analysis_md_path = save_analysis_markdown(
                    video_id=video_id,
                    username=username,
                    task_description=video_meta["task_description"],
                    markdown_content=gemini_result["markdown"],
                )
                if analysis_md_path:
                    print(f"  Analysis saved: {Path(analysis_md_path).name}")

            # --- Stage 5: Build and append CSV row (only for successfully analyzed videos) ---
            if args.metadata_only or gemini_result:
                row = build_row(
                    parsed_metadata=video_meta,
                    video_metadata=file_metadata,
                    gemini_structured=gemini_result["structured"] if gemini_result else None,
                    analysis_md_path=analysis_md_path,
                    mp4_path=mp4_path,
                )

                if append_row(row):
                    mark_processed(video_id)
                    update_workflow_sessions_status(video_id, "Analyzed", "", args.sessions_csv)
                    stats["processed"] += 1
                    print(f"  Written to CSV")
                else:
                    stats["failed"] += 1
                    stats["errors"].append(f"CSV write failed: {filename}")

            # Rate limit delay between Gemini calls
            if not args.metadata_only and i < len(to_process):
                print(f"  Waiting {API_CALL_DELAY_SECONDS:.0f}s before next video...")
                time.sleep(API_CALL_DELAY_SECONDS)

        except Exception as e:
            stats["failed"] += 1
            stats["errors"].append(f"{filename}: {e}")
            print(f"  ERROR: {e}")
            continue

    # --- Summary ---
    elapsed = (datetime.now() - start_time).total_seconds()
    print("\n" + "=" * 60)
    print("Pipeline Complete")
    print("=" * 60)
    print(f"Total videos found:    {stats['total']}")
    print(f"Processed:             {stats['processed']}")
    print(f"Skipped (existing):    {stats['skipped']}")
    print(f"Rejected (filtered):   {stats['rejected']}")
    print(f"Failed:                {stats['failed']}")
    print(f"Elapsed time:          {elapsed:.1f}s")

    if stats["errors"]:
        print(f"\nErrors:")
        for err in stats["errors"]:
            print(f"  - {err}")

    # CSV stats
    csv_stats = get_csv_stats()
    print(f"\nCSV Status:")
    print(f"  Total rows:     {csv_stats['total_rows']}")
    print(f"  Unique users:   {csv_stats['unique_users']}")
    print(f"  Unique machines: {csv_stats['unique_machines']}")
    print(f"  Date range:     {csv_stats['date_range']}")
    print("=" * 60)

    return stats


def main():
    parser = argparse.ArgumentParser(
        description="L7S Workflow Analysis Pipeline - Process workflow recordings into structured data",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python run_pipeline.py                        Process all users, full pipeline
  python run_pipeline.py --user rcrane           Process a single user
  python run_pipeline.py --limit 3               Process at most 3 videos
  python run_pipeline.py --dry-run               Preview what would be processed
  python run_pipeline.py --metadata-only         Extract file metadata only (no Gemini)
  python run_pipeline.py --report                Generate insights report after processing
        """,
    )

    parser.add_argument(
        "--source",
        default=MP4_DIR,
        help=f"Source directory for converted MP4s (default: {MP4_DIR})",
    )
    parser.add_argument(
        "--sessions-csv",
        default=CONVERSION_CSV,
        help=f"Path to workflow_sessions.csv (default: {CONVERSION_CSV})",
    )
    parser.add_argument(
        "--user",
        default="",
        help="Process only this user's videos",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Maximum number of videos to process (0 = unlimited)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview only — don't process or write anything",
    )
    parser.add_argument(
        "--metadata-only",
        action="store_true",
        help="Extract file metadata only (skip Gemini analysis)",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="Generate insights report after processing",
    )

    args = parser.parse_args()

    # Run the pipeline
    stats = run_pipeline(args)

    # Generate report if requested
    if args.report and not args.dry_run:
        print("\nGenerating insights report...")
        try:
            from report_generator import generate_report
            report_path = generate_report()
            if report_path:
                print(f"Report generated: {report_path}")
        except Exception as e:
            print(f"Report generation failed: {e}")

    # Exit with appropriate code
    if stats["failed"] > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
