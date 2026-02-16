"""
L7S Workflow Analysis Pipeline - Insights Report Generator

Reads the analysis CSV and per-video markdown files to produce an aggregate
insights report. Report sections:
  1. Volume Summary
  2. Workflow Inventory
  3. Automation Landscape
  4. SOP Complexity Overview
  5. Application Insights
  6. User-Specific Findings
  7. Detailed Analysis Links
  8. Cross-Video Automation Themes
"""

import json
import os
from collections import Counter
from datetime import datetime

import pandas as pd

from config import ANALYSIS_CSV, REPORTS_DIR
from gemini_analyzer import _parse_markdown_response


def generate_report(
    csv_path: str = ANALYSIS_CSV,
    output_dir: str = REPORTS_DIR,
) -> str:
    """
    Generate a markdown insights report from the analysis CSV.

    Returns:
        Path to the generated report file.
    """
    if not os.path.isfile(csv_path):
        print(f"[ERROR] Analysis CSV not found: {csv_path}")
        return ""

    df = pd.read_csv(csv_path)

    if df.empty:
        print("[WARN] Analysis CSV is empty. No report to generate.")
        return ""

    os.makedirs(output_dir, exist_ok=True)

    date_str = datetime.now().strftime("%Y-%m-%d")
    report_path = os.path.join(output_dir, f"insights_{date_str}.md")

    sections = []
    sections.append(_header(df))
    sections.append(_volume_summary(df))
    sections.append(_workflow_inventory(df))
    sections.append(_automation_landscape(df))
    sections.append(_sop_complexity(df))
    sections.append(_application_insights(df))
    sections.append(_user_findings(df))
    sections.append(_analysis_links(df))
    sections.append(_cross_video_themes(df))
    sections.append(_footer())

    report_content = "\n\n".join(sections)

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

    if "duration_sec" in df.columns:
        valid_durations = df["duration_sec"][df["duration_sec"] > 0]
        total_seconds = valid_durations.sum()
        total_hours = total_seconds / 3600
        avg_duration_min = valid_durations.mean() / 60 if len(valid_durations) > 0 else 0
    else:
        total_hours = 0
        avg_duration_min = 0

    if "timestamp" in df.columns:
        earliest = df["timestamp"].min()
        latest = df["timestamp"].max()
        date_range = f"{earliest} to {latest}"
    else:
        date_range = "Unknown"

    user_lines = ""
    if "username" in df.columns:
        user_counts = df["username"].value_counts()
        user_lines = "\n".join(
            f"| {user} | {count} | {count/total_videos*100:.0f}% |"
            for user, count in user_counts.items()
        )

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


def _workflow_inventory(df: pd.DataFrame) -> str:
    lines = ["## 2. Workflow Inventory"]
    lines.append(f"\n**Total workflows analyzed:** {len(df)}")
    lines.append("\n| User | Task | Duration | App | Score | SOP Steps | Top Candidate | Summary |")
    lines.append("|------|------|----------|-----|-------|-----------|---------------|---------|")

    for _, row in df.iterrows():
        user = row.get("username", "")
        task = _truncate(row.get("task_description", ""), 30)
        duration = f"{_safe_float(row.get('duration_sec', 0))/60:.1f}m" if _safe_float(row.get('duration_sec', 0)) > 0 else "-"
        app = _truncate(row.get("primary_app", ""), 15)
        score = f"{_safe_float(row.get('automation_score', 0)):.2f}"
        sop = str(_safe_int(row.get("sop_step_count", 0)))
        candidate = _truncate(row.get("top_automation_candidate", ""), 25)
        summary = _truncate(row.get("workflow_description", ""), 40)

        lines.append(f"| {user} | {task} | {duration} | {app} | {score} | {sop} | {candidate} | {summary} |")

    return "\n".join(lines)


def _automation_landscape(df: pd.DataFrame) -> str:
    lines = ["## 3. Automation Landscape"]

    if "automation_score" not in df.columns:
        lines.append("\n*No automation data available.*")
        return "\n".join(lines)

    df_scored = df.copy()
    df_scored["score_float"] = df_scored["automation_score"].apply(_safe_float)

    # Top automation candidates across all videos
    if "top_automation_candidate" in df.columns:
        candidates = df["top_automation_candidate"].dropna().tolist()
        candidates = [c for c in candidates if c and c != ""]
        if candidates:
            candidate_counts = Counter(candidates)
            lines.append("\n### Most Common Automation Candidates\n")
            lines.append("| Automation Candidate | Appearances | Avg Score |")
            lines.append("|---------------------|-------------|-----------|")
            for candidate, count in candidate_counts.most_common(10):
                matching = df_scored[df_scored["top_automation_candidate"] == candidate]
                avg_score = matching["score_float"].mean()
                lines.append(f"| {_truncate(candidate, 50)} | {count} | {avg_score:.2f} |")

    # Top scoring workflows
    auto_ready = df_scored[df_scored["score_float"] >= 0.7].sort_values("score_float", ascending=False)
    if auto_ready.empty:
        lines.append("\n*No workflows scored 0.7+ for automation potential.*")
    else:
        lines.append(f"\n### Top Automation Candidates ({len(auto_ready)} workflows scoring >= 0.7)\n")
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

    # Score distribution
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


def _sop_complexity(df: pd.DataFrame) -> str:
    lines = ["## 4. SOP Complexity Overview"]

    if "sop_step_count" not in df.columns:
        lines.append("\n*No SOP data available.*")
        return "\n".join(lines)

    df_sop = df.copy()
    df_sop["steps"] = df_sop["sop_step_count"].apply(_safe_int)
    valid = df_sop[df_sop["steps"] > 0]

    if valid.empty:
        lines.append("\n*No SOP step data available.*")
        return "\n".join(lines)

    avg_steps = valid["steps"].mean()
    max_steps = valid["steps"].max()
    min_steps = valid["steps"].min()

    lines.append(f"\n| Metric | Value |")
    lines.append(f"|--------|-------|")
    lines.append(f"| Average SOP steps | {avg_steps:.1f} |")
    lines.append(f"| Most complex (max steps) | {max_steps} |")
    lines.append(f"| Simplest (min steps) | {min_steps} |")

    # Most complex workflows
    top_complex = valid.nlargest(10, "steps")
    lines.append("\n### Most Complex Workflows\n")
    lines.append("| User | Task | SOP Steps | Auto Score | App |")
    lines.append("|------|------|-----------|------------|-----|")
    for _, row in top_complex.iterrows():
        lines.append(
            f"| {row.get('username', '')} "
            f"| {_truncate(row.get('task_description', ''), 40)} "
            f"| {row['steps']} "
            f"| {_safe_float(row.get('automation_score', 0)):.2f} "
            f"| {row.get('primary_app', '')} |"
        )

    # Step count distribution
    bins_steps = [(1, 5, "Simple (1-5)"), (6, 10, "Moderate (6-10)"), (11, 20, "Complex (11-20)"), (21, 999, "Very Complex (21+)")]
    lines.append("\n### Complexity Distribution\n")
    lines.append("| Range | Videos | % |")
    lines.append("|-------|--------|---|")
    total = len(valid)
    for low, high, label in bins_steps:
        count = len(valid[(valid["steps"] >= low) & (valid["steps"] <= high)])
        pct = count / total * 100 if total > 0 else 0
        lines.append(f"| {label} | {count} | {pct:.0f}% |")

    return "\n".join(lines)


def _application_insights(df: pd.DataFrame) -> str:
    lines = ["## 5. Application Insights"]

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

    # Apps by automation score
    if "automation_score" in df.columns:
        app_scores = df.groupby("primary_app")["automation_score"].apply(
            lambda x: x.apply(_safe_float).mean()
        ).sort_values(ascending=False)

        lines.append("\n### Applications by Average Automation Score\n")
        lines.append("| Application | Avg Score | Videos |")
        lines.append("|-------------|-----------|--------|")
        for app, avg_s in app_scores.head(10).items():
            count = len(df[df["primary_app"] == app])
            lines.append(f"| {app} | {avg_s:.2f} | {count} |")

    # Co-occurring apps
    if "app_sequence" in df.columns:
        app_pairs = Counter()
        for seq_str in df["app_sequence"].dropna():
            apps = _parse_json_field(seq_str)
            unique_apps = list(dict.fromkeys(apps))
            for i in range(len(unique_apps)):
                for j in range(i + 1, len(unique_apps)):
                    pair = tuple(sorted([unique_apps[i], unique_apps[j]]))
                    app_pairs[pair] += 1

        if app_pairs:
            lines.append("\n### Frequently Co-Occurring Applications\n")
            lines.append("| App 1 | App 2 | Videos Together |")
            lines.append("|-------|-------|-----------------|")
            for (a, b), count in app_pairs.most_common(10):
                lines.append(f"| {a} | {b} | {count} |")

    return "\n".join(lines)


def _user_findings(df: pd.DataFrame) -> str:
    lines = ["## 6. User-Specific Findings"]

    if "username" not in df.columns:
        lines.append("\n*No user data available.*")
        return "\n".join(lines)

    has_score = "automation_score" in df.columns
    has_sop = "sop_step_count" in df.columns

    if not has_score and not has_sop:
        lines.append("\n*No analysis data available for user comparison.*")
        return "\n".join(lines)

    lines.append("\n### User Overview\n")
    header = "| User | Videos | "
    if has_score:
        header += "Avg Auto Score | "
    if has_sop:
        header += "Avg SOP Steps | "
    header += "Top App |"
    lines.append(header)

    sep = "|------|--------|"
    if has_score:
        sep += "---------------|"
    if has_sop:
        sep += "--------------|"
    sep += "---------|"
    lines.append(sep)

    for user in df["username"].unique():
        user_df = df[df["username"] == user]
        count = len(user_df)
        top_app = user_df["primary_app"].mode().iloc[0] if "primary_app" in user_df.columns and not user_df["primary_app"].dropna().empty else ""

        row_str = f"| {user} | {count} | "
        if has_score:
            avg_s = user_df["automation_score"].apply(_safe_float).mean()
            row_str += f"{avg_s:.2f} | "
        if has_sop:
            avg_steps = user_df["sop_step_count"].apply(_safe_int).mean()
            row_str += f"{avg_steps:.1f} | "
        row_str += f"{top_app} |"
        lines.append(row_str)

    return "\n".join(lines)


def _analysis_links(df: pd.DataFrame) -> str:
    lines = ["## 7. Detailed Analysis Files"]

    if "analysis_md_path" not in df.columns:
        lines.append("\n*No per-video analysis files available.*")
        return "\n".join(lines)

    analyses = df[df["analysis_md_path"].notna() & (df["analysis_md_path"] != "")]

    if analyses.empty:
        lines.append("\n*No per-video analysis files found.*")
        return "\n".join(lines)

    lines.append(f"\n**{len(analyses)}** videos have detailed markdown analyses.\n")
    lines.append("| User | Task | Score | Analysis File |")
    lines.append("|------|------|-------|---------------|")

    for _, row in analyses.iterrows():
        user = row.get("username", "")
        task = _truncate(row.get("task_description", ""), 35)
        score = f"{_safe_float(row.get('automation_score', 0)):.2f}"
        md_path = row.get("analysis_md_path", "")
        filename = os.path.basename(md_path) if md_path else ""
        lines.append(f"| {user} | {task} | {score} | {filename} |")

    return "\n".join(lines)


def _cross_video_themes(df: pd.DataFrame) -> str:
    lines = ["## 8. Cross-Video Automation Themes"]

    if "analysis_md_path" not in df.columns:
        lines.append("\n*No per-video analyses available for theme extraction.*")
        return "\n".join(lines)

    analyses = df[df["analysis_md_path"].notna() & (df["analysis_md_path"] != "")]

    if analyses.empty:
        lines.append("\n*No analysis files to extract themes from.*")
        return "\n".join(lines)

    # Read each markdown file and extract Section B (automation candidates)
    all_candidates = []
    for _, row in analyses.iterrows():
        md_path = row.get("analysis_md_path", "")
        if not md_path or not os.path.isfile(md_path):
            continue

        try:
            with open(md_path, "r", encoding="utf-8") as f:
                content = f.read()

            # Skip YAML front matter
            if content.startswith("---"):
                end_idx = content.find("---", 3)
                if end_idx > 0:
                    content = content[end_idx + 3:]

            sections = _parse_markdown_response(content)
            candidates_text = sections.get("automation_candidates", "")
            if candidates_text:
                all_candidates.append({
                    "username": row.get("username", ""),
                    "task": row.get("task_description", ""),
                    "candidates": candidates_text,
                })
        except OSError:
            continue

    if not all_candidates:
        lines.append("\n*Could not read analysis files for theme extraction.*")
        return "\n".join(lines)

    lines.append(f"\nExtracted automation candidates from **{len(all_candidates)}** analyses.\n")

    # Show per-video candidate summaries
    for entry in all_candidates:
        lines.append(f"### {entry['username']} — {_truncate(entry['task'], 50)}\n")
        # Show first ~500 chars of candidates section
        preview = entry["candidates"][:500]
        if len(entry["candidates"]) > 500:
            preview += "\n\n*(truncated)*"
        lines.append(preview)
        lines.append("")

    return "\n".join(lines)


def _footer() -> str:
    return f"""---

*Report generated by L7S Workflow Analysis Pipeline on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*
*Data source: Gemini whole-video analysis of screen recordings collected via L7S Workflow Capture*
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
