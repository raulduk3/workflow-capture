# Manual Pipeline Operations Guide

**Last Updated:** February 13, 2026  
**For:** Richard Alvarez / L7S Admins

---

## How the Data Flows

```
Workstations              Network Share              Utility Server
┌──────────────┐     ┌─────────────────────┐     ┌──────────────────────────┐
│ L7S Capture  │────►│ \\bulley-fs1\       │────►│ 1. Convert .webm → .mp4  │
│ records .webm│ 2x/ │   workflow\{user}\  │     │ 2. Extract frames        │
│              │ day │                     │     │ 3. Gemini Vision analysis │
└──────────────┘     └─────────────────────┘     │ 4. CSV + patterns + report│
   (automatic)          (Ninja RMM)              └──────────────────────────┘
                                                    (YOU run this)
```

**Short version:** Videos land on the share automatically. You kick off the analysis whenever you want.

---

## Running the Pipeline Daily

Yes — you can run `Run-WorkflowPipeline.ps1` daily. It's designed for exactly that. The pipeline is **idempotent**: it tracks which videos have already been processed (`processed.log`) and skips them. Only new recordings get analyzed.

### Quick Start (Full Pipeline)

Open PowerShell on the utility server and run:

```powershell
cd C:\path\to\workflow-analyzer\scripts
.\Run-WorkflowPipeline.ps1
```

This runs both stages:
1. **Stage 1** — Converts new `.webm` files from the network share to `.mp4`
2. **Stage 2** — Extracts frames, sends to Gemini Vision, writes analysis to CSV

### With an Insights Report

```powershell
.\Run-WorkflowPipeline.ps1 -GenerateReport
```

This adds a markdown report (like `insights_2026-02-13.md`) after analysis completes.

---

## Common Manual Commands

| What You Want | Command |
|---|---|
| **Full pipeline** (convert + analyze) | `.\Run-WorkflowPipeline.ps1` |
| **Full pipeline + report** | `.\Run-WorkflowPipeline.ps1 -GenerateReport` |
| **Skip conversion** (MP4s already exist) | `.\Run-WorkflowPipeline.ps1 -SkipConversion` |
| **One user only** | `.\Run-WorkflowPipeline.ps1 -User "rcrane"` |
| **Limit batch size** | `.\Run-WorkflowPipeline.ps1 -Limit 10` |
| **Preview without doing anything** | `.\Run-WorkflowPipeline.ps1 -DryRun` |
| **Metadata only** (no Gemini API usage) | `.\Run-WorkflowPipeline.ps1 -MetadataOnly` |
| **Combine flags** | `.\Run-WorkflowPipeline.ps1 -User "cheras" -GenerateReport` |

---

## Running Each Stage Separately

### Stage 1 Only: Convert Videos

```powershell
cd C:\path\to\workflow-analyzer\scripts
.\Convert-WorkflowSessions.ps1
```

Options:
- `-SingleUser "rcrane"` — Convert only one user's videos
- `-DryRun` — Preview what would be converted
- `-CrfQuality 28` — Lower quality / smaller files (default: 23)

Output goes to `C:\temp\WorkflowProcessing\`:
- `.mp4` files (one per recording)
- `workflow_sessions.csv` (session metadata)

### Stage 2 Only: Analyze Videos

```powershell
cd C:\path\to\workflow-analyzer\pipeline
python run_pipeline.py
```

Options:
- `--user rcrane` — Single user
- `--limit 5` — Max videos to process
- `--dry-run` — Preview only
- `--metadata-only` — Skip Gemini, just extract file info
- `--report` — Generate insights report after processing

Output updates `C:\temp\WorkflowProcessing\workflow_analysis.csv`.

### Report Only (No New Analysis)

```powershell
cd C:\path\to\workflow-analyzer\pipeline
python -c "from report_generator import generate_report; generate_report()"
```

---

## Setting Up a Daily Schedule

If you want it fully automated instead of manual:

```powershell
cd C:\path\to\workflow-analyzer\scripts

# Schedule daily at 2:00 AM (default)
.\Schedule-WorkflowPipeline.ps1

# Schedule at a different time
.\Schedule-WorkflowPipeline.ps1 -Time "06:00"

# Run as a service account
.\Schedule-WorkflowPipeline.ps1 -RunAs "DOMAIN\svcaccount"

# Remove the schedule
.\Schedule-WorkflowPipeline.ps1 -Uninstall

# Trigger the scheduled task right now
.\Schedule-WorkflowPipeline.ps1 -RunNow
```

This creates a Windows Scheduled Task (`L7S-WorkflowAnalysisPipeline`) that retries up to 3 times on failure with 30-minute intervals.

---

## Where Things Live

| Item | Location |
|---|---|
| Raw recordings (.webm) | `\\bulley-fs1\workflow\{username}\` |
| Converted videos (.mp4) | `C:\temp\WorkflowProcessing\` |
| Session metadata CSV | `C:\temp\WorkflowProcessing\workflow_sessions.csv` |
| Analysis results CSV | `C:\temp\WorkflowProcessing\workflow_analysis.csv` |
| Processing dedup log | `C:\temp\WorkflowProcessing\processed.log` |
| Insights reports | `C:\temp\WorkflowProcessing\reports\` |
| Pipeline logs | `C:\temp\WorkflowProcessing\logs\` |
| Health check file | `C:\temp\WorkflowProcessing\logs\last_pipeline_run.json` |
| Gemini API key | `pipeline/.env` (GEMINI_API_KEY) |

---

## Checking Pipeline Health

After a run, check the health marker:

```powershell
Get-Content C:\temp\WorkflowProcessing\logs\last_pipeline_run.json
```

Check today's log:

```powershell
Get-Content C:\temp\WorkflowProcessing\logs\pipeline_$(Get-Date -Format 'yyyy-MM-dd').log
```

Logs auto-rotate after 14 days.

---

## Prerequisites Checklist

Before first run, confirm these on the utility server:

- [ ] `ffmpeg` installed (`choco install ffmpeg`)
- [ ] Python 3.10+ installed and on PATH
- [ ] Pipeline deps installed (`pip install -r pipeline/requirements.txt`)
- [ ] Gemini API key set in `pipeline/.env`
- [ ] Network share `\\bulley-fs1\workflow` is accessible
