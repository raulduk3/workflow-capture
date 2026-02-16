"""
Workflow Analysis Pipeline - Configuration
All paths, constants, and environment variables centralized here.
"""

import os
from pathlib import Path
from dotenv import load_dotenv

# Load .env file from the pipeline directory
_pipeline_dir = Path(__file__).parent
load_dotenv(_pipeline_dir / ".env", override=True)

# =============================================================================
# Paths
# =============================================================================

# Source directory where .webm files are collected (network share or local)
# Configure via WORKFLOW_SOURCE_SHARE environment variable or set below
SOURCE_SHARE = os.environ.get("WORKFLOW_SOURCE_SHARE", r"\\SERVER\SHARE\workflow")

# Local directory where MP4s are written by video conversion process
MP4_DIR = r"C:\temp\WorkflowProcessing"

# Conversion CSV produced by conversion script
CONVERSION_CSV = os.path.join(MP4_DIR, "workflow_sessions.csv")

# Output directory for analysis results
OUTPUT_DIR = MP4_DIR

# Main analysis CSV (one row per video, cumulative)
ANALYSIS_CSV = os.path.join(OUTPUT_DIR, "workflow_analysis.csv")

# Processing log (one video_id per line for dedup - only successfully analyzed videos)
PROCESSING_LOG = os.path.join(OUTPUT_DIR, "processed.log")

# Rejected videos log (videos that failed validation/quality checks)
REJECTED_LOG = os.path.join(OUTPUT_DIR, "rejected.log")

# Reports output directory
REPORTS_DIR = os.path.join(OUTPUT_DIR, "reports")

# Per-video analysis markdown output directory
ANALYSES_DIR = os.path.join(OUTPUT_DIR, "analyses")

# =============================================================================
# Pipeline Settings
# =============================================================================

# Delay between Gemini API calls in seconds (rate limit protection)
API_CALL_DELAY_SECONDS = 5.0

# Video upload polling interval (seconds between File API state checks)
VIDEO_UPLOAD_POLL_INTERVAL = 5

# Maximum time to wait for Gemini to process an uploaded video (seconds)
VIDEO_UPLOAD_TIMEOUT = int(os.environ.get("VIDEO_UPLOAD_TIMEOUT", "300"))

# Maximum retries for Gemini API calls
MAX_API_RETRIES = 5

# Initial backoff delay for rate limit errors (seconds)
RATE_LIMIT_INITIAL_BACKOFF = 10.0

# Minimum file size in bytes to consider a video valid (skip corrupt/empty)
MIN_FILE_SIZE_BYTES = 10_000  # 10 KB

# =============================================================================
# Video Quality Filtering
# =============================================================================

# Minimum video duration in seconds to consider valid (skip accidental recordings)
MIN_VIDEO_DURATION_SEC = 5

# Maximum video duration in seconds (skip all-day recordings)
MAX_VIDEO_DURATION_SEC = 3600  # 1 hour

# Directory for misrecorded/invalid videos
MISRECORDINGS_DIR = os.path.join(OUTPUT_DIR, "_misrecordings")

# =============================================================================
# FFmpeg / FFprobe
# =============================================================================

# Chocolatey installs ffmpeg here on Windows
FFMPEG_CHOCO_PATH = r"C:\ProgramData\chocolatey\bin\ffmpeg.exe"
FFPROBE_CHOCO_PATH = r"C:\ProgramData\chocolatey\bin\ffprobe.exe"


def find_ffmpeg() -> str:
    """Locate ffmpeg executable. Checks Chocolatey path first, then PATH."""
    if os.path.isfile(FFMPEG_CHOCO_PATH):
        return FFMPEG_CHOCO_PATH

    import shutil
    path = shutil.which("ffmpeg")
    if path:
        return path

    raise FileNotFoundError(
        "ffmpeg not found. Install via: choco install ffmpeg\n"
        f"  Checked: {FFMPEG_CHOCO_PATH}\n"
        "  Also checked: system PATH"
    )


def find_ffprobe() -> str:
    """Locate ffprobe executable. Checks Chocolatey path first, then PATH."""
    if os.path.isfile(FFPROBE_CHOCO_PATH):
        return FFPROBE_CHOCO_PATH

    import shutil
    path = shutil.which("ffprobe")
    if path:
        return path

    raise FileNotFoundError(
        "ffprobe not found. Should be installed alongside ffmpeg.\n"
        f"  Checked: {FFPROBE_CHOCO_PATH}\n"
        "  Also checked: system PATH"
    )


# =============================================================================
# Gemini API
# =============================================================================

GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "").strip()
GEMINI_MODEL = "gemini-2.0-flash"

# =============================================================================
# CSV Schema
# =============================================================================

# CSV schema: filename metadata + video metadata + Gemini analysis (two-pass)
CSV_COLUMNS = [
    # From filename (7 fields)
    "video_id",
    "username",
    "timestamp",
    "machine_id",
    "task_description",
    "day_of_week",
    "hour_of_day",
    # From video file (2 fields)
    "duration_sec",
    "file_size_mb",
    # From Gemini Pass 2 — structured ML fields (6 fields)
    "workflow_description",
    "primary_app",
    "app_sequence",
    "detected_actions",
    "automation_score",
    "workflow_category",
    # From Gemini Pass 2 — new fields derived from rich analysis (3 fields)
    "sop_step_count",
    "automation_candidate_count",
    "top_automation_candidate",
    # Metadata
    "source_path",
    "mp4_path",
    "analysis_md_path",
    "processed_at",
]
