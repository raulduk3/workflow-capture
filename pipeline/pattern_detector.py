"""
L7S Workflow Analysis Pipeline - Pattern Detector

DEPRECATED: This module is no longer used by the pipeline.
The whole-video Gemini analysis (sections B+C of the new prompt) now provides
richer, context-aware automation candidate ranking and planning that replaces
these rule-based pattern flags.

Kept for reference only.
"""

import json
from typing import Optional


# Pattern definitions
PATTERNS = {
    "copy_paste_heavy": {
        "label": "Copy-Paste Heavy",
        "emoji": "🔄",
        "description": "3+ copy-paste actions detected — manual data transfer between systems",
        "action": "Integration or automation between apps",
    },
    "app_switch_loop": {
        "label": "App Switch Loop",
        "emoji": "🔀",
        "description": "6+ apps in sequence — fragmented workflow, context switching",
        "action": "Unified dashboard or consolidated tool",
    },
    "high_friction": {
        "label": "High Friction",
        "emoji": "⚠️",
        "description": "3+ friction events — user is struggling with this task",
        "action": "Priority investigation, possible training",
    },
    "automation_ready": {
        "label": "Automation Ready",
        "emoji": "🤖",
        "description": "Score >= 0.75 — highly repetitive, predictable workflow",
        "action": "Strong candidate for RPA or Gemini automation",
    },
}


def detect_patterns(analysis: dict) -> str:
    """
    Apply rule-based pattern detection to a Gemini analysis result.

    Args:
        analysis: Dict from gemini_analyzer.analyze_video() containing
                  app_sequence, detected_actions, friction_events,
                  automation_score.

    Returns:
        Comma-separated string of triggered pattern keys.
        Empty string if no patterns match.
    """
    if not analysis:
        return ""

    triggered = []

    # --- Copy-Paste Heavy ---
    actions = _parse_json_list(analysis.get("detected_actions", "[]"))
    copy_paste_count = sum(
        1 for action in actions
        if any(term in action.lower() for term in ["copy-paste", "copy paste", "copy/paste", "copy and paste"])
    )
    if copy_paste_count >= 3:
        triggered.append("copy_paste_heavy")

    # --- App Switch Loop ---
    apps = _parse_json_list(analysis.get("app_sequence", "[]"))
    if len(apps) >= 6:
        triggered.append("app_switch_loop")

    # --- High Friction ---
    friction = _parse_json_list(analysis.get("friction_events", "[]"))
    friction_count = analysis.get("friction_count", len(friction))
    if isinstance(friction_count, str):
        try:
            friction_count = int(friction_count)
        except ValueError:
            friction_count = len(friction)
    if friction_count >= 3:
        triggered.append("high_friction")

    # --- Automation Ready ---
    score = analysis.get("automation_score", 0.0)
    if isinstance(score, str):
        try:
            score = float(score)
        except ValueError:
            score = 0.0
    if score >= 0.75:
        triggered.append("automation_ready")

    return ",".join(triggered)


def get_pattern_details(flags_str: str) -> list[dict]:
    """
    Get full details for triggered pattern flags.

    Args:
        flags_str: Comma-separated pattern keys from detect_patterns().

    Returns:
        List of pattern detail dicts with label, emoji, description, action.
    """
    if not flags_str:
        return []

    details = []
    for key in flags_str.split(","):
        key = key.strip()
        if key in PATTERNS:
            details.append(PATTERNS[key])

    return details


def summarize_patterns(all_flags: list[str]) -> dict:
    """
    Aggregate pattern flags across all analyzed videos.

    Args:
        all_flags: List of flags strings from detect_patterns().

    Returns:
        Dict with pattern_key -> count of videos triggering each pattern.
    """
    counts = {key: 0 for key in PATTERNS}
    total_flagged = 0

    for flags_str in all_flags:
        if not flags_str:
            continue
        flagged = False
        for key in flags_str.split(","):
            key = key.strip()
            if key in counts:
                counts[key] += 1
                flagged = True
        if flagged:
            total_flagged += 1

    return {
        "pattern_counts": counts,
        "total_flagged": total_flagged,
        "total_analyzed": len(all_flags),
    }


def _parse_json_list(value) -> list:
    """Parse a value that may be a JSON string, a list, or something else."""
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, list):
                return parsed
        except json.JSONDecodeError:
            pass
        # Single value
        if value and value != "[]":
            return [value]
    return []


if __name__ == "__main__":
    # Test with sample analysis results
    test_cases = [
        {
            "name": "High automation + lots of copy-paste",
            "analysis": {
                "app_sequence": '["Excel", "SAP", "Excel", "Outlook"]',
                "detected_actions": '["copy-paste", "data entry", "copy-paste", "copy-paste", "form filling"]',
                "friction_events": '["manual data re-entry between systems"]',
                "automation_score": 0.82,
            },
        },
        {
            "name": "App switching nightmare",
            "analysis": {
                "app_sequence": '["Excel", "Chrome", "SAP", "Outlook", "Teams", "Chrome", "Excel"]',
                "detected_actions": '["navigation", "data entry"]',
                "friction_events": '["context switching", "repeated login", "data lookup", "manual transfer"]',
                "automation_score": 0.65,
            },
        },
        {
            "name": "Clean workflow",
            "analysis": {
                "app_sequence": '["Procore"]',
                "detected_actions": '["form filling", "document review"]',
                "friction_events": '[]',
                "automation_score": 0.3,
            },
        },
    ]

    for tc in test_cases:
        flags = detect_patterns(tc["analysis"])
        details = get_pattern_details(flags)
        print(f"\n{tc['name']}:")
        print(f"  Flags: {flags or '(none)'}")
        for d in details:
            print(f"  {d['emoji']} {d['label']}: {d['description']}")
