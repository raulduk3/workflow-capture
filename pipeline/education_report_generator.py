"""
L7S Workflow Analysis Pipeline - Education Report Generator

Reads the education CSV and per-video education markdown files to produce
an aggregate education insights report. Report sections:
  1. Volume Summary
  2. Per-User Learning Profiles
  3. AI Skill Gap Heatmap Data
  4. Most Common AI-Assistable Moments
  5. Missed Tool Features Inventory
  6. Recommended Training Curriculum
  7. Per-Video Education Details
"""

import json
import os
from collections import Counter, defaultdict
from datetime import datetime

import pandas as pd

from config import EDUCATION_CSV, REPORTS_DIR


def generate_education_report(
    csv_path: str = EDUCATION_CSV,
    output_dir: str = REPORTS_DIR,
) -> str:
    """
    Generate an education insights report from the education CSV.

    Returns:
        Path to the generated report file.
    """
    if not os.path.isfile(csv_path):
        print(f"[ERROR] Education CSV not found: {csv_path}")
        return ""

    df = pd.read_csv(csv_path)

    if df.empty:
        print("[WARN] Education CSV is empty. No report to generate.")
        return ""

    os.makedirs(output_dir, exist_ok=True)

    date_str = datetime.now().strftime("%Y-%m-%d")
    report_path = os.path.join(output_dir, f"education_insights_{date_str}.md")

    sections = []
    sections.append(_header(df))
    sections.append(_volume_summary(df))
    sections.append(_per_user_learning_profiles(df))
    sections.append(_skill_gap_heatmap(df))
    sections.append(_common_ai_assistable_moments(df))
    sections.append(_missed_tool_features_inventory(df))
    sections.append(_recommended_curriculum(df))
    sections.append(_per_video_details(df))
    sections.append(_footer())

    report_content = "\n\n".join(sections)

    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report_content)

    print(f"[INFO] Education report generated: {report_path}")
    return report_path


# =============================================================================
# Report Sections
# =============================================================================


def _header(df: pd.DataFrame) -> str:
    date_str = datetime.now().strftime("%B %d, %Y")
    return f"""# Education & Training Insights Report

**Generated:** {date_str}
**Source:** L7S Workflow Capture — Education Analysis Pipeline
**Author:** Layer 7 Systems — Automated Report

---"""


def _volume_summary(df: pd.DataFrame) -> str:
    total_videos = len(df)
    unique_users = df["username"].nunique() if "username" in df.columns else 0

    if "duration_sec" in df.columns:
        valid_durations = df["duration_sec"][df["duration_sec"] > 0]
        total_seconds = valid_durations.sum()
        total_hours = total_seconds / 3600
        avg_duration_min = valid_durations.mean() / 60 if len(valid_durations) > 0 else 0
    else:
        total_hours = 0
        avg_duration_min = 0

    # Skill level distribution
    skill_dist = ""
    if "skill_level" in df.columns:
        skill_counts = df["skill_level"].value_counts()
        skill_lines = "\n".join(
            f"| {level} | {count} | {count/total_videos*100:.0f}% |"
            for level, count in skill_counts.items()
        )
        skill_dist = f"""

### Skill Level Distribution

| Level | Users | % |
|-------|-------|---|
{skill_lines}"""

    # Time save distribution
    time_dist = ""
    if "time_save_opportunity" in df.columns:
        time_counts = df["time_save_opportunity"].value_counts()
        time_lines = "\n".join(
            f"| {level} | {count} | {count/total_videos*100:.0f}% |"
            for level, count in time_counts.items()
        )
        time_dist = f"""

### Time Savings Opportunity Distribution

| Opportunity | Videos | % |
|-------------|--------|---|
{time_lines}"""

    return f"""## 1. Volume Summary

| Metric | Value |
|--------|-------|
| Total videos analyzed | {total_videos} |
| Unique users | {unique_users} |
| Total recording time | {total_hours:.1f} hours |
| Average recording length | {avg_duration_min:.1f} minutes |
{skill_dist}{time_dist}"""


def _per_user_learning_profiles(df: pd.DataFrame) -> str:
    lines = ["## 2. Per-User Learning Profiles"]

    if "username" not in df.columns:
        lines.append("\n*No user data available.*")
        return "\n".join(lines)

    for user in sorted(df["username"].unique()):
        user_df = df[df["username"] == user]
        count = len(user_df)

        # Aggregate skill level (mode)
        skill_level = user_df["skill_level"].mode().iloc[0] if "skill_level" in user_df.columns and not user_df["skill_level"].dropna().empty else "unknown"

        # Common learning categories
        categories = ""
        if "learning_category" in user_df.columns:
            cat_counts = user_df["learning_category"].value_counts()
            categories = ", ".join(f"{cat} ({n})" for cat, n in cat_counts.head(3).items())

        # Aggregate time save opportunity (most common)
        time_save = user_df["time_save_opportunity"].mode().iloc[0] if "time_save_opportunity" in user_df.columns and not user_df["time_save_opportunity"].dropna().empty else "unknown"

        # Collect all recommended modules
        all_modules = []
        if "recommended_training_modules" in user_df.columns:
            for val in user_df["recommended_training_modules"].dropna():
                modules = _parse_json_field(val)
                all_modules.extend(modules)
        top_modules = Counter(all_modules).most_common(5)

        # Collect example prompts
        example_prompts = []
        if "example_ai_prompt" in user_df.columns:
            for val in user_df["example_ai_prompt"].dropna():
                prompt = str(val).strip()
                if prompt:
                    example_prompts.append(prompt)

        lines.append(f"\n### {user}")
        lines.append(f"\n| Attribute | Value |")
        lines.append(f"|-----------|-------|")
        lines.append(f"| Videos analyzed | {count} |")
        lines.append(f"| Skill level | {skill_level} |")
        lines.append(f"| Primary learning areas | {categories or 'N/A'} |")
        lines.append(f"| Time save opportunity | {time_save} |")

        if top_modules:
            lines.append(f"\n**Recommended Training Modules:**")
            for module, freq in top_modules:
                lines.append(f"- {module} (appears {freq}x)")

        if example_prompts:
            lines.append(f"\n**Example AI Prompts to Try:**")
            for prompt in example_prompts[:3]:
                lines.append(f"\n> {_truncate(prompt, 200)}")

    return "\n".join(lines)


def _skill_gap_heatmap(df: pd.DataFrame) -> str:
    lines = ["## 3. AI Skill Gap Heatmap"]

    if "username" not in df.columns or "learning_category" not in df.columns:
        lines.append("\n*Insufficient data for heatmap.*")
        return "\n".join(lines)

    lines.append("\nUser × Learning Category matrix showing time save opportunity:")
    lines.append("(minimal / moderate / significant / transformative)\n")

    # Build pivot data
    users = sorted(df["username"].unique())
    categories = sorted(df["learning_category"].unique())

    # Header row
    header = "| User |"
    sep = "|------|"
    for cat in categories:
        short_cat = cat.replace("_", " ").title()[:20]
        header += f" {short_cat} |"
        sep += "------|"
    lines.append(header)
    lines.append(sep)

    for user in users:
        user_df = df[df["username"] == user]
        row_str = f"| {user} |"
        for cat in categories:
            cat_df = user_df[user_df["learning_category"] == cat]
            if cat_df.empty:
                row_str += " — |"
            else:
                # Show the most common time save opportunity for this user+category
                time_save = cat_df["time_save_opportunity"].mode().iloc[0] if not cat_df["time_save_opportunity"].dropna().empty else "—"
                row_str += f" {time_save} |"
        lines.append(row_str)

    return "\n".join(lines)


def _common_ai_assistable_moments(df: pd.DataFrame) -> str:
    lines = ["## 4. Most Common AI-Assistable Moments"]

    if "ai_assistable_moments" not in df.columns:
        lines.append("\n*No AI-assistable moments data available.*")
        return "\n".join(lines)

    all_moments = []
    for _, row in df.iterrows():
        moments = _parse_json_field(row.get("ai_assistable_moments", "[]"))
        for moment in moments:
            if isinstance(moment, dict):
                all_moments.append({
                    "moment": moment.get("moment", str(moment)),
                    "ai_tool": moment.get("ai_tool", ""),
                    "example_prompt": moment.get("example_prompt", ""),
                    "username": row.get("username", ""),
                })
            elif isinstance(moment, str):
                all_moments.append({
                    "moment": moment,
                    "ai_tool": "",
                    "example_prompt": "",
                    "username": row.get("username", ""),
                })

    if not all_moments:
        lines.append("\n*No AI-assistable moments extracted.*")
        return "\n".join(lines)

    lines.append(f"\n**{len(all_moments)}** AI-assistable moments identified across all videos.\n")

    # Group by AI tool
    tool_counts = Counter(m["ai_tool"] for m in all_moments if m["ai_tool"])
    if tool_counts:
        lines.append("### By AI Tool\n")
        lines.append("| AI Tool | Occurrences |")
        lines.append("|---------|-------------|")
        for tool, count in tool_counts.most_common(10):
            lines.append(f"| {tool} | {count} |")

    # Show top moments
    lines.append("\n### Top Moments (sample)\n")
    lines.append("| User | Moment | Suggested Tool |")
    lines.append("|------|--------|----------------|")
    for m in all_moments[:20]:
        lines.append(
            f"| {m['username']} "
            f"| {_truncate(m['moment'], 60)} "
            f"| {m['ai_tool']} |"
        )

    return "\n".join(lines)


def _missed_tool_features_inventory(df: pd.DataFrame) -> str:
    lines = ["## 5. Missed Tool Features Inventory"]

    if "missed_tool_features" not in df.columns:
        lines.append("\n*No missed tool features data available.*")
        return "\n".join(lines)

    all_features = []
    for _, row in df.iterrows():
        features = _parse_json_field(row.get("missed_tool_features", "[]"))
        for feat in features:
            if isinstance(feat, dict):
                all_features.append({
                    "app": feat.get("app", ""),
                    "feature": feat.get("feature", str(feat)),
                    "manual_approach": feat.get("manual_approach", ""),
                    "difficulty": feat.get("difficulty", ""),
                    "username": row.get("username", ""),
                })
            elif isinstance(feat, str):
                all_features.append({
                    "app": "",
                    "feature": feat,
                    "manual_approach": "",
                    "difficulty": "",
                    "username": row.get("username", ""),
                })

    if not all_features:
        lines.append("\n*No missed features extracted.*")
        return "\n".join(lines)

    lines.append(f"\n**{len(all_features)}** missed tool features identified.\n")

    # Group by app
    app_features = defaultdict(list)
    for feat in all_features:
        app_name = feat["app"] or "Unknown App"
        app_features[app_name].append(feat)

    for app, features in sorted(app_features.items(), key=lambda x: -len(x[1])):
        lines.append(f"\n### {app} ({len(features)} missed features)\n")
        lines.append("| Feature | What User Did Instead | Difficulty | Users |")
        lines.append("|---------|----------------------|------------|-------|")

        # Deduplicate by feature name
        feature_groups = defaultdict(list)
        for f in features:
            feature_groups[f["feature"]].append(f)

        for feature_name, group in sorted(feature_groups.items(), key=lambda x: -len(x[1])):
            manual = group[0]["manual_approach"]
            difficulty = group[0]["difficulty"]
            users = ", ".join(sorted(set(g["username"] for g in group)))
            lines.append(
                f"| {_truncate(feature_name, 40)} "
                f"| {_truncate(manual, 40)} "
                f"| {difficulty} "
                f"| {users} |"
            )

    return "\n".join(lines)


def _recommended_curriculum(df: pd.DataFrame) -> str:
    lines = ["## 6. Recommended Training Curriculum"]

    if "recommended_training_modules" not in df.columns:
        lines.append("\n*No training module data available.*")
        return "\n".join(lines)

    all_modules = []
    module_users = defaultdict(set)

    for _, row in df.iterrows():
        modules = _parse_json_field(row.get("recommended_training_modules", "[]"))
        username = row.get("username", "")
        for mod in modules:
            mod_str = str(mod).strip()
            if mod_str:
                all_modules.append(mod_str)
                module_users[mod_str].add(username)

    if not all_modules:
        lines.append("\n*No training modules recommended.*")
        return "\n".join(lines)

    module_counts = Counter(all_modules)

    lines.append(f"\n**{len(module_counts)}** unique training modules recommended across all analyses.\n")
    lines.append("### Priority Training Modules (ranked by frequency)\n")
    lines.append("| # | Training Module | Appearances | Users Who Need It |")
    lines.append("|---|----------------|-------------|-------------------|")

    for rank, (module, count) in enumerate(module_counts.most_common(20), 1):
        users = ", ".join(sorted(module_users[module]))
        lines.append(f"| {rank} | {_truncate(module, 50)} | {count} | {users} |")

    # Group by learning category
    if "learning_category" in df.columns:
        lines.append("\n### Modules by Learning Category\n")
        for cat in sorted(df["learning_category"].unique()):
            cat_df = df[df["learning_category"] == cat]
            cat_modules = []
            for val in cat_df["recommended_training_modules"].dropna():
                cat_modules.extend(_parse_json_field(val))

            if cat_modules:
                cat_module_counts = Counter(cat_modules)
                cat_display = cat.replace("_", " ").title()
                lines.append(f"\n**{cat_display}:**")
                for mod, count in cat_module_counts.most_common(5):
                    lines.append(f"- {mod} ({count}x)")

    return "\n".join(lines)


def _per_video_details(df: pd.DataFrame) -> str:
    lines = ["## 7. Per-Video Education Details"]

    if "education_md_path" not in df.columns:
        lines.append("\n*No per-video education files available.*")
        return "\n".join(lines)

    analyses = df[df["education_md_path"].notna() & (df["education_md_path"] != "")]

    if analyses.empty:
        lines.append("\n*No per-video education files found.*")
        return "\n".join(lines)

    lines.append(f"\n**{len(analyses)}** videos have education analyses.\n")
    lines.append("| User | Task | Skill Level | Category | Time Save | File |")
    lines.append("|------|------|-------------|----------|-----------|------|")

    for _, row in analyses.iterrows():
        user = row.get("username", "")
        task = _truncate(row.get("task_description", ""), 30)
        skill = row.get("skill_level", "")
        category = str(row.get("learning_category", "")).replace("_", " ")
        time_save = row.get("time_save_opportunity", "")
        md_path = row.get("education_md_path", "")
        filename = os.path.basename(md_path) if md_path else ""
        lines.append(f"| {user} | {task} | {skill} | {category} | {time_save} | {filename} |")

    return "\n".join(lines)


def _footer() -> str:
    return f"""---

*Report generated by L7S Education Analysis Pipeline on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*
*Data source: Gemini education-focused analysis of screen recordings collected via L7S Workflow Capture*
*Layer 7 Systems — ML Engineering*"""


# =============================================================================
# Helpers
# =============================================================================


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

    csv_file = sys.argv[1] if len(sys.argv) > 1 else EDUCATION_CSV
    print(f"Generating education report from: {csv_file}")
    path = generate_education_report(csv_path=csv_file)
    if path:
        print(f"\nReport saved to: {path}")
