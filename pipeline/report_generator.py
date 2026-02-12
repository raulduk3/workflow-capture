"""
L7S Workflow Analysis Pipeline - Insights Report Generator

Reads the analysis CSV and produces the Day 7 deliverable report as markdown.
Report sections per VIDEO_TO_INSIGHTS_PIPELINE.md section 8.1:
  1. Volume Summary
  2. Top Friction Points
  3. Automation Opportunities
  4. Application Insights
  5. User-Specific Findings
  6. Gemini Integration Recommendations
"""

import csv
import json
import os
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

import pandas as pd

from config import ANALYSIS_CSV, REPORTS_DIR
from pattern_detector import PATTERNS, get_pattern_details


def generate_report(
    csv_path: str = ANALYSIS_CSV,
    output_dir: str = REPORTS_DIR,
) -> str:
    """
    Generate a markdown insights report from the analysis CSV.

    Returns:
        Path to the generated report file.
    """
    # Load data
    if not os.path.isfile(csv_path):
        print(f"[ERROR] Analysis CSV not found: {csv_path}")
        return ""

    df = pd.read_csv(csv_path)

    if df.empty:
        print("[WARN] Analysis CSV is empty. No report to generate.")
        return ""

    # Ensure output directory exists
    os.makedirs(output_dir, exist_ok=True)

    # Generate report filename
    date_str = datetime.now().strftime("%Y-%m-%d")
    report_path = os.path.join(output_dir, f"insights_{date_str}.md")

    # Build report sections
    sections = []
    sections.append(_header(df))
    sections.append(_volume_summary(df))
    sections.append(_top_friction_points(df))
    sections.append(_automation_opportunities(df))
    sections.append(_application_insights(df))
    sections.append(_user_findings(df))
    sections.append(_gemini_recommendations(df))
    sections.append(_footer())

    report_content = "\n\n".join(sections)

    # Write report
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report_content)

    print(f"[INFO] Report generated: {report_path}")
    return report_path


# =============================================================================
# Report Sections
# =============================================================================


def _header(df: pd.DataFrame) -> str:
    date_str = datetime.now().strftime("%B %d, %Y")
    return f"""# Workflow Analysis — Insights Report

**Generated:** {date_str}
**Source:** L7S Workflow Capture Analysis Pipeline
**Author:** Layer 7 Systems — Automated Report

---"""


def _volume_summary(df: pd.DataFrame) -> str:
    total_videos = len(df)
    unique_users = df["username"].nunique() if "username" in df.columns else 0
    unique_machines = df["machine_id"].nunique() if "machine_id" in df.columns else 0

    # Total recording hours
    if "duration_sec" in df.columns:
        valid_durations = df["duration_sec"][df["duration_sec"] > 0]
        total_seconds = valid_durations.sum()
        total_hours = total_seconds / 3600
        avg_duration_min = valid_durations.mean() / 60 if len(valid_durations) > 0 else 0
    else:
        total_hours = 0
        avg_duration_min = 0

    # Date range
    if "timestamp" in df.columns:
        earliest = df["timestamp"].min()
        latest = df["timestamp"].max()
        date_range = f"{earliest} to {latest}"
    else:
        date_range = "Unknown"

    # User list
    if "username" in df.columns:
        user_counts = df["username"].value_counts()
        user_lines = "\n".join(
            f"| {user} | {count} | {count/total_videos*100:.0f}% |"
            for user, count in user_counts.items()
        )
    else:
        user_lines = ""

    return f"""## 1. Volume Summary

| Metric | Value |
|--------|-------|
| Total videos analyzed | {total_videos} |
| Unique users | {unique_users} |
| Unique workstations | {unique_machines} |
| Total recording time | {total_hours:.1f} hours |
| Average recording length | {avg_duration_min:.1f} minutes |
| Date range | {date_range} |

### Recordings by User

| User | Videos | % of Total |
|------|--------|------------|
{user_lines}"""


def _top_friction_points(df: pd.DataFrame) -> str:
    lines = ["## 2. Top Friction Points (Priority)"]

    # Videos with highest friction counts
    if "friction_count" not in df.columns:
        lines.append("\n*No friction data available — Gemini analysis may not have run.*")
        return "\n".join(lines)

    df_friction = df[df["friction_count"].apply(_safe_int) > 0].copy()
    df_friction["friction_count_int"] = df_friction["friction_count"].apply(_safe_int)

    if df_friction.empty:
        lines.append("\n*No friction events detected across analyzed videos.*")
        return "\n".join(lines)

    total_friction = df_friction["friction_count_int"].sum()
    avg_friction = df["friction_count"].apply(_safe_int).mean()

    lines.append(f"\n**Total friction events detected:** {total_friction}")
    lines.append(f"**Average friction events per video:** {avg_friction:.1f}")

    # Top friction videos
    top_friction = df_friction.nlargest(10, "friction_count_int")
    lines.append("\n### Highest-Friction Workflows\n")
    lines.append("| User | Task | Friction Events | App | Score |")
    lines.append("|------|------|-----------------|-----|-------|")

    for _, row in top_friction.iterrows():
        lines.append(
            f"| {row.get('username', '')} "
            f"| {_truncate(row.get('task_description', ''), 40)} "
            f"| {_safe_int(row.get('friction_count', 0))} "
            f"| {row.get('primary_app', '')} "
            f"| {_safe_float(row.get('automation_score', 0)):.2f} |"
        )

    # Friction by user
    if "username" in df.columns:
        user_friction = df.groupby("username")["friction_count"].apply(
            lambda x: x.apply(_safe_int).sum()
        ).sort_values(ascending=False)

        lines.append("\n### Friction by User\n")
        lines.append("| User | Total Friction Events | Avg per Video |")
        lines.append("|------|----------------------|---------------|")
        for user, total in user_friction.items():
            count = len(df[df["username"] == user])
            avg = total / count if count > 0 else 0
            lines.append(f"| {user} | {total} | {avg:.1f} |")

    # Common friction event descriptions
    all_friction = []
    if "friction_events" in df.columns:
        for events_str in df["friction_events"].dropna():
            parsed = _parse_json_field(events_str)
            all_friction.extend(parsed)

    if all_friction:
        friction_counts = Counter(all_friction).most_common(10)
        lines.append("\n### Most Common Friction Events\n")
        lines.append("| Friction Event | Occurrences |")
        lines.append("|----------------|-------------|")
        for event, count in friction_counts:
            lines.append(f"| {_truncate(event, 60)} | {count} |")

    return "\n".join(lines)


def _automation_opportunities(df: pd.DataFrame) -> str:
    lines = ["## 3. Automation Opportunities"]

    if "automation_score" not in df.columns:
        lines.append("\n*No automation score data — Gemini analysis may not have run.*")
        return "\n".join(lines)

    df_scored = df.copy()
    df_scored["score_float"] = df_scored["automation_score"].apply(_safe_float)

    # Pattern flag summary
    if "pattern_flags" in df.columns:
        flag_values = df["pattern_flags"].dropna().tolist()
        all_flags = []
        for f in flag_values:
            if f:
                all_flags.extend(f.split(","))

        flag_counts = Counter(all_flags)
        if flag_counts:
            lines.append("\n### Pattern Summary\n")
            lines.append("| Pattern | Videos Flagged | Description |")
            lines.append("|---------|---------------|-------------|")
            for key, count in flag_counts.most_common():
                key = key.strip()
                info = PATTERNS.get(key, {})
                label = info.get("label", key)
                emoji = info.get("emoji", "")
                desc = info.get("action", "")
                lines.append(f"| {emoji} {label} | {count} | {desc} |")

    # Top automation candidates
    auto_ready = df_scored[df_scored["score_float"] >= 0.7].sort_values("score_float", ascending=False)

    if auto_ready.empty:
        lines.append("\n*No workflows scored 0.7+ for automation potential.*")
    else:
        lines.append(f"\n### Top Automation Candidates ({len(auto_ready)} workflows scoring ≥ 0.7)\n")
        lines.append("| User | Task | Score | App | Category |")
        lines.append("|------|------|-------|-----|----------|")
        for _, row in auto_ready.head(15).iterrows():
            lines.append(
                f"| {row.get('username', '')} "
                f"| {_truncate(row.get('task_description', ''), 40)} "
                f"| {row['score_float']:.2f} "
                f"| {row.get('primary_app', '')} "
                f"| {row.get('workflow_category', '')} |"
            )

    # Automation score distribution
    bins = [(0, 0.3, "Low"), (0.3, 0.5, "Moderate"), (0.5, 0.7, "Medium"), (0.7, 0.85, "High"), (0.85, 1.01, "Very High")]
    lines.append("\n### Automation Score Distribution\n")
    lines.append("| Range | Level | Videos | % |")
    lines.append("|-------|-------|--------|---|")
    total = len(df_scored)
    for low, high, label in bins:
        count = len(df_scored[(df_scored["score_float"] >= low) & (df_scored["score_float"] < high)])
        pct = count / total * 100 if total > 0 else 0
        lines.append(f"| {low:.1f}–{high:.2f} | {label} | {count} | {pct:.0f}% |")

    return "\n".join(lines)


def _application_insights(df: pd.DataFrame) -> str:
    lines = ["## 4. Application Insights"]

    if "primary_app" not in df.columns or df["primary_app"].dropna().empty:
        lines.append("\n*No application data available.*")
        return "\n".join(lines)

    # Most-used apps
    app_counts = df["primary_app"].value_counts()
    lines.append("\n### Most-Used Applications\n")
    lines.append("| Application | Videos | % of Total |")
    lines.append("|-------------|--------|------------|")
    total = len(df)
    for app, count in app_counts.head(15).items():
        lines.append(f"| {app} | {count} | {count/total*100:.0f}% |")

    # Apps by friction
    if "friction_count" in df.columns:
        app_friction = df.groupby("primary_app")["friction_count"].apply(
            lambda x: x.apply(_safe_int).mean()
        ).sort_values(ascending=False)

        lines.append("\n### Applications by Average Friction\n")
        lines.append("| Application | Avg Friction Events | Videos |")
        lines.append("|-------------|--------------------:|--------|")
        for app, avg_f in app_friction.head(10).items():
            count = len(df[df["primary_app"] == app])
            lines.append(f"| {app} | {avg_f:.1f} | {count} |")

    # Co-occurring apps (from app_sequence)
    if "app_sequence" in df.columns:
        app_pairs = Counter()
        for seq_str in df["app_sequence"].dropna():
            apps = _parse_json_field(seq_str)
            unique_apps = list(dict.fromkeys(apps))  # preserve order, remove dups
            for i in range(len(unique_apps)):
                for j in range(i + 1, len(unique_apps)):
                    pair = tuple(sorted([unique_apps[i], unique_apps[j]]))
                    app_pairs[pair] += 1

        if app_pairs:
            lines.append("\n### Frequently Co-Occurring Applications (Integration Candidates)\n")
            lines.append("| App 1 | App 2 | Videos Together |")
            lines.append("|-------|-------|-----------------|")
            for (a, b), count in app_pairs.most_common(10):
                lines.append(f"| {a} | {b} | {count} |")

    return "\n".join(lines)


def _user_findings(df: pd.DataFrame) -> str:
    lines = ["## 5. User-Specific Findings"]

    if "username" not in df.columns:
        lines.append("\n*No user data available.*")
        return "\n".join(lines)

    has_friction = "friction_count" in df.columns
    has_score = "automation_score" in df.columns

    if not has_friction and not has_score:
        lines.append("\n*No analysis data available for user comparison.*")
        return "\n".join(lines)

    # Per-user summary
    lines.append("\n### User Overview\n")
    header = "| User | Videos | "
    if has_friction:
        header += "Avg Friction | "
    if has_score:
        header += "Avg Auto Score | "
    header += "Top App |"
    lines.append(header)

    sep = "|------|--------|"
    if has_friction:
        sep += "-------------|"
    if has_score:
        sep += "---------------|"
    sep += "---------|"
    lines.append(sep)

    for user in df["username"].unique():
        user_df = df[df["username"] == user]
        count = len(user_df)
        top_app = user_df["primary_app"].mode().iloc[0] if "primary_app" in user_df.columns and not user_df["primary_app"].dropna().empty else ""

        row_str = f"| {user} | {count} | "
        if has_friction:
            avg_f = user_df["friction_count"].apply(_safe_int).mean()
            row_str += f"{avg_f:.1f} | "
        if has_score:
            avg_s = user_df["automation_score"].apply(_safe_float).mean()
            row_str += f"{avg_s:.2f} | "
        row_str += f"{top_app} |"
        lines.append(row_str)

    # Highest friction users (may need training)
    if has_friction:
        user_total_friction = df.groupby("username")["friction_count"].apply(
            lambda x: x.apply(_safe_int).sum()
        ).sort_values(ascending=False)

        if user_total_friction.iloc[0] > 0:
            lines.append("\n### Users with Highest Total Friction (May Need Support/Training)")
            lines.append("")
            for user, total in user_total_friction.head(5).items():
                if total == 0:
                    break
                lines.append(f"- **{user}**: {total} total friction events")

    # Smoothest workflows (best practices)
    if has_friction:
        user_avg_friction = df.groupby("username")["friction_count"].apply(
            lambda x: x.apply(_safe_int).mean()
        ).sort_values()

        lines.append("\n### Users with Smoothest Workflows (Possible Best Practices)")
        lines.append("")
        for user, avg in user_avg_friction.head(3).items():
            lines.append(f"- **{user}**: {avg:.1f} avg friction events per recording")

    return "\n".join(lines)


def _gemini_recommendations(df: pd.DataFrame) -> str:
    lines = ["## 6. Gemini Integration Recommendations"]

    has_analysis = "automation_score" in df.columns and df["automation_score"].apply(_safe_float).sum() > 0

    if not has_analysis:
        lines.append("\n*Gemini analysis has not been run yet. Recommendations will be available after processing.*")
        lines.append("\nTo run analysis: `python run_pipeline.py`")
        return "\n".join(lines)

    # Find specific opportunities
    df_copy = df.copy()
    df_copy["score_float"] = df_copy["automation_score"].apply(_safe_float)

    # Group by task description similarity (exact match for now)
    task_groups = df_copy.groupby("task_description").agg(
        count=("video_id", "count"),
        avg_score=("score_float", "mean"),
        avg_friction=("friction_count", lambda x: x.apply(_safe_int).mean()),
        users=("username", lambda x: ", ".join(x.unique())),
        primary_app=("primary_app", lambda x: x.mode().iloc[0] if not x.dropna().empty else ""),
    ).sort_values("avg_score", ascending=False)

    # Filter to high-value opportunities
    opportunities = task_groups[
        (task_groups["avg_score"] >= 0.5) & (task_groups["count"] >= 1)
    ]

    if opportunities.empty:
        lines.append("\n*No high-confidence recommendations yet. More data needed.*")
        return "\n".join(lines)

    lines.append("\n### Recommended Gemini AI Integrations\n")

    for i, (task, row) in enumerate(opportunities.head(10).iterrows(), 1):
        lines.append(f"#### {i}. {task}")
        lines.append("")
        lines.append(f"- **Frequency:** {row['count']} recording(s)")
        lines.append(f"- **Users:** {row['users']}")
        lines.append(f"- **Primary App:** {row['primary_app']}")
        lines.append(f"- **Automation Score:** {row['avg_score']:.2f}")
        lines.append(f"- **Avg Friction:** {row['avg_friction']:.1f} events")

        # Suggest based on score range
        score = row["avg_score"]
        if score >= 0.85:
            lines.append(f"- **Recommendation:** Full automation candidate — build Gemini workflow to handle end-to-end")
        elif score >= 0.7:
            lines.append(f"- **Recommendation:** Strong AI assist — Gemini can handle repetitive steps, human reviews output")
        elif score >= 0.5:
            lines.append(f"- **Recommendation:** Partial automation — Gemini can pre-populate fields, suggest actions, or summarize inputs")

        lines.append("")

    # Summary recommendation
    total_high = len(df_copy[df_copy["score_float"] >= 0.7])
    total_medium = len(df_copy[(df_copy["score_float"] >= 0.5) & (df_copy["score_float"] < 0.7)])

    lines.append("### Summary")
    lines.append("")
    lines.append(f"- **{total_high}** workflows are strong automation candidates (score ≥ 0.7)")
    lines.append(f"- **{total_medium}** workflows could benefit from partial AI assistance (score 0.5–0.7)")
    lines.append(f"- Focus AI deployment on high-frequency, high-score tasks for maximum ROI")

    return "\n".join(lines)


def _footer() -> str:
    return f"""---

*Report generated by L7S Workflow Analysis Pipeline on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*
*Data source: Gemini Vision analysis of screen recordings collected via L7S Workflow Capture*
*Layer 7 Systems — ML Engineering*"""


# =============================================================================
# Helpers
# =============================================================================


def _safe_int(value) -> int:
    try:
        return int(float(value))
    except (ValueError, TypeError):
        return 0


def _safe_float(value) -> float:
    try:
        return float(value)
    except (ValueError, TypeError):
        return 0.0


def _truncate(text: str, max_len: int) -> str:
    if not text:
        return ""
    text = str(text)
    if len(text) <= max_len:
        return text
    return text[:max_len - 3] + "..."


def _parse_json_field(value) -> list:
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, list):
                return parsed
        except (json.JSONDecodeError, TypeError):
            pass
    return []


if __name__ == "__main__":
    import sys

    csv_file = sys.argv[1] if len(sys.argv) > 1 else ANALYSIS_CSV
    print(f"Generating report from: {csv_file}")
    path = generate_report(csv_path=csv_file)
    if path:
        print(f"\nReport saved to: {path}")
