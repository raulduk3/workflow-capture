# L7S Workflow Capture - Deployment Scripts

PowerShell scripts for deploying and managing L7S Workflow Capture via Ninja RMM.

## Scripts Overview

| Script | Purpose | Runs As |
|--------|---------|---------|
| `Install-WorkflowCapture.ps1` | Silent installation on client machines | Administrator |
| `Uninstall-WorkflowCapture.ps1` | Silent removal from client machines | Administrator |
| `Extract-WorkflowCaptures.ps1` | Collect recordings from all users | Administrator |
| `Deploy-WorkflowConfig.ps1` | Deploy/update configuration remotely | Administrator |
| `Run-WorkflowPipeline.ps1` | Full analysis pipeline (convert + Gemini) | Administrator |
| `Schedule-WorkflowPipeline.ps1` | Register daily Task Scheduler job | Administrator |

---

## Schedule-WorkflowPipeline.ps1

**Registers a Windows Scheduled Task that runs the full analysis pipeline daily on the utility server.**

The pipeline converts `.webm` recordings from the network share to `.mp4`, then runs Gemini Vision analysis to produce structured workflow insights.

### How It Works

```
  Ninja RMM (daily)                Utility Server (daily, 2 AM)
  ┌──────────────┐                 ┌──────────────────────────────────┐
  │ Client PCs   │    .webm        │ Schedule-WorkflowPipeline.ps1    │
  │ Extract      │──────────►      │  └─► Run-WorkflowPipeline.ps1   │
  │ .webm to     │  Network/Local │       ├─ Stage 1: webm → mp4    │
  │ network share│  \workflow\     │       └─ Stage 2: Gemini → CSV  │
  └──────────────┘                 └──────────────────────────────────┘
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Time` | String | `"02:00"` | Daily trigger time (24h format) |
| `-RunAs` | String | Current user | Service account (prompted for password) |
| `-GenerateReport` | Switch | `$false` | Include insights report generation |
| `-Force` | Switch | `$false` | Overwrite existing scheduled task |
| `-Uninstall` | Switch | `$false` | Remove the scheduled task |
| `-RunNow` | Switch | `$false` | Trigger the task immediately |

### Features

- **Lock file** prevents overlapping runs
- **Stale lock auto-clear** after 6 hours (handles crashed runs)
- **Transcript logging** — full audit trail in `C:\temp\WorkflowProcessing\logs\`
- **Health marker** — `last_run.json` for monitoring tools
- **Retry on failure** — 3 retries with 30-minute intervals
- **4-hour execution time limit**
- **Log rotation** — old logs auto-cleaned after 14 days

### Examples

```powershell
# Register daily task at 2 AM (default)
.\Schedule-WorkflowPipeline.ps1

# Register at 4 AM with report generation
.\Schedule-WorkflowPipeline.ps1 -Time "04:00" -GenerateReport

# Run as a service account (password prompted)
.\Schedule-WorkflowPipeline.ps1 -RunAs "DOMAIN\svc-workflow"

# Update schedule to 3 AM
.\Schedule-WorkflowPipeline.ps1 -Force -Time "03:00"

# Trigger immediately (for testing)
.\Schedule-WorkflowPipeline.ps1 -RunNow

# Remove the scheduled task
.\Schedule-WorkflowPipeline.ps1 -Uninstall
```

### Monitoring

```powershell
# Check last run status
Get-Content C:\temp\WorkflowProcessing\logs\last_run.json

# View today's log
Get-Content C:\temp\WorkflowProcessing\logs\pipeline_$(Get-Date -Format 'yyyy-MM-dd').log

# List recent scheduled logs
Get-ChildItem C:\temp\WorkflowProcessing\logs\scheduled_*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 5

# Check task status in Task Scheduler
Get-ScheduledTask -TaskName "L7S-WorkflowAnalysisPipeline" -TaskPath "\L7S\" | Get-ScheduledTaskInfo
```

### Setup on Utility Server

1. Clone the repo (or copy `scripts/` and `pipeline/` folders)
2. Install prerequisites:
   ```powershell
   choco install ffmpeg
   pip install -r pipeline/requirements.txt
   ```
3. Configure Gemini API key in `pipeline/.env`:
   ```
   GEMINI_API_KEY=your-key-here
   ```
4. Register the scheduled task:
   ```powershell
   .\Schedule-WorkflowPipeline.ps1 -Time "02:00" -GenerateReport
   ```
5. Verify with a manual run:
   ```powershell
   .\Schedule-WorkflowPipeline.ps1 -RunNow
   ```

---

## Deploy-WorkflowConfig.ps1

**Deploy or update recording settings across all clients without reinstalling the app.**

The app reads its configuration from `C:\temp\L7SWorkflowCapture\config.json` at startup. This script creates or updates that config file, allowing you to change settings like max recording duration across your entire fleet.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-MaxRecordingMinutes` | Int | `5` | Maximum recording duration (1-60 minutes) |
| `-VideoBitrateMbps` | Int | `5` | Video quality bitrate (1-50 Mbps) |
| `-RestartApp` | Switch | `$false` | Restart the app to apply changes immediately |

### Config File Format

```json
{
  "maxRecordingMinutes": 10,
  "videoBitrateMbps": 5
}
```

### Examples

```powershell
# Set max recording to 10 minutes
.\Deploy-WorkflowConfig.ps1 -MaxRecordingMinutes 10

# Set max recording to 15 minutes with higher quality
.\Deploy-WorkflowConfig.ps1 -MaxRecordingMinutes 15 -VideoBitrateMbps 8

# Update config and restart the app immediately
.\Deploy-WorkflowConfig.ps1 -MaxRecordingMinutes 10 -RestartApp

# Set to 30 minutes for longer workflows
.\Deploy-WorkflowConfig.ps1 -MaxRecordingMinutes 30
```

### Ninja RMM Configuration

1. Create a new Script in Ninja RMM
2. Set **Script Type**: PowerShell
3. Set **Run As**: System (or Administrator)
4. Create Script Variables for parameters:
   - `MaxRecordingMinutes` (Number, default: 5)
   - `VideoBitrateMbps` (Number, default: 5)
   - `RestartApp` (Checkbox, default: unchecked)
5. Schedule to run once or on-demand when you need to update settings

### When Changes Take Effect

- **Without `-RestartApp`**: Changes apply next time the app starts
- **With `-RestartApp`**: Changes apply immediately (app is restarted)

### Workflow for Changing Settings Fleet-Wide

1. Test the new setting on a single machine first
2. Deploy via Ninja RMM to all machines
3. Either wait for users to restart the app, or use `-RestartApp`

---

## Install-WorkflowCapture.ps1

Silently installs the Workflow Capture application on Windows 10/11 machines.

**By default, downloads the latest version from GitHub automatically.**

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-InstallerSource` | String | `""` | Network/local path containing installer (overrides GitHub) |
| `-InstallerUrl` | String | `""` | Direct URL to download installer (overrides GitHub) |
| `-InstallerFileName` | String | `L7S-Workflow-Capture-*-x64.exe` | Installer filename pattern (for Source mode) |
| `-AutoStart` | Switch | `$false` | Add to user startup |
| `-ForceReinstall` | Switch | `$false` | Reinstall even if already installed |
| `-AllUsers` | Switch | `$false` | Install for all users (per-machine) |
| `-SkipGitHub` | Switch | `$false` | Disable automatic GitHub download |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Installer not found |
| 3 | Installation failed |
| 4 | Unsupported OS |

### Examples

```powershell
# Install latest version from GitHub (default)
.\Install-WorkflowCapture.ps1

# Install with auto-start enabled
.\Install-WorkflowCapture.ps1 -AutoStart

# Install from network share (overrides GitHub)
.\Install-WorkflowCapture.ps1 -InstallerSource "\\fileserver\software\L7S"

# Install from direct URL
.\Install-WorkflowCapture.ps1 -InstallerUrl "https://example.com/installer.exe"

# Force reinstall/update to latest GitHub version
.\Install-WorkflowCapture.ps1 -ForceReinstall
```

### Installer Source Priority

1. **`-InstallerUrl`**: Explicit URL (highest priority)
2. **`-InstallerSource`**: Network/local path
3. **GitHub**: Latest release (default if nothing specified)

### How GitHub Download Works

- Queries: `https://api.github.com/repos/raulduk3/workflow-capture/releases/latest`
- Automatically finds and downloads the Windows x64 installer
- No authentication required (public repository)
- Always gets the latest released version

### Ninja RMM Configuration

1. Create a new Script in Ninja RMM
2. Set **Script Type**: PowerShell
3. Set **Run As**: System (or Administrator)
4. Paste script content
5. Configure parameters as Script Variables

---

## Uninstall-WorkflowCapture.ps1

Silently removes the application and optionally preserves/exports session data.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-KeepData` | Switch | `$false` | Preserve session recordings |
| `-ExportDataFirst` | Switch | `$false` | Export data before uninstall |
| `-ExportPath` | String | `""` | Network path for data export |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (or not installed) |
| 1 | General error |
| 3 | Uninstallation failed |

### Examples

```powershell
# Simple uninstall (removes all data)
.\Uninstall-WorkflowCapture.ps1

# Keep user recordings
.\Uninstall-WorkflowCapture.ps1 -KeepData

# Export recordings before uninstall
.\Uninstall-WorkflowCapture.ps1 -ExportDataFirst -ExportPath "\\server\backups"
```

---

## Extract-WorkflowCaptures.ps1

Collects all workflow capture sessions from a machine and uploads to a central location.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DestinationPath` | String | `\\server\share\WorkflowCaptures` | Upload destination |
| `-ClientName` | String | `$env:COMPUTERNAME` | Identifier for this machine |
| `-DeleteAfterUpload` | Switch | `$false` | Remove local copies after upload |
| `-Verbose` | Switch | `$false` | Enable verbose logging |

### Data Structure

The script handles both legacy and date-organized session structures:

```
C:\temp\L7SWorkflowCapture\Sessions\
├── 2026-01-29\                    # Date-organized (new)
│   └── {session-uuid}\
│       ├── session.json
│       └── recording_*.webm
└── {session-uuid}\                # Legacy structure
    ├── session.json
    └── recording_*.webm
```

### Output Structure

```
\\server\share\WorkflowCaptures\
└── COMPUTERNAME\
    └── COMPUTERNAME_username_20260129-143022.zip
```

### Examples

```powershell
# Extract to network share
.\Extract-WorkflowCaptures.ps1 -DestinationPath "\\nas\captures"

# Extract and clean up local copies
.\Extract-WorkflowCaptures.ps1 -DestinationPath "\\nas\captures" -DeleteAfterUpload

# Custom client identifier
.\Extract-WorkflowCaptures.ps1 -ClientName "NYC-WORKSTATION-01"
```

---

## Deployment Workflow

### Initial Rollout

1. **Simple Deployment (Recommended)**
   - Script automatically downloads latest from GitHub
   - No staging required
   - Run: `.\Install-WorkflowCapture.ps1 -AutoStart`

2. **Deploy via Ninja RMM**
   - Create scheduled task or run immediately
   - Target: Windows 10/11 Pro devices
   - Script: `Install-WorkflowCapture.ps1`
   - No parameters needed (uses GitHub by default)

3. **Verify Installation**
   - Check exit codes in Ninja RMM
   - Review installation logs at `%TEMP%\L7S-WorkflowCapture-Install.log`

### Alternative: Network Share Deployment

If you prefer to control the installer version:

1. **Stage Installer**
   - Download from: https://github.com/raulduk3/workflow-capture/releases
   - Copy to network share: `\\server\software\L7S\`

2. **Deploy with Source Override**
   ```powershell
   .\Install-WorkflowCapture.ps1 -InstallerSource "\\server\software\L7S" -AutoStart
   ```

### Regular Data Collection

1. **Schedule Extraction** (Client Machines)
   - Run daily via Ninja RMM
   - Script: `Extract-WorkflowCaptures.ps1`
   - Uploads `.webm` to configured destination (network share or local path)

2. **Schedule Analysis Pipeline** (Utility Server)
   - Run once on the utility server to register the task:
     ```powershell
     .\Schedule-WorkflowPipeline.ps1 -Time "02:00" -GenerateReport
     ```
   - Converts `.webm` → `.mp4`, runs Gemini analysis, outputs CSV
   - Runs daily after extraction completes (set time accordingly)
   - Monitor via `last_run.json` or Task Scheduler

3. **Monitor Results**
   - Check returned objects for session counts
   - Alert on failures via `last_run.json` health marker

### Application Updates

```powershell
# Update to latest GitHub version (simplest)
.\Install-WorkflowCapture.ps1 -ForceReinstall

# Update from specific source
.\Install-WorkflowCapture.ps1 -InstallerSource "\\server\v2" -ForceReinstall
```

### Complete Removal

```powershell
# Export data, then uninstall
.\Extract-WorkflowCaptures.ps1 -DestinationPath "\\server\final-export"
.\Uninstall-WorkflowCapture.ps1
```

---

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| "Failed to download from GitHub" | Check internet connectivity and GitHub availability |
| "Installer not found" | Verify network path accessibility and filename pattern |
| "Unsupported OS" | Requires Windows 10 or 11 |
| "Installation failed" | Check `%TEMP%\L7S-WorkflowCapture-Install.log` |
| "Access denied" | Ensure script runs as Administrator/System |
| GitHub API rate limit | Use `-InstallerSource` to bypass GitHub |

### Log Locations

| Log | Path |
|-----|------|
| Install | `%TEMP%\L7S-WorkflowCapture-Install.log` |
| Uninstall | `%TEMP%\L7S-WorkflowCapture-Uninstall.log` |
| Application | `C:\temp\L7SWorkflowCapture\logs\` |

### Testing Locally

```powershell
# Test installation script
.\Install-WorkflowCapture.ps1 -InstallerSource "C:\Temp" -Verbose

# Test extraction script  
.\Extract-WorkflowCaptures.ps1 -DestinationPath "C:\Temp\TestExport" -Verbose
```
