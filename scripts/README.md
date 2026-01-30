# L7S Workflow Capture - Ninja RMM Scripts

PowerShell scripts for deploying and managing L7S Workflow Capture via Ninja RMM.

## Scripts Overview

| Script | Purpose | Runs As |
|--------|---------|---------|
| `Install-WorkflowCapture.ps1` | Silent installation on client machines | Administrator |
| `Uninstall-WorkflowCapture.ps1` | Silent removal from client machines | Administrator |
| `Extract-WorkflowCaptures.ps1` | Collect recordings from all users | Administrator |

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
%LOCALAPPDATA%\L7SWorkflowCapture\Sessions\
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

1. **Schedule Extraction**
   - Run daily/weekly via Ninja RMM
   - Script: `Extract-WorkflowCaptures.ps1`
   - Consider `-DeleteAfterUpload` to manage disk space

2. **Monitor Results**
   - Check returned objects for session counts
   - Alert on failures

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
| Application | `%LOCALAPPDATA%\L7SWorkflowCapture\logs\` |

### Testing Locally

```powershell
# Test installation script
.\Install-WorkflowCapture.ps1 -InstallerSource "C:\Temp" -Verbose

# Test extraction script  
.\Extract-WorkflowCaptures.ps1 -DestinationPath "C:\Temp\TestExport" -Verbose
```
