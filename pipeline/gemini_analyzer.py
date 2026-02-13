"""
L7S Workflow Analysis Pipeline - Gemini Vision Analyzer

Sends extracted frames + structured prompt to Gemini Flash API.
Returns structured JSON with: primary_app, app_sequence, detected_actions,
friction_events, automation_score, workflow_category.
"""

import json
import os
import time
from pathlib import Path
from typing import Optional

import google.genai as genai
from google.genai import types
from PIL import Image

from config import (
    API_CALL_DELAY_SECONDS,
    GEMINI_API_KEY,
    GEMINI_MODEL,
    MAX_API_RETRIES,
    MAX_FRAMES_TO_ANALYZE,
    RATE_LIMIT_INITIAL_BACKOFF,
)

# =============================================================================
# Gemini API Setup
# =============================================================================

_client = None


def _ensure_configured():
    """Initialize the Gemini client once."""
    global _client
    if _client is not None:
        return

    api_key = os.environ.get("GEMINI_API_KEY", GEMINI_API_KEY).strip()
    if not api_key:
        raise ValueError(
            "GEMINI_API_KEY not set. Create pipeline/.env with:\n"
            "  GEMINI_API_KEY=your-key-here\n"
            "Get a key at: https://aistudio.google.com/app/apikey"
        )

    _client = genai.Client(api_key=api_key)


def _get_client():
    """Get the configured client."""
    _ensure_configured()
    return _client


# =============================================================================
# Analysis Prompt
# =============================================================================

ANALYSIS_PROMPT = """You are analyzing screenshots from a screen recording of someone performing a work task on their computer.

**Task the user said they were doing:** "{task_description}"

Analyze all the provided screenshots and extract the following information. Look carefully at:
- Which applications are visible (window titles, UI elements)
- What the user is doing in each frame (data entry, reading, navigating, copying, etc.)
- Any signs of friction: error messages, repeated actions, excessive app switching, long pauses on the same screen, confusing UI states
- Whether this workflow could be partially or fully automated

Return your analysis as a JSON object with exactly these fields:

{{
    "primary_app": "The application that appears most frequently across the screenshots (e.g., 'Excel', 'Outlook', 'Procore', 'Chrome', 'SAP')",
    "app_sequence": ["Ordered list of distinct applications used, in the order they first appear"],
    "detected_actions": ["List of actions observed (e.g., 'data entry', 'copy-paste', 'form filling', 'email reading', 'file navigation', 'report generation', 'approval workflow', 'manual calculation')"],
    "friction_events": ["List of specific friction points observed (e.g., 'error dialog appeared', 'user repeated same action', 'switched between 3 apps to copy data', 'long pause suggesting confusion', 'manual data re-entry between systems')"],
    "automation_score": 0.0,
    "workflow_category": "One of: data_entry, reporting, communication, document_review, financial_processing, project_management, payroll, procurement, approval_workflow, other"
}}

Guidelines for automation_score (0.0 to 1.0):
- 0.0-0.3: Creative/judgment-heavy work, unique decisions each time
- 0.3-0.5: Some repetitive elements but significant human judgment needed
- 0.5-0.7: Moderately repetitive, follows patterns, some steps could be automated
- 0.7-0.85: Highly repetitive, predictable steps, strong automation candidate
- 0.85-1.0: Almost entirely mechanical, minimal judgment, ideal for full automation

Be specific in your observations. Reference actual UI elements, application names, and actions you can see in the screenshots. If you cannot identify an application, describe what you see (e.g., "spreadsheet application", "web-based form").

Return ONLY the JSON object, no additional text."""


# =============================================================================
# Frame Loading
# =============================================================================


def _load_frames(frame_paths: list[str], max_frames: int = MAX_FRAMES_TO_ANALYZE) -> list[Image.Image]:
    """
    Load frame images for Gemini analysis.
    If there are more frames than max_frames, sample evenly.
    """
    if len(frame_paths) > max_frames:
        # Evenly sample frames
        step = len(frame_paths) / max_frames
        indices = [int(i * step) for i in range(max_frames)]
        frame_paths = [frame_paths[i] for i in indices]

    images = []
    for path in frame_paths:
        try:
            img = Image.open(path)
            # Resize if very large to reduce API costs (keep aspect ratio)
            max_dim = 1280
            if img.width > max_dim or img.height > max_dim:
                img.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)
            images.append(img)
        except Exception as e:
            print(f"[WARN] Could not load frame {Path(path).name}: {e}")

    return images


# =============================================================================
# Analysis
# =============================================================================


def analyze_video(
    frame_paths: list[str],
    task_description: str,
    video_id: str = "",
) -> Optional[dict]:
    """
    Send frames to Gemini Vision API and get structured analysis.

    Args:
        frame_paths: List of paths to extracted frame JPGs.
        task_description: The user's stated task from the filename.
        video_id: Identifier for logging.

    Returns:
        Dict with: primary_app, app_sequence, detected_actions,
                   friction_events, friction_count, automation_score,
                   workflow_category.
        None on failure.
    """
    _ensure_configured()

    if not frame_paths:
        print(f"[ERROR] No frames to analyze for video {video_id}")
        return None

    # Load and prepare frames
    images = _load_frames(frame_paths)
    if not images:
        print(f"[ERROR] Could not load any frames for video {video_id}")
        return None

    # Build the prompt
    prompt = ANALYSIS_PROMPT.format(task_description=task_description)

    # Build content: prompt + all images
    content = [prompt] + images

    # Get client
    client = _get_client()

    # Add a small warmup delay before the first request to avoid burst limits
    print(f"  Waiting {API_CALL_DELAY_SECONDS:.0f}s before API call (rate limit protection)...")
    time.sleep(API_CALL_DELAY_SECONDS / 2)

    # Call Gemini with retries
    last_error = None
    for attempt in range(1, MAX_API_RETRIES + 1):
        try:
            response = client.models.generate_content(
                model=GEMINI_MODEL,
                contents=content,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    temperature=0.2,  # Low temp for consistent structured output
                ),
            )

            # Parse JSON response
            result = _parse_response(response.text, video_id)
            if result:
                return result

            print(f"[WARN] Malformed response for {video_id}, attempt {attempt}/{MAX_API_RETRIES}")

        except Exception as e:
            last_error = e
            error_str = str(e).lower()

            # Rate limit — back off exponentially with longer initial wait
            if "429" in str(e) or "resource_exhausted" in error_str or "quota" in error_str:
                # Start with longer backoff and increase exponentially
                wait = RATE_LIMIT_INITIAL_BACKOFF * (2 ** (attempt - 1))
                print(f"[WARN] Rate limited on {video_id}, waiting {wait:.0f}s (attempt {attempt}/{MAX_API_RETRIES})")
                time.sleep(wait)
                continue

            # Safety filter or blocked content
            if "safety" in error_str or "blocked" in error_str:
                print(f"[WARN] Content blocked by safety filter for {video_id}: {e}")
                return None

            # Other errors
            print(f"[WARN] Gemini API error for {video_id} (attempt {attempt}/{MAX_API_RETRIES}): {e}")
            if attempt < MAX_API_RETRIES:
                time.sleep(API_CALL_DELAY_SECONDS)

    error_msg = str(last_error)
    print(f"[ERROR] All {MAX_API_RETRIES} attempts failed for {video_id}: {last_error}")
    
    # If it's a quota/rate limit error, provide guidance
    if "429" in error_msg or "RESOURCE_EXHAUSTED" in error_msg or "quota" in error_msg.lower():
        print(f"[TIP] Consider:")
        print(f"      - Increase API_CALL_DELAY_SECONDS in config.py (currently {API_CALL_DELAY_SECONDS}s)")
        print(f"      - Reduce FRAMES_PER_VIDEO in config.py to lower API load")
        print(f"      - Process fewer videos at once with --limit flag")
        print(f"      - Check your Gemini API quota at: https://aistudio.google.com/")
    
    return None


def _parse_response(response_text: str, video_id: str) -> Optional[dict]:
    """Parse and validate the Gemini JSON response."""
    try:
        data = json.loads(response_text)
    except json.JSONDecodeError:
        # Try to extract JSON from markdown code block
        import re
        match = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', response_text, re.DOTALL)
        if match:
            try:
                data = json.loads(match.group(1))
            except json.JSONDecodeError:
                print(f"[ERROR] Could not parse JSON from response for {video_id}")
                return None
        else:
            print(f"[ERROR] Response is not valid JSON for {video_id}")
            return None

    # Validate required fields
    required = ["primary_app", "app_sequence", "detected_actions",
                 "friction_events", "automation_score", "workflow_category"]

    for field in required:
        if field not in data:
            print(f"[WARN] Missing field '{field}' in response for {video_id}")
            data.setdefault(field, _default_value(field))

    # Normalize types
    result = {
        "primary_app": str(data.get("primary_app", "Unknown")),
        "app_sequence": _ensure_json_list(data.get("app_sequence", [])),
        "detected_actions": _ensure_json_list(data.get("detected_actions", [])),
        "friction_events": _ensure_json_list(data.get("friction_events", [])),
        "automation_score": _clamp_float(data.get("automation_score", 0.0), 0.0, 1.0),
        "workflow_category": str(data.get("workflow_category", "other")),
    }

    # Derive friction_count
    friction_list = data.get("friction_events", [])
    result["friction_count"] = len(friction_list) if isinstance(friction_list, list) else 0

    return result


def _default_value(field: str):
    """Return a sensible default for missing fields."""
    defaults = {
        "primary_app": "Unknown",
        "app_sequence": [],
        "detected_actions": [],
        "friction_events": [],
        "automation_score": 0.0,
        "workflow_category": "other",
    }
    return defaults.get(field, "")


def _ensure_json_list(value) -> str:
    """Ensure value is serialized as a JSON array string."""
    if isinstance(value, list):
        return json.dumps(value)
    if isinstance(value, str):
        # Already a JSON string?
        try:
            parsed = json.loads(value)
            if isinstance(parsed, list):
                return value
        except json.JSONDecodeError:
            pass
        return json.dumps([value])
    return json.dumps([])


def _clamp_float(value, min_val: float, max_val: float) -> float:
    """Clamp a numeric value between min and max."""
    try:
        v = float(value)
        return max(min_val, min(max_val, v))
    except (ValueError, TypeError):
        return 0.0


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        print("Usage: python gemini_analyzer.py <frames_dir> <task_description>")
        print("  frames_dir: Directory containing frame_*.jpg files")
        print("  task_description: The user's stated task")
        sys.exit(1)

    frames_dir = sys.argv[1]
    task = sys.argv[2]

    frame_files = sorted(
        [str(Path(frames_dir) / f) for f in os.listdir(frames_dir) if f.endswith(".jpg")]
    )

    print(f"Analyzing {len(frame_files)} frames...")
    print(f"Task: {task}")

    import os  # noqa: F811
    result = analyze_video(frame_files, task, "test")
    if result:
        print("\nAnalysis Result:")
        print(json.dumps(result, indent=2))
    else:
        print("\nAnalysis failed.")
