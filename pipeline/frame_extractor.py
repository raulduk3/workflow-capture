"""
L7S Workflow Analysis Pipeline - Video Metadata Extractor

Extracts video duration and file size via ffprobe.
"""

import json
import os
import subprocess
from pathlib import Path

from config import (
    MIN_FILE_SIZE_BYTES,
    find_ffprobe,
)


def get_video_metadata(video_path: str) -> dict:
    """
    Get video duration and file size via ffprobe.

    Returns:
        Dict with duration_sec (float) and file_size_mb (float).
        duration_sec is -1 if ffprobe fails.
    """
    file_size_bytes = os.path.getsize(video_path)
    file_size_mb = round(file_size_bytes / (1024 * 1024), 2)

    try:
        ffprobe = find_ffprobe()
        result = subprocess.run(
            [
                ffprobe,
                "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                video_path,
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode == 0:
            info = json.loads(result.stdout)
            duration = float(info.get("format", {}).get("duration", -1))
            return {
                "duration_sec": round(duration, 1),
                "file_size_mb": file_size_mb,
            }
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError) as e:
        print(f"[WARN] ffprobe failed for {Path(video_path).name}: {e}")

    return {
        "duration_sec": -1,
        "file_size_mb": file_size_mb,
    }


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python frame_extractor.py <video_path>")
        sys.exit(1)

    video = sys.argv[1]
    print(f"Getting metadata for: {video}")

    meta = get_video_metadata(video)
    print(f"  Duration: {meta['duration_sec']}s, Size: {meta['file_size_mb']} MB")
