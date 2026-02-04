# =============================================================================
# L7S Workflow Capture - Configuration Deployment Script for Ninja RMM
# =============================================================================
# This script deploys or updates the config.json file for L7S Workflow Capture
# allowing you to change recording settings across all clients without reinstalling.
#
# Deploy via Ninja RMM to update all machines simultaneously.
# Changes take effect when the app is next started (or restarted).
#
# Configuration Options:
#   - maxRecordingMinutes: Maximum recording duration (default: 5)
#   - videoBitrateMbps: Video quality bitrate (default: 5)
#
# Config Location: C:\temp\L7SWorkflowCapture\config.json
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [int]$MaxRecordingMinutes = 5,
    
    [Parameter(Mandatory=$false)]
    [int]$VideoBitrateMbps = 5,
    
    [Parameter(Mandatory=$false)]
    [switch]$RestartApp = $false
)

# Configuration
$AppName = "L7SWorkflowCapture"
$BasePath = "C:\temp"
$ConfigPath = Join-Path $BasePath "$AppName\config.json"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Log "=========================================="
Write-Log "L7S Workflow Capture - Config Deployment"
Write-Log "=========================================="

# Validate parameters
if ($MaxRecordingMinutes -lt 1 -or $MaxRecordingMinutes -gt 60) {
    Write-Log "ERROR: MaxRecordingMinutes must be between 1 and 60"
    exit 1
}

if ($VideoBitrateMbps -lt 1 -or $VideoBitrateMbps -gt 50) {
    Write-Log "ERROR: VideoBitrateMbps must be between 1 and 50"
    exit 1
}

# Ensure directory exists
$configDir = Split-Path $ConfigPath -Parent
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Write-Log "Created directory: $configDir"
}

# Build config object
$config = @{
    maxRecordingMinutes = $MaxRecordingMinutes
    videoBitrateMbps = $VideoBitrateMbps
}

# Write config file
try {
    $configJson = $config | ConvertTo-Json -Depth 2
    Set-Content -Path $ConfigPath -Value $configJson -Encoding UTF8 -Force
    Write-Log "Configuration saved to: $ConfigPath"
    Write-Log "Settings:"
    Write-Log "  - Max Recording Duration: $MaxRecordingMinutes minutes"
    Write-Log "  - Video Bitrate: $VideoBitrateMbps Mbps"
} catch {
    Write-Log "ERROR: Failed to write config: $_"
    exit 1
}

# Optionally restart the app to apply changes immediately
if ($RestartApp) {
    Write-Log "Restarting L7S Workflow Capture to apply changes..."
    
    # Find and stop the running app
    $appProcess = Get-Process -Name "L7S-Workflow-Capture" -ErrorAction SilentlyContinue
    if ($appProcess) {
        Write-Log "Stopping running instance..."
        $appProcess | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
    
    # Find the installed app path
    $possiblePaths = @(
        "${env:LOCALAPPDATA}\Programs\L7S-Workflow-Capture\L7S-Workflow-Capture.exe",
        "${env:ProgramFiles}\L7S-Workflow-Capture\L7S-Workflow-Capture.exe",
        "${env:ProgramFiles(x86)}\L7S-Workflow-Capture\L7S-Workflow-Capture.exe"
    )
    
    $appPath = $null
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $appPath = $path
            break
        }
    }
    
    if ($appPath) {
        Write-Log "Starting app from: $appPath"
        Start-Process -FilePath $appPath
        Write-Log "App restarted successfully"
    } else {
        Write-Log "WARNING: Could not find app executable to restart"
        Write-Log "Config will be applied when the app is next started manually"
    }
}

Write-Log "=========================================="
Write-Log "Configuration deployment complete"
Write-Log "=========================================="

# Return success for Ninja RMM
return @{
    Success = $true
    ConfigPath = $ConfigPath
    MaxRecordingMinutes = $MaxRecordingMinutes
    VideoBitrateMbps = $VideoBitrateMbps
}
