"""
L7S Workflow Analysis Pipeline - CSV Manager

Manages the append-only analysis CSV and processing log.
- Creates CSV with header if it doesn't exist
- Appends new rows (one per analyzed video)
- Deduplicates by video_id via processing log
- Never overwrites existing data
"""

import csv
import os
from datetime import datetime
from pathlib import Path

from config import ANALYSIS_CSV, CSV_COLUMNS, OUTPUT_DIR, PROCESSING_LOG


def ensure_output_dir() -> None:
    """Create the output directory and reports subdirectory if they don't exist."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(os.path.join(OUTPUT_DIR, "reports"), exist_ok=True)


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
    gemini_analysis: dict,
    pattern_flags: str,
    mp4_path: str = "",
) -> dict:
    """
    Merge all data sources into a single row dict matching CSV_COLUMNS.

    Args:
        parsed_metadata: From filename_parser.parse_filename()
        video_metadata: From frame_extractor.get_video_metadata()
        gemini_analysis: From gemini_analyzer.analyze_video()
        pattern_flags: From pattern_detector.detect_patterns()
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

    # From Gemini analysis
    if gemini_analysis:
        row["workflow_description"] = gemini_analysis.get("workflow_description", "")
        row["primary_app"] = gemini_analysis.get("primary_app", "")
        row["app_sequence"] = gemini_analysis.get("app_sequence", "[]")
        row["detected_actions"] = gemini_analysis.get("detected_actions", "[]")
        row["friction_events"] = gemini_analysis.get("friction_events", "[]")
        row["friction_count"] = gemini_analysis.get("friction_count", 0)
        row["automation_score"] = gemini_analysis.get("automation_score", 0.0)
        row["workflow_category"] = gemini_analysis.get("workflow_category", "")
    else:
        row["workflow_description"] = ""
        row["primary_app"] = ""
        row["app_sequence"] = "[]"
        row["detected_actions"] = "[]"
        row["friction_events"] = "[]"
        row["friction_count"] = 0
        row["automation_score"] = 0.0
        row["workflow_category"] = ""

    # Pattern flags
    row["pattern_flags"] = pattern_flags

    # ActivTrak fields (deferred - empty for now)
    row["activtrak_productive_pct"] = ""
    row["activtrak_idle_min"] = ""
    row["activtrak_top_apps"] = ""

    # Metadata
    row["source_path"] = parsed_metadata.get("source_path", "")
    row["mp4_path"] = mp4_path
    row["processed_at"] = datetime.now().isoformat(timespec="seconds")

    return row


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
