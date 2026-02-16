# Workflow Video Analysis Pipeline

**Layer 7 Systems — February 2026**

---

**Abstract.**
We are collecting screen recordings of employee workflows via the L7S Workflow Capture application, extracted twice daily to a central network share. This document outlines a 7-day sprint to build a lightweight pipeline that converts raw .webm video files into structured, queryable data. The resulting dataset enables standard ML analysis (clustering, anomaly detection, classification) to identify friction points and automation opportunities across the organization.

**Problem.**
Workflow inefficiencies are invisible. Users struggle with repetitive tasks, fragmented tooling, and manual data transfer—but we have no systematic way to observe or quantify these patterns. ActivTrak provides productivity metrics but lacks workflow context. Video captures provide context but are unstructured and unscalable to review manually.

**Solution.**
A pipeline that processes each workflow recording into a single row of structured data:

- **Ingest**: Parse filename metadata (user, timestamp, machine, task description)
- **Sample**: Extract 35 evenly-spaced frames from each video (~1 frame per 8.5 seconds)
- **Analyze**: Send frames to Gemini Vision API with structured prompt
- **Store**: Append extracted features to a running CSV

The output is a growing dataset where each row represents one recorded workflow, with fields for applications used, actions detected, friction events observed, and an automation opportunity score.

**Data Sources.**
| Source | What It Provides |
|--------|------------------|
| Video filename | User, timestamp, machine ID, task description |
| Video frames (via Gemini) | Primary app, app sequence, detected actions, friction events, automation score |
| ActivTrak | Productivity ratio, idle time, app usage (joined by user + date) |

**What This Enables.**
The structured dataset supports standard ML workflows:

- **Clustering**: Group similar workflows to identify common patterns
- **Anomaly detection**: Flag outlier workflows with unusual friction or duration
- **Classification**: Categorize workflows by type, application, or department
- **Correlation analysis**: Link video observations to ActivTrak productivity metrics

All analysis uses existing ML tooling. No custom model training required.

**Non-Goals.**
This pipeline does not build custom models, automate any user workflows, make decisions on behalf of users, or require real-time processing. It produces data for human analysis.

**Output.**
A continuously growing CSV at the configured output directory with one row per processed video. Key fields: `username`, `timestamp`, `task_description`, `primary_app`, `app_sequence`, `friction_events`, `friction_count`, `automation_score`, `workflow_category`.

**Cost.**
Gemini API: ~$3.50/day at 100 videos (35 frames each). Monthly estimate: ~$105. Storage: negligible.

**Timeline.**
7 days from start to first insights report. Pipeline runs automatically after each extraction thereafter.

**Deliverable.**
By end of sprint: a running pipeline, a populated dataset, and an initial insights report identifying top friction points and automation candidates with supporting evidence.

---

*Prepared by Richard Alvarez — Layer 7 Systems ML Engineering*
