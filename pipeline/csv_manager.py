"""
L7S Workflow Analysis Pipeline - CSV Manager

Manages the append-only analysis CSV, processing log, and per-video markdown files.
- Creates CSV with header if it doesn't exist
- Appends new rows (one per analyzed video)
- Deduplicates by video_id via processing log
- Saves per-video markdown analysis files
- Never overwrites existing data
"""

import csv
import os
import re
from datetime import datetime
from pathlib import Path

from config import ANALYSES_DIR, ANALYSIS_CSV, CSV_COLUMNS, OUTPUT_DIR, PROCESSING_LOG


def ensure_output_dir() -> None:
    """Create the output directory, reports, and analyses subdirectories if they don't exist."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(os.path.join(OUTPUT_DIR, "reports"), exist_ok=True)
    os.makedirs(ANALYSES_DIR, exist_ok=True)


def initialize_csv(csv_path: str = ANALYSIS_CSV) -> None:
    """Create the CSV file with headers if it doesn't exist."""
    ensure_output_dir()

    if not os.path.isfile(csv_path):
        with open(csv_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(CSV_COLUMNS)
        print(f"[INFO] Created analysis CSV: {csv_path}")


def load_processed_ids(log_path: str = PROCESSING_LOG) -> set[str]:
    """
    Load the set of already-processed video IDs from the processing log.

    Returns:
        Set of video_id strings that have already been processed.
    """
    processed = set()

    if not os.path.isfile(log_path):
        return processed

    try:
        with open(log_path, "r", encoding="utf-8") as f:
            for line in f:
                vid = line.strip()
                if vid:
                    processed.add(vid)
    except OSError as e:
        print(f"[WARN] Could not read processing log: {e}")

    return processed


def mark_processed(video_id: str, log_path: str = PROCESSING_LOG) -> None:
    """Append a video_id to the processing log."""
    ensure_output_dir()

    try:
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"{video_id}\n")
    except OSError as e:
        print(f"[ERROR] Could not write to processing log: {e}")


def append_row(
    row_data: dict,
    csv_path: str = ANALYSIS_CSV,
) -> bool:
    """
    Append a single analysis row to the CSV.

    Args:
        row_data: Dictionary with keys matching CSV_COLUMNS.
                  Missing keys will be filled with empty strings.
        csv_path: Path to the CSV file.

    Returns:
        True if the row was written successfully.
    """
    initialize_csv(csv_path)

    # Build row in column order, filling missing fields
    row_data.setdefault("processed_at", datetime.now().isoformat(timespec="seconds"))

    row = []
    for col in CSV_COLUMNS:
        value = row_data.get(col, "")
        row.append(str(value) if value is not None else "")

    try:
        with open(csv_path, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(row)
        return True
    except OSError as e:
        print(f"[ERROR] Could not append to CSV: {e}")
        return False


def build_row(
    parsed_metadata: dict,
    video_metadata: dict,
    gemini_structured: dict,
    analysis_md_path: str = "",
    mp4_path: str = "",
) -> dict:
    """
    Merge all data sources into a single row dict matching CSV_COLUMNS.

    Args:
        parsed_metadata: From filename_parser.parse_filename()
        video_metadata: From frame_extractor.get_video_metadata()
        gemini_structured: From gemini_analyzer.analyze_video()["structured"]
        analysis_md_path: Path to the saved per-video markdown file
        mp4_path: Path to the converted MP4 file (if available)

    Returns:
        Dict with all CSV_COLUMNS keys populated.
    """
    row = {}

    # From filename parser
    row["video_id"] = parsed_metadata.get("video_id", "")
    row["username"] = parsed_metadata.get("username", "")
    row["timestamp"] = parsed_metadata.get("timestamp", "")
    row["machine_id"] = parsed_metadata.get("machine_id", "")
    row["task_description"] = parsed_metadata.get("task_description", "")
    row["day_of_week"] = parsed_metadata.get("day_of_week", "")
    row["hour_of_day"] = parsed_metadata.get("hour_of_day", "")

    # From video file
    row["duration_sec"] = video_metadata.get("duration_sec", -1)
    row["file_size_mb"] = video_metadata.get("file_size_mb", 0)

    # From Gemini Pass 2 structured analysis
    if gemini_structured:
        row["workflow_description"] = gemini_structured.get("workflow_description", "")
        row["primary_app"] = gemini_structured.get("primary_app", "")
        row["app_sequence"] = gemini_structured.get("app_sequence", "[]")
        row["detected_actions"] = gemini_structured.get("detected_actions", "[]")
        row["automation_score"] = gemini_structured.get("automation_score", 0.0)
        row["workflow_category"] = gemini_structured.get("workflow_category", "")
        row["sop_step_count"] = gemini_structured.get("sop_step_count", 0)
        row["automation_candidate_count"] = gemini_structured.get("automation_candidate_count", 0)
        row["top_automation_candidate"] = gemini_structured.get("top_automation_candidate", "")
    else:
        row["workflow_description"] = ""
        row["primary_app"] = ""
        row["app_sequence"] = "[]"
        row["detected_actions"] = "[]"
        row["automation_score"] = 0.0
        row["workflow_category"] = ""
        row["sop_step_count"] = 0
        row["automation_candidate_count"] = 0
        row["top_automation_candidate"] = ""

    # Metadata
    row["source_path"] = parsed_metadata.get("source_path", "")
    row["mp4_path"] = mp4_path
    row["analysis_md_path"] = analysis_md_path
    row["processed_at"] = datetime.now().isoformat(timespec="seconds")

    return row


def save_analysis_markdown(
    video_id: str,
    username: str,
    task_description: str,
    markdown_content: str,
    analyses_dir: str = ANALYSES_DIR,
) -> str:
    """
    Save per-video markdown analysis to a file.

    Args:
        video_id: Unique video identifier.
        username: User who recorded the video.
        task_description: The stated task.
        markdown_content: Full markdown analysis from Gemini Pass 1.
        analyses_dir: Output directory for markdown files.

    Returns:
        Path to the saved file.
    """
    os.makedirs(analyses_dir, exist_ok=True)

    # Sanitize task description for filename
    safe_task = re.sub(r'[^\w\s-]', '', task_description).strip()
    safe_task = re.sub(r'[\s]+', '_', safe_task)[:50]

    filename = f"{video_id}_{username}_{safe_task}.md"
    filepath = os.path.join(analyses_dir, filename)

    # Build file with metadata header
    header = f"""---
video_id: {video_id}
username: {username}
task: {task_description}
analyzed_at: {datetime.now().isoformat(timespec="seconds")}
---

"""

    try:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(header)
            f.write(markdown_content)
        return filepath
    except OSError as e:
        print(f"[ERROR] Could not save analysis markdown: {e}")
        return ""


def get_csv_stats(csv_path: str = ANALYSIS_CSV) -> dict:
    """
    Get summary statistics from the analysis CSV.

    Returns:
        Dict with: total_rows, unique_users, date_range, etc.
    """
    stats = {
        "total_rows": 0,
        "unique_users": set(),
        "unique_machines": set(),
        "date_range": {"earliest": None, "latest": None},
    }

    if not os.path.isfile(csv_path):
        return stats

    try:
        with open(csv_path, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                stats["total_rows"] += 1
                if row.get("username"):
                    stats["unique_users"].add(row["username"])
                if row.get("machine_id"):
                    stats["unique_machines"].add(row["machine_id"])
                ts = row.get("timestamp", "")
                if ts:
                    if stats["date_range"]["earliest"] is None or ts < stats["date_range"]["earliest"]:
                        stats["date_range"]["earliest"] = ts
                    if stats["date_range"]["latest"] is None or ts > stats["date_range"]["latest"]:
                        stats["date_range"]["latest"] = ts
    except (OSError, csv.Error) as e:
        print(f"[WARN] Could not read CSV for stats: {e}")

    # Convert sets to counts for serialization
    stats["unique_users"] = len(stats["unique_users"])
    stats["unique_machines"] = len(stats["unique_machines"])

    return stats


if __name__ == "__main__":
    print("CSV Manager - Status")
    print(f"  CSV path: {ANALYSIS_CSV}")
    print(f"  Log path: {PROCESSING_LOG}")
    print(f"  Analyses dir: {ANALYSES_DIR}")

    processed = load_processed_ids()
    print(f"  Processed IDs: {len(processed)}")

    if os.path.isfile(ANALYSIS_CSV):
        stats = get_csv_stats()
        print(f"  CSV rows: {stats['total_rows']}")
        print(f"  Users: {stats['unique_users']}")
        print(f"  Machines: {stats['unique_machines']}")
        print(f"  Date range: {stats['date_range']}")
    else:
        print("  CSV does not exist yet.")
