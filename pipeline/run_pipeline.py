"""
L7S Workflow Analysis Pipeline - Orchestrator

Main entry point that wires all pipeline stages together:
  1. Discover .webm files on network share
  2. Skip already-processed videos
  3. For each new video:
     a. Parse filename → metadata
     b. Get duration/size via ffprobe
     c. Extract 35 frames
     d. Send to Gemini Vision → analysis JSON
     e. Apply pattern detection rules
     f. Append row to analysis CSV
     g. Mark as processed
     h. Clean up temp frames
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
    MP4_DIR,
    OUTPUT_DIR,
    SOURCE_SHARE,
)
from csv_manager import (
    append_row,
    build_row,
    ensure_output_dir,
    get_csv_stats,
    load_processed_ids,
    mark_processed,
)
from filename_parser import discover_videos
from frame_extractor import (
    cleanup_frames,
    extract_frames,
    get_video_metadata,
)
from gemini_analyzer import analyze_video
from pattern_detector import detect_patterns


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
        "failed": 0,
        "errors": [],
    }

    # --- Pre-flight ---
    print("=" * 60)
    print("L7S Workflow Analysis Pipeline")
    print("=" * 60)
    print(f"Source:      {args.source}")
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
    print("\n[Stage 1] Discovering videos...")
    videos = discover_videos(args.source, single_user=args.user)
    stats["total"] = len(videos)

    if not videos:
        print("  No videos found.")
        return stats

    print(f"  Found {len(videos)} video(s)")

    # --- Load processing log for dedup ---
    processed_ids = load_processed_ids()
    print(f"  Previously processed: {len(processed_ids)} video(s)")

    # Filter to unprocessed only
    to_process = [v for v in videos if v["video_id"] not in processed_ids]
    stats["skipped"] = len(videos) - len(to_process)

    if not to_process:
        print("  All videos already processed. Nothing to do.")
        return stats

    # Apply limit
    if args.limit and args.limit > 0:
        to_process = to_process[:args.limit]

    print(f"  Will process: {len(to_process)} video(s) (skipping {stats['skipped']} already done)")

    # --- Stage 2-4: Process each video ---
    for i, video_meta in enumerate(to_process, 1):
        video_id = video_meta["video_id"]
        source_path = video_meta["source_path"]
        filename = Path(source_path).name
        username = video_meta["username"]

        print(f"\n[{i}/{len(to_process)}] {filename}")
        print(f"  User: {username} | Task: {video_meta['task_description']}")

        if args.dry_run:
            print(f"  DRY RUN: Would process this video")
            stats["processed"] += 1
            continue

        try:
            # --- Stage 2: Get video metadata ---
            print(f"  Getting video metadata...")
            file_metadata = get_video_metadata(source_path)
            print(f"  Duration: {file_metadata['duration_sec']}s | Size: {file_metadata['file_size_mb']} MB")

            # --- Determine MP4 path (if converted) ---
            basename = Path(source_path).stem
            mp4_name = f"{username}_{basename}.mp4"
            mp4_path = str(Path(MP4_DIR) / mp4_name)
            if not Path(mp4_path).is_file():
                mp4_path = ""  # Not yet converted

            gemini_result = None
            if not args.metadata_only:
                # --- Stage 3: Extract frames ---
                print(f"  Extracting frames...")
                frames = extract_frames(source_path)

                if not frames:
                    print(f"  WARNING: No frames extracted, skipping Gemini analysis")
                else:
                    print(f"  Extracted {len(frames)} frames")
                    frames_dir = str(Path(frames[0]).parent)

                    # --- Stage 4: Gemini analysis ---
                    print(f"  Analyzing with Gemini...")
                    gemini_result = analyze_video(
                        frame_paths=frames,
                        task_description=video_meta["task_description"],
                        video_id=video_id,
                    )

                    if gemini_result:
                        print(f"  Primary app: {gemini_result['primary_app']}")
                        print(f"  Automation score: {gemini_result['automation_score']}")
                        print(f"  Friction events: {gemini_result['friction_count']}")
                    else:
                        print(f"  WARNING: Gemini analysis returned no results")

                    # Clean up frames
                    cleanup_frames(frames_dir)

            # --- Stage 5: Pattern detection ---
            pattern_flags = detect_patterns(gemini_result) if gemini_result else ""
            if pattern_flags:
                print(f"  Pattern flags: {pattern_flags}")

            # --- Stage 6: Build and append CSV row ---
            row = build_row(
                parsed_metadata=video_meta,
                video_metadata=file_metadata,
                gemini_analysis=gemini_result,
                pattern_flags=pattern_flags,
                mp4_path=mp4_path,
            )

            if append_row(row):
                mark_processed(video_id)
                stats["processed"] += 1
                print(f"  ✓ Written to CSV")
            else:
                stats["failed"] += 1
                stats["errors"].append(f"CSV write failed: {filename}")

            # Rate limit delay between Gemini calls
            if not args.metadata_only and i < len(to_process):
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
        default=SOURCE_SHARE,
        help=f"Source share path (default: {SOURCE_SHARE})",
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
