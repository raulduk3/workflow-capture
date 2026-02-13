"""
L7S Workflow Analysis Pipeline - Configuration
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

# Network share where .webm files are collected by Ninja RMM extraction script
SOURCE_SHARE = r"\\bulley-fs1\workflow"

# Local directory on utility server where MP4s are written by Convert-WorkflowSessions.ps1
MP4_DIR = r"C:\temp\WorkflowProcessing"

# Conversion CSV produced by Convert-WorkflowSessions.ps1
CONVERSION_CSV = os.path.join(MP4_DIR, "workflow_sessions.csv")

# Output directory for analysis results
OUTPUT_DIR = MP4_DIR

# Main analysis CSV (one row per video, cumulative)
ANALYSIS_CSV = os.path.join(OUTPUT_DIR, "workflow_analysis.csv")

# Processing log (one video_id per line for dedup)
PROCESSING_LOG = os.path.join(OUTPUT_DIR, "processed.log")

# Reports output directory
REPORTS_DIR = os.path.join(OUTPUT_DIR, "reports")

# Temp directory for frame extraction (cleaned up after each video)
FRAMES_TEMP_DIR = os.path.join(os.environ.get("TEMP", r"C:\temp"), "WorkflowFrames")

# =============================================================================
# Pipeline Settings
# =============================================================================

# Number of evenly-spaced frames to extract per video
# 50 frames from a 5-min video = 1 frame every ~6 seconds
# Optimized for maximum coverage while staying under token-per-minute limits
# At 768px/258 tokens per frame = ~12,900 tokens per request + prompt
FRAMES_PER_VIDEO = 50

# Maximum frames to send to Gemini per request (cost control)
MAX_FRAMES_TO_ANALYZE = 50

# Delay between Gemini API calls in seconds (rate limit protection)
# Increased to avoid hitting rate limits with large frame batches
API_CALL_DELAY_SECONDS = 5.0

# Maximum retries for Gemini API calls
MAX_API_RETRIES = 5

# Initial backoff delay for rate limit errors (seconds)
RATE_LIMIT_INITIAL_BACKOFF = 10.0

# Minimum file size in bytes to consider a video valid (skip corrupt/empty)
MIN_FILE_SIZE_BYTES = 10_000  # 10 KB

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

# Full schema (16 fields)
# Core analysis pipeline: filename metadata + Gemini Vision + pattern detection
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
    # From Gemini Vision (8 fields)
    "workflow_description",
    "primary_app",
    "app_sequence",
    "detected_actions",
    "friction_events",
    "friction_count",
    "automation_score",
    "workflow_category",
    # Pattern flags (1 derived field)
    "pattern_flags",
    # Metadata
    "source_path",
    "mp4_path",
    "processed_at",
]
