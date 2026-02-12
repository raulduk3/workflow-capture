"""
L7S Workflow Analysis Pipeline - Frame Extractor

Extracts evenly-spaced screenshot frames from workflow videos using ffmpeg.
Frames are saved as JPGs to a temp directory, used by Gemini, then cleaned up.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

from config import (
    FRAMES_PER_VIDEO,
    FRAMES_TEMP_DIR,
    MIN_FILE_SIZE_BYTES,
    find_ffmpeg,
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


def extract_frames(
    video_path: str,
    num_frames: int = FRAMES_PER_VIDEO,
    output_dir: str = "",
) -> list[str]:
    """
    Extract evenly-spaced frames from a video file.

    Args:
        video_path: Path to the .webm video file.
        num_frames: Number of frames to extract (default: 35).
        output_dir: Directory for output JPGs. If empty, uses a temp dir
                    named by the video's hash.

    Returns:
        Sorted list of paths to extracted frame JPGs.
        Empty list on failure.
    """
    video_path = str(video_path)

    # Validate input
    if not os.path.isfile(video_path):
        print(f"[ERROR] Video file not found: {video_path}")
        return []

    if os.path.getsize(video_path) < MIN_FILE_SIZE_BYTES:
        print(f"[WARN] Video too small ({os.path.getsize(video_path)} bytes), skipping: {Path(video_path).name}")
        return []

    # Get duration to calculate frame interval
    metadata = get_video_metadata(video_path)
    duration = metadata["duration_sec"]

    if duration <= 0:
        print(f"[WARN] Could not determine duration, using fallback extraction for: {Path(video_path).name}")
        return _extract_frames_fallback(video_path, num_frames, output_dir)

    # Create output directory
    if not output_dir:
        # Use a subdirectory named by first 8 chars of filename hash
        import hashlib
        video_hash = hashlib.sha256(video_path.encode()).hexdigest()[:8]
        output_dir = os.path.join(FRAMES_TEMP_DIR, video_hash)

    os.makedirs(output_dir, exist_ok=True)

    # Calculate frame interval: extract 1 frame every N seconds
    interval = duration / num_frames
    if interval < 0.5:
        # Very short video — just grab what we can
        interval = 0.5
        num_frames = max(1, int(duration / interval))

    # Use ffmpeg select filter for precise frame extraction
    # select='not(mod(n,INTERVAL))' selects every Nth frame
    # fps filter approach is more reliable for even spacing
    ffmpeg = find_ffmpeg()
    output_pattern = os.path.join(output_dir, "frame_%03d.jpg")

    try:
        result = subprocess.run(
            [
                ffmpeg,
                "-i", video_path,
                "-vf", f"fps=1/{interval:.2f}",
                "-frames:v", str(num_frames),
                "-q:v", "2",  # JPEG quality (2 = high quality)
                "-y",
                "-loglevel", "error",
                output_pattern,
            ],
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout for large files
        )

        if result.returncode != 0:
            print(f"[ERROR] ffmpeg frame extraction failed: {result.stderr.strip()}")
            return []

    except subprocess.TimeoutExpired:
        print(f"[ERROR] Frame extraction timed out for: {Path(video_path).name}")
        return []
    except FileNotFoundError:
        print(f"[ERROR] ffmpeg not found")
        return []

    # Collect extracted frames
    frames = sorted(
        [os.path.join(output_dir, f) for f in os.listdir(output_dir) if f.endswith(".jpg")],
    )

    if not frames:
        print(f"[WARN] No frames extracted from: {Path(video_path).name}")
        return []

    return frames


def _extract_frames_fallback(
    video_path: str,
    num_frames: int,
    output_dir: str,
) -> list[str]:
    """
    Fallback extraction when duration is unknown.
    Extracts frames at 1fps and takes the first num_frames.
    """
    if not output_dir:
        import hashlib
        video_hash = hashlib.sha256(video_path.encode()).hexdigest()[:8]
        output_dir = os.path.join(FRAMES_TEMP_DIR, video_hash)

    os.makedirs(output_dir, exist_ok=True)
    ffmpeg = find_ffmpeg()
    output_pattern = os.path.join(output_dir, "frame_%03d.jpg")

    try:
        result = subprocess.run(
            [
                ffmpeg,
                "-i", video_path,
                "-vf", "fps=1",             # 1 frame per second
                "-frames:v", str(num_frames),
                "-q:v", "2",
                "-y",
                "-loglevel", "error",
                output_pattern,
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )

        if result.returncode != 0:
            print(f"[ERROR] Fallback extraction failed: {result.stderr.strip()}")
            return []

    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"[ERROR] Fallback extraction error: {e}")
        return []

    frames = sorted(
        [os.path.join(output_dir, f) for f in os.listdir(output_dir) if f.endswith(".jpg")],
    )

    return frames


def cleanup_frames(output_dir: str) -> None:
    """Remove the temporary frames directory after processing."""
    try:
        if os.path.isdir(output_dir):
            shutil.rmtree(output_dir)
    except OSError as e:
        print(f"[WARN] Could not clean up frames dir {output_dir}: {e}")


def cleanup_all_frames() -> None:
    """Remove the entire temp frames root directory."""
    cleanup_frames(FRAMES_TEMP_DIR)


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python frame_extractor.py <video_path>")
        sys.exit(1)

    video = sys.argv[1]
    print(f"Extracting frames from: {video}")

    meta = get_video_metadata(video)
    print(f"  Duration: {meta['duration_sec']}s, Size: {meta['file_size_mb']} MB")

    frames = extract_frames(video)
    if frames:
        print(f"  Extracted {len(frames)} frames:")
        for f in frames[:5]:
            print(f"    {f}")
        if len(frames) > 5:
            print(f"    ... and {len(frames) - 5} more")
        print(f"\n  Frames dir: {Path(frames[0]).parent}")
        print("  Run cleanup manually when done: cleanup_frames(dir)")
    else:
        print("  No frames extracted.")
