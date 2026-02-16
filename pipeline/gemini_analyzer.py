"""
L7S Workflow Analysis Pipeline - Gemini Video Analyzer

Two-pass analysis with quality check using Gemini's File API:
  Pass 1: Upload whole video + SOP/automation prompt → rich markdown (sections A-E)
  Pass 2: Send markdown to Gemini → structured JSON for ML pipelines
  Quality Check: Evaluate Pass 2 results to filter low-quality/non-workflow videos
  
Quality indicators:
  - Primary app detected (not Unknown/N/A)
  - Automation score ≥ 0.3
  - SOP steps > 0
  - Meaningful workflow description

Videos failing quality check are rejected without saving (one upload, smart filtering).
"""

import json
import os
import re
import time
from typing import Optional

import google.genai as genai
from google.genai import types

from config import (
    API_CALL_DELAY_SECONDS,
    GEMINI_API_KEY,
    GEMINI_MODEL,
    MAX_API_RETRIES,
    RATE_LIMIT_INITIAL_BACKOFF,
    VIDEO_UPLOAD_POLL_INTERVAL,
    VIDEO_UPLOAD_TIMEOUT,
)

# =============================================================================
# Gemini API Setup
# =============================================================================

_client: Optional[genai.Client] = None


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
# Prompts
# =============================================================================

# Pass 1: Rich workflow analysis prompt (produces markdown sections A-E)
ANALYSIS_PROMPT = """You are an AI workflow analyst.
Your job is to audit how I complete a recurring work task and identify:
1) the exact steps I follow
2) what should and should not be automated
3) how to automate it safely
4) how to explain the findings visually

INPUT:
I will provide a screen recording of me completing the task.
The user described this task as: "{task_description}"
Treat this input as if you watched me complete the task end-to-end.
---

OUTPUT THE FOLLOWING SECTIONS (STRICT):

### A) SOP (Standard Operating Procedure) — Step-by-step process

Write the exact steps I followed, in order.
- Use numbered steps
- Include decision points (if X, then Y)
- Call out tools used at each step
- Be precise, not high-level

### B) Automation candidates (ranked)

Identify the top 5 parts of this workflow that are best to automate first.
Rank them by:
1) Repetition
2) Low risk
3) Clear inputs / outputs
4) Time saved

For each candidate, include:
- Why it's a good automation target
- Estimated effort: Low / Medium / High
- Estimated risk: Low / Medium / High

### C) Automation plan

For each automation candidate, propose:
1) A "quick win" automation (no-code / built-in tools)
2) A "robust" automation (workflow tool, agent, or code-based)

Also include:
- What should NOT be automated yet
- Why (human judgment, quality risk, edge cases, compliance)

### D) Visual / infographic plan

Design a visual explanation of this workflow and automation plan.
Include:
- A clear title
- Sections for: SOP, automation opportunities, what not to automate
- Suggested layout (flow diagram, columns, icons)
- Short, punchy labels suitable for an infographic or slide
Do NOT generate the image yet.
Only plan it.

### E) Clarifying questions

Ask me 5 specific questions that would help you automate this perfectly.
These should surface missing context rather than guessing"""


# Pass 2: Structured feature extraction prompt (produces JSON for ML)
EXTRACTION_PROMPT = """You are a data extraction assistant. Given the following workflow analysis, extract structured data as a JSON object.

WORKFLOW ANALYSIS:
---
{analysis_markdown}
---

Return a JSON object with exactly these fields:

{{
    "workflow_description": "A concise 1-2 sentence summary of what the user is doing in this workflow",
    "primary_app": "The application used most frequently (e.g., 'Excel', 'Outlook', 'Procore', 'Chrome', 'SAP')",
    "app_sequence": ["Ordered list of distinct applications used, in the order they first appear in the SOP"],
    "detected_actions": ["List of action types observed (e.g., 'data entry', 'copy-paste', 'form filling', 'email reading', 'file navigation', 'report generation', 'approval workflow', 'manual calculation')"],
    "automation_score": 0.0,
    "workflow_category": "One of: data_entry, reporting, communication, document_review, financial_processing, project_management, payroll, procurement, approval_workflow, other",
    "sop_step_count": 0,
    "automation_candidate_count": 0,
    "top_automation_candidate": "Name or short description of the #1 ranked automation candidate"
}}

Guidelines for automation_score (0.0 to 1.0):
- 0.0-0.3: Creative/judgment-heavy work, unique decisions each time
- 0.3-0.5: Some repetitive elements but significant human judgment needed
- 0.5-0.7: Moderately repetitive, follows patterns, some steps could be automated
- 0.7-0.85: Highly repetitive, predictable steps, strong automation candidate
- 0.85-1.0: Almost entirely mechanical, minimal judgment, ideal for full automation

For sop_step_count: Count the numbered top-level steps in Section A.
For automation_candidate_count: Count the ranked candidates in Section B.
For top_automation_candidate: Use the name/title of candidate #1 from Section B.

Return ONLY the JSON object, no additional text."""


# =============================================================================
# Video Upload
# =============================================================================


def _upload_video(video_path: str, video_id: str = "") -> object:
    """
    Upload a video file to Gemini File API and wait for processing.

    Returns the processed file object.
    Raises TimeoutError or RuntimeError on failure.
    """
    client = _get_client()

    print(f"  Uploading video to Gemini File API...")
    video_file = client.files.upload(file=video_path)
    print(f"  Upload complete, waiting for processing...")

    elapsed = 0
    while video_file.state.name == "PROCESSING":
        if elapsed >= VIDEO_UPLOAD_TIMEOUT:
            # Clean up the stuck file
            try:
                client.files.delete(name=video_file.name)
            except Exception:
                pass
            raise TimeoutError(
                f"Video processing timed out after {VIDEO_UPLOAD_TIMEOUT}s for {video_id}"
            )
        time.sleep(VIDEO_UPLOAD_POLL_INTERVAL)
        elapsed += VIDEO_UPLOAD_POLL_INTERVAL
        video_file = client.files.get(name=video_file.name)

    if video_file.state.name == "FAILED":
        raise RuntimeError(f"Video processing failed for {video_id}")

    print(f"  Video processed successfully")
    return video_file


# =============================================================================
# Markdown Parsing
# =============================================================================


def _parse_markdown_response(markdown_text: str) -> dict:
    """
    Split the Gemini markdown response into sections A-E.

    Returns dict with keys: sop, automation_candidates, automation_plan,
    visual_plan, clarifying_questions, raw
    """
    sections = {
        "sop": "",
        "automation_candidates": "",
        "automation_plan": "",
        "visual_plan": "",
        "clarifying_questions": "",
        "raw": markdown_text,
    }

    section_map = {
        "A": "sop",
        "B": "automation_candidates",
        "C": "automation_plan",
        "D": "visual_plan",
        "E": "clarifying_questions",
    }

    # Match section headers like "### A)", "## A)", "### A."
    pattern = r'#{2,3}\s*([A-E])\s*\)'
    matches = list(re.finditer(pattern, markdown_text))

    for i, match in enumerate(matches):
        letter = match.group(1)
        key = section_map.get(letter)
        if not key:
            continue

        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(markdown_text)
        sections[key] = markdown_text[start:end].strip()

    return sections


# =============================================================================
# Analysis (Two-Pass with Quality Check)
# =============================================================================


def analyze_video(
    video_path: str,
    task_description: str,
    video_id: str = "",
) -> Optional[dict]:
    """
    Upload video to Gemini and perform two-pass analysis.

    Pass 1: Rich markdown analysis (SOP, automation candidates, etc.)
    Quality check: Evaluate Pass 1 results before continuing
    Pass 2: Structured JSON extraction (only if Pass 1 shows useful content)

    Args:
        video_path: Path to the MP4 video file.
        task_description: The user's stated task from the filename.
        video_id: Identifier for logging.

    Returns:
        Dict with:
            "markdown": str -- full Pass 1 response
            "sections": dict -- parsed A-E sections
            "structured": dict -- Pass 2 JSON for CSV/ML
            "is_useful": bool -- True if quality check passed
            "rejection_reason": str -- Why it was rejected (if is_useful=False)
        None on failure.
    """
    _ensure_configured()

    if not os.path.isfile(video_path):
        print(f"[ERROR] Video file not found: {video_path}")
        return None

    client = _get_client()
    video_file = None

    try:
        # --- Upload video ---
        video_file = _upload_video(video_path, video_id)

        # --- Pass 1: Rich analysis ---
        print(f"  Pass 1: Analyzing workflow (SOP + automation)...")
        prompt = ANALYSIS_PROMPT.format(task_description=task_description)

        markdown_text = _call_gemini(
            client=client,
            contents=[video_file, prompt],
            video_id=video_id,
            pass_name="Pass 1",
            use_json=False,
        )

        if not markdown_text:
            return None

        sections = _parse_markdown_response(markdown_text)

        # --- Quick Pass 2 to check quality (cheaper than separate validation) ---
        print(f"  Pass 2: Extracting structured features...")
        extraction_prompt = EXTRACTION_PROMPT.format(analysis_markdown=markdown_text)

        json_text = _call_gemini(
            client=client,
            contents=[extraction_prompt],
            video_id=video_id,
            pass_name="Pass 2",
            use_json=True,
        )

        structured = _parse_json_response(json_text, video_id) if json_text else _empty_structured()

        # --- Quality Check: Is this a useful workflow recording? ---
        quality_check = _check_analysis_quality(structured)
        
        if not quality_check["is_useful"]:
            print(f"  Quality check FAILED: {quality_check['reason']}")
            return {
                "markdown": markdown_text,
                "sections": sections,
                "structured": structured,
                "is_useful": False,
                "rejection_reason": quality_check["reason"],
            }

        print(f"  Quality check PASSED: Useful workflow detected")
        return {
            "markdown": markdown_text,
            "sections": sections,
            "structured": structured,
            "is_useful": True,
            "rejection_reason": "",
        }

    except (TimeoutError, RuntimeError) as e:
        print(f"[ERROR] {e}")
        return None

    finally:
        # Clean up uploaded file
        if video_file:
            try:
                client.files.delete(name=video_file.name)
            except Exception:
                pass


def _call_gemini(
    client,
    contents: list,
    video_id: str,
    pass_name: str,
    use_json: bool,
) -> Optional[str]:
    """
    Call Gemini with retry logic. Returns the response text or None.
    """
    config = types.GenerateContentConfig(
        temperature=0.2,
    )
    if use_json:
        config = types.GenerateContentConfig(
            response_mime_type="application/json",
            temperature=0.2,
        )

    last_error = None
    for attempt in range(1, MAX_API_RETRIES + 1):
        try:
            response = client.models.generate_content(
                model=GEMINI_MODEL,
                contents=contents,
                config=config,
            )
            if response.text:
                return response.text

            print(f"[WARN] Empty response for {video_id} {pass_name}, attempt {attempt}/{MAX_API_RETRIES}")

        except Exception as e:
            last_error = e
            error_str = str(e).lower()

            if "429" in str(e) or "resource_exhausted" in error_str or "quota" in error_str:
                wait = RATE_LIMIT_INITIAL_BACKOFF * (2 ** (attempt - 1))
                print(f"[WARN] Rate limited on {video_id} {pass_name}, waiting {wait:.0f}s (attempt {attempt}/{MAX_API_RETRIES})")
                time.sleep(wait)
                continue

            if "safety" in error_str or "blocked" in error_str:
                print(f"[WARN] Content blocked by safety filter for {video_id} {pass_name}: {e}")
                return None

            print(f"[WARN] Gemini API error for {video_id} {pass_name} (attempt {attempt}/{MAX_API_RETRIES}): {e}")
            if attempt < MAX_API_RETRIES:
                time.sleep(API_CALL_DELAY_SECONDS)

    print(f"[ERROR] All {MAX_API_RETRIES} attempts failed for {video_id} {pass_name}: {last_error}")
    return None


# =============================================================================
# JSON Parsing (Pass 2)
# =============================================================================


def _parse_json_response(response_text: str, video_id: str) -> dict:
    """Parse and validate the Pass 2 structured JSON response."""
    try:
        data = json.loads(response_text)
    except json.JSONDecodeError:
        match = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', response_text, re.DOTALL)
        if match:
            try:
                data = json.loads(match.group(1))
            except json.JSONDecodeError:
                print(f"[ERROR] Could not parse JSON from Pass 2 response for {video_id}")
                return _empty_structured()
        else:
            print(f"[ERROR] Pass 2 response is not valid JSON for {video_id}")
            return _empty_structured()

    return {
        "workflow_description": str(data.get("workflow_description", "")),
        "primary_app": str(data.get("primary_app", "Unknown")),
        "app_sequence": _ensure_json_list(data.get("app_sequence", [])),
        "detected_actions": _ensure_json_list(data.get("detected_actions", [])),
        "automation_score": _clamp_float(data.get("automation_score", 0.0), 0.0, 1.0),
        "workflow_category": str(data.get("workflow_category", "other")),
        "sop_step_count": _safe_int(data.get("sop_step_count", 0)),
        "automation_candidate_count": _safe_int(data.get("automation_candidate_count", 0)),
        "top_automation_candidate": str(data.get("top_automation_candidate", "")),
    }


def _empty_structured() -> dict:
    """Return empty structured data when analysis fails."""
    return {
        "workflow_description": "",
        "primary_app": "Unknown",
        "app_sequence": "[]",
        "detected_actions": "[]",
        "automation_score": 0.0,
        "workflow_category": "other",
        "sop_step_count": 0,
        "automation_candidate_count": 0,
        "top_automation_candidate": "",
    }


def _ensure_json_list(value) -> str:
    """Ensure value is serialized as a JSON array string."""
    if isinstance(value, list):
        return json.dumps(value)
    if isinstance(value, str):
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


def _safe_int(value) -> int:
    """Safely convert to int."""
    try:
        return int(float(value))
    except (ValueError, TypeError):
        return 0


def _check_analysis_quality(structured: dict) -> dict:
    """
    Check if the structured analysis indicates a useful workflow recording.
    
    Low-quality indicators:
    - Primary app is Unknown/N/A/empty
    - Automation score very low (< 0.3)
    - No SOP steps detected
    - No workflow description
    
    Returns:
        Dict with "is_useful" (bool) and "reason" (str)
    """
    primary_app = structured.get("primary_app", "").strip()
    automation_score = structured.get("automation_score", 0.0)
    sop_steps = structured.get("sop_step_count", 0)
    workflow_desc = structured.get("workflow_description", "").strip()
    
    # Check for clear "not useful" signals
    if primary_app in ("", "Unknown", "N/A", "None"):
        return {"is_useful": False, "reason": "No application detected"}
    
    if sop_steps == 0:
        return {"is_useful": False, "reason": "No workflow steps detected"}
    
    if automation_score < 0.3:
        return {"is_useful": False, "reason": f"Very low automation potential (score: {automation_score})"}
    
    if not workflow_desc or len(workflow_desc) < 20:
        return {"is_useful": False, "reason": "No meaningful workflow description"}
    
    # Passed quality checks
    return {"is_useful": True, "reason": ""}


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        print("Usage: python gemini_analyzer.py <video_path> <task_description>")
        print("  video_path: Path to an MP4 video file")
        print("  task_description: The user's stated task")
        sys.exit(1)

    video = sys.argv[1]
    task = sys.argv[2]

    print(f"Analyzing video: {video}")
    print(f"Task: {task}")

    result = analyze_video(video, task, "test")
    if result:
        print("\n--- Pass 1: Markdown Analysis ---")
        print(result["markdown"][:2000])
        if len(result["markdown"]) > 2000:
            print(f"\n... ({len(result['markdown'])} total characters)")

        print("\n--- Pass 2: Structured Data ---")
        print(json.dumps(result["structured"], indent=2))
    else:
        print("\nAnalysis failed.")
