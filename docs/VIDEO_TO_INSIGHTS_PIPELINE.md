# Workflow Video Analysis Pipeline
## From Raw .webm Recordings to Actionable Business Insights

**Version:** 2.0  
**Date:** February 6, 2026  
**Status:** 🟢 
**Author:** Richard Alvarez - Layer 7 Systems

## Executive Summary

### The Problem
We have users recording their daily workflows. The videos are piling up on a network share. We need to turn this raw footage into actionable intelligence: Where are people struggling? What can we automate? Where can AI (Gemini) make their lives easier?

### The Solution
A 7-day sprint to build a lightweight analysis pipeline that watches videos, extracts insights, and produces a running dataset we can query for patterns.

### The End Result
1. A CSV that grows daily with structured data about every workflow recording
2. Automatic flagging of high-friction workflows and automation candidates
3. Weekly insights reports identifying where to deploy AI tools
4. Evidence-based recommendations for Gemini integrations

## 1. Current State: What We Have Now

### 1.1 Live Systems
| System | Status | What It Does |
|--------|--------|--------------|
| **L7S Workflow Capture** | ✅ Running | Desktop app records user screen when they start a task |
| **Ninja RMM Extraction** | ✅ Running | Copies recordings to network share twice daily |
| **Source Directory** | ✅ Receiving | Configured source share stores all videos (network share or local path) |
| **ActivTrak** | ✅ Active | Tracks productivity metrics, app usage, idle time |

### 1.2 What the Data Looks Like

**Video files arrive with metadata baked into the filename:**
```
2026-02-06_143022_DESKTOP-FIN01_quarterly_sales_report.webm
    │         │        │              │
    │         │        │              └── Task description (user typed this)
    │         │        └── Machine name (ties to ActivTrak)
    │         └── Time started (14:30:22)
    └── Date
```

**Organized by user on the network share:**
```
\\bulley-fs1\workflow\
├── jsmith\
│   ├── 2026-02-06_091522_DESKTOP-FIN01_invoice_processing.webm
│   ├── 2026-02-06_143022_DESKTOP-FIN01_quarterly_sales_report.webm
│   └── ...
├── mjones\
│   └── ...
└── klee\
    └── ...
```

### 1.3 Data Flow Today vs. End of Week
```
TODAY (Data Collecting):
┌──────────────┐         ┌───────────────────┐
│ User records │  ──────►│ Network share     │  ◄── Videos piling up here
│ workflow     │  2x/day │ {user}\*.webm     │
└──────────────┘         └───────────────────┘

END OF WEEK (Pipeline Running):
┌──────────────┐         ┌───────────────────┐         ┌─────────────────┐
│ User records │  ──────►│ Network share     │  ──────►│ Analysis CSV    │
│ workflow     │  2x/day │ {user}\*.webm     │  auto   │ + Pattern flags │
└──────────────┘         └───────────────────┘         │ + Weekly report │
                                                        └─────────────────┘
```

## 2. The Pipeline: How It Works

### 2.1 Overview

Every video goes through four stages:

| Stage | Input | Process | Output |
|-------|-------|---------|--------|
| **1. Ingest** | .webm file path | Parse filename, get file metadata | Structured metadata (user, time, task, duration) |
| **2. Sample** | Video file | Extract 35 evenly-spaced screenshot frames | 35 JPG images |
| **3. Analyze** | 20 frames + metadata | Send to Gemini Vision API with analysis prompt | JSON with apps, actions, friction events |
| **4. Store** | All extracted data | Append row to CSV, log as processed | Growing analysis dataset |

### 2.2 Why This Approach?

| Design Choice | Why |
|---------------|-----|
| **35 frames, not every frame** | 5-minute video = 9,000 frames. 35 frames = 1 every ~8.5 seconds. Catches app transitions and brief errors while keeping costs low. |
| **CSV, not a database** | Zero setup. Easy to open in Excel. Easy to query with pandas. Can migrate later if needed. |
| **Gemini Flash, not Pro** | Cheaper, faster. We're doing classification, not complex reasoning. |
| **Process on network share** | Videos are huge. Don't copy them. Read directly from source. |
| **Append-only log** | Never reprocess the same video. Track what we've done. |

### 2.3 What Gemini Sees and Returns

**We send Gemini:**
- 35 screenshot frames from the video
- The task description from the filename
- A structured prompt asking for specific analysis

**Gemini returns:**
- Primary application being used
- Sequence of applications (workflow map)
- Actions detected (data entry, copy-paste, navigation, etc.)
- Friction events (errors, repeated actions, app-switching loops)
- Automation opportunity score (0.0 to 1.0)
- Workflow category

## 3. What We Extract: The Data Model

### 3.1 From Filename (Free, Immediate)

| Field | Source | Why It Matters |
|-------|--------|----------------|
| `username` | Parent folder name | Who did this? |
| `timestamp` | Filename | When exactly? |
| `machine_id` | Filename | Which workstation? (Joins to ActivTrak) |
| `task_description` | Filename | **What they intended to do** - this is gold |
| `day_of_week` | Derived from timestamp | Monday workflows differ from Friday |
| `hour_of_day` | Derived from timestamp | Morning vs afternoon patterns |

### 3.2 From Video File (Cheap, Day 1)

| Field | Source | Why It Matters |
|-------|--------|----------------|
| `duration_seconds` | ffprobe video metadata | How long did this take? |
| `file_size_mb` | Filesystem | Larger files = more activity |

### 3.3 From Gemini Vision (Core Value, Day 3-4)

| Field | What Gemini Identifies | Business Value |
|-------|------------------------|----------------|
| `primary_app` | Application with most screen time | What tools dominate their work? |
| `app_sequence` | Order of applications used | Map the actual workflow |
| `detected_actions` | What they're doing (data entry, copy-paste, etc.) | Categorize work types |
| `friction_events` | Errors, repeated undos, app-switch loops, long pauses | **WHERE THEY STRUGGLE** |
| `friction_count` | Number of friction events | Quick severity filter |
| `automation_score` | 0.0-1.0 based on repetition and manual work | **WHAT TO AUTOMATE** |
| `workflow_category` | Classification (reporting, data entry, communication, etc.) | Group similar workflows |

### 3.4 From ActivTrak (Enrichment, Day 6)

| Field | Source | Correlation Value |
|-------|--------|-------------------|
| `productive_time_ratio` | ActivTrak API | Is recorded time productive or struggling? |
| `activtrak_top_apps` | ActivTrak API | Cross-validate with video observation |
| `idle_time` | ActivTrak API | Long pauses = waiting on something? |

## 4. The Output: Running Analysis CSV

### 4.1 Location
```
Configured output directory\\workflow_analysis.csv
```

### 4.2 One Row Per Video

Each processed video becomes one row with all extracted fields. Example:

| video_id | timestamp | username | task_description | duration_sec | primary_app | friction_count | automation_score |
|----------|-----------|----------|------------------|--------------|-------------|----------------|------------------|
| a1b2c3 | 2026-02-06T14:30:22 | jsmith | quarterly sales report | 287 | Excel | 1 | 0.72 |

### 4.3 What This Enables

With this CSV, we can immediately answer:

| Business Question | How to Find the Answer |
|-------------------|------------------------|
| "What tasks take the longest?" | Group by task description, average duration |
| "Which apps cause the most friction?" | Filter high friction, group by primary app |
| "Who needs the most help?" | Group by username, sum friction count |
| "What should we automate first?" | Filter automation score > 0.7, sort descending |
| "When do problems happen?" | Filter high friction, group by hour of day |
| "What are common workflow patterns?" | Group by app sequence |

## 5. Pattern Detection: Automatic Flags

### 5.1 Rule-Based Patterns (Day 5)

The pipeline automatically flags videos matching these patterns:

| Pattern | Trigger | What It Means | Recommended Action |
|---------|---------|---------------|-------------------|
| 🔄 **Copy-Paste Heavy** | 3+ copy-paste actions detected | Manual data transfer between systems | Integration or automation between apps |
| 🔀 **App Switch Loop** | 6+ apps in sequence | Fragmented workflow, context switching | Unified dashboard or consolidated tool |
| ⚠️ **High Friction** | 3+ friction events | User is struggling with this task | Priority investigation, possible training |
| 🤖 **Automation Ready** | Score ≥ 0.75 | Highly repetitive, predictable workflow | Strong candidate for RPA or Gemini |

### 5.2 Why Rule-Based First?

We don't have labeled training data yet. Rule-based patterns give us:
- Immediate value on Day 5
- A way to validate our assumptions
- Labels for future ML models (if we scale)

Once we have 500+ processed videos with these flags, we can train classifiers to do this cheaper/faster.

## 6. ActivTrak Correlation: Adding Context

### 6.1 Why Correlate?

Video shows **what they're doing**. ActivTrak shows **productivity context**.

| ActivTrak Says | Video Shows | Combined Insight |
|----------------|-------------|------------------|
| Low productivity score | High friction count | User is **struggling**, not slacking |
| High idle time | Long pauses visible | Waiting on **system or approvals** |
| Top app is Outlook | Video shows Excel | **Multitasking** or unreported work |
| Productive time ratio high | Low friction count | This workflow is **working well** |

### 6.2 Join Strategy

Match records by username and date, with a ±1 hour tolerance window around the recording timestamp.

## 7. The 7-Day Sprint

### Day 1 (Thu Feb 6): Foundation
| Task | Outcome |
|------|---------|
| Set up `_outputs/` directory on network share | Place to store results |
| Build filename parser | Extract metadata from any video filename |
| Define CSV schema | Structure for all extracted data |
| Test ffmpeg frame extraction | Confirm we can pull screenshots |

### Day 2 (Fri Feb 7): Frame Extraction
| Task | Outcome |
|------|---------|
| Build batch extraction script | Process any video → 20 frames |
| Run on all existing videos | Frames ready for analysis |
| Validate output quality | Frames are readable, useful |

### Day 3-4 (Sat-Sun Feb 8-9): Gemini Integration
| Task | Outcome |
|------|---------|
| Set up Gemini API credentials | Connection working |
| Build analysis prompt | Structured output we can parse |
| Process first 50 videos end-to-end | Validate full pipeline |
| Iterate on prompt quality | Gemini returns useful data |

### Day 5 (Mon Feb 10): Pipeline + Patterns
| Task | Outcome |
|------|---------|
| Wire up full pipeline | Video → Frames → Gemini → CSV (automated) |
| Add pattern detection rules | Automatic flagging |
| Schedule pipeline to run after extractions | Continuous processing |

### Day 6 (Tue Feb 11): ActivTrak + Analysis
| Task | Outcome |
|------|---------|
| Pull ActivTrak data export | Productivity metrics for correlation |
| Join with video analysis | Enriched dataset |
| Run first aggregate queries | Initial insights |

### Day 7 (Wed Feb 12): Delivery
| Task | Outcome |
|------|---------|
| Generate insights report | Findings document |
| Identify top automation opportunities | Prioritized list with evidence |
| Document Gemini integration recommendations | Specific use cases |
| Demo to stakeholders | Alignment on next steps |

## 8. Day 7 Deliverable: Insights Report

### 8.1 Report Structure

**Section 1: Volume Summary**
- Total videos analyzed
- Users covered
- Total recording hours
- Date range

**Section 2: Top Friction Points (Priority)**
- Ranked list of most common friction patterns
- Which users experience them
- Recommended actions for each

**Section 3: Automation Opportunities**
- Workflows with highest automation scores
- Frequency (how often this workflow happens)
- Estimated time savings if automated
- Whether Gemini could help

**Section 4: Application Insights**
- Most-used applications
- Applications causing most friction
- Applications frequently used together (integration candidates)

**Section 5: User-Specific Findings**
- Users with highest friction (may need training)
- Users with smoothest workflows (possible best practices)

**Section 6: Gemini Integration Recommendations**
- Specific opportunities with evidence from the data
- Estimated impact
- Implementation complexity

### 8.2 Success Criteria

By end of Day 7, we will have:

| Deliverable | How We Know It's Done |
|-------------|----------------------|
| Pipeline running | Automatically processes new videos after each extraction |
| CSV growing | New rows added with each batch |
| Insights report | Document delivered to stakeholders |
| Automation opportunities | Top 3+ identified with supporting evidence |
| Gemini recommendations | Specific use cases documented with rationale |

## 9. Cost Estimate

### 9.1 Gemini API Costs

| Volume | Frames/Video | Daily Cost | Monthly Cost |
|--------|--------------|------------|--------------|
| 50 videos/day | 35 | ~$1.75 | ~$52 |
| 100 videos/day | 35 | ~$3.50 | ~$105 |
| 200 videos/day | 35 | ~$7.00 | ~$210 |

**Budget recommendation:** $200/month covers approximately 100 videos/day with buffer for retries.

### 9.2 Storage Costs

Frames are temporary (deleted after Gemini processes them). The CSV grows by approximately 1KB per video. Storage cost is negligible.

## 10. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Gemini rate limits | Processing slows down | Batch with delays, exponential backoff |
| Network share inaccessible | Pipeline can't run | Run from machine with reliable mount |
| Poor video quality | Unusable frame extraction | Filter by file size (skip tiny files) |
| Gemini returns malformed data | Row not written to CSV | Retry with different settings, log errors for review |
| Costs exceed budget | Overspend | Sample videos randomly, reduce frame count |
| Privacy concerns | Legal/compliance exposure | Process on-premises only, avoid sending PII |

## 11. Key Decisions

| Decision | Rationale |
|----------|-----------|
| 35 frames per video | 1 frame every ~8.5 seconds captures app transitions and brief errors while keeping costs manageable |
| CSV over database | Zero setup time, can open in Excel, easy to migrate later if needed |
| Gemini 1.5 Flash over Pro | Lower cost, sufficient accuracy for classification tasks |
| Process directly on network share | Avoid copying gigabytes of video data |
| Rule-based patterns before ML | No training data yet, provides immediate value |
| ActivTrak correlation on Day 6 | Adds productivity context, not blocking for core pipeline |
