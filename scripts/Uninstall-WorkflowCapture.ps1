# =============================================================================
# L7S Workflow Capture - Silent Uninstallation Script
# =============================================================================
# This script silently uninstalls the Workflow Capture application
# from Windows client machines.
#
# Designed to be deployed via Ninja RMM for mass removal
#
# Usage:
#   .\Uninstall-WorkflowCapture.ps1
#   .\Uninstall-WorkflowCapture.ps1 -KeepData
#   .\Uninstall-WorkflowCapture.ps1 -ExportDataFirst -ExportPath "\\server\share"
#
# Exit Codes:
#   0 - Success (or not installed)
#   1 - General error
#   3 - Uninstallation failed
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [switch]$KeepData = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$ExportDataFirst = $false,
    
    [Parameter(Mandatory=$false)]
    [string]$ExportPath = ""
)

# =============================================================================
# Configuration
# =============================================================================

$AppName = "L7S Workflow Capture"
$AppPublisher = "Layer 7 Systems"
$LogPath = "$env:TEMP\L7S-WorkflowCapture-Uninstall.log"

# =============================================================================
# Functions
# =============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARN"    { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage }
    }
    
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
}

function Stop-ApplicationProcesses {
    Write-Log "Checking for running instances..."
    
    $processNames = @(
        "Workflow Capture"
    )
    
    foreach ($name in $processNames) {
        $processes = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($processes) {
            Write-Log "Stopping process: $name (PID: $($processes.Id -join ', '))"
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }
}

function Find-UninstallString {
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($keyPath in $uninstallKeys) {
        $apps = Get-ItemProperty $keyPath -ErrorAction SilentlyContinue | 
                Where-Object { 
                    $_.DisplayName -like "*Workflow Capture*" -or 
                    $_.Publisher -eq $AppPublisher 
                }
        
        if ($apps) {
            foreach ($app in $apps) {
                if ($app.UninstallString) {
                    Write-Log "Found uninstaller: $($app.DisplayName)"
                    return @{
                        DisplayName = $app.DisplayName
                        UninstallString = $app.UninstallString
                        InstallLocation = $app.InstallLocation
                        Version = $app.DisplayVersion
                    }
                }
            }
        }
    }
    
    return $null
}

function Find-ManualInstallation {
    $possiblePaths = @(
        "$env:LOCALAPPDATA\Programs\l7s-workflow-capture",
        "${env:ProgramFiles}\Workflow Capture",
        "${env:ProgramFiles(x86)}\Workflow Capture"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $uninstaller = Join-Path $path "Uninstall Workflow Capture.exe"
            if (Test-Path $uninstaller) {
                Write-Log "Found manual installation at: $path"
                return @{
                    DisplayName = $AppName
                    UninstallString = "`"$uninstaller`""
                    InstallLocation = $path
                    Version = "Unknown"
                }
            }
        }
    }
    
    return $null
}

function Export-SessionData {
    param([string]$Destination)
    
    if (-not $Destination) {
        Write-Log "No export destination specified" -Level "WARN"
        return $false
    }
    
    $sessionsPath = "C:\temp\L7SWorkflowCapture\Sessions"
    
    if (-not (Test-Path $sessionsPath)) {
        Write-Log "No recording files found to export"
        return $true
    }
    
    # Get all .webm files
    $recordings = Get-ChildItem $sessionsPath -Filter "*.webm" -File -ErrorAction SilentlyContinue
    
    if (-not $recordings -or $recordings.Count -eq 0) {
        Write-Log "No recording files found to export"
        return $true
    }
    
    # Create user folder in destination
    $userFolder = Join-Path $Destination $env:USERNAME
    
    if (-not (Test-Path $userFolder)) {
        New-Item -ItemType Directory -Path $userFolder -Force | Out-Null
    }
    
    try {
        Write-Log "Exporting $($recordings.Count) recording(s) to: $userFolder"
        foreach ($recording in $recordings) {
            $destPath = Join-Path $userFolder $recording.Name
            Copy-Item -Path $recording.FullName -Destination $destPath -Force
            Write-Log "Exported: $($recording.Name)"
        }
        Write-Log "Recording files exported successfully" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Failed to export recording files: $_" -Level "ERROR"
        return $false
    }
}

function Remove-SessionData {
    $dataPath = "C:\temp\L7SWorkflowCapture"
    
    if (Test-Path $dataPath) {
        Write-Log "Removing recording files: $dataPath"
        try {
            Remove-Item -Path $dataPath -Recurse -Force -ErrorAction Stop
            Write-Log "Recording files removed" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to remove some recording files: $_" -Level "WARN"
        }
    }
}

function Remove-AutoStartEntry {
    $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $shortcutPath = Join-Path $startupPath "Workflow Capture.lnk"
    
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
        Write-Log "Removed auto-start shortcut"
    }
}

function Remove-DesktopShortcuts {
    $desktopPaths = @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory")
    )
    
    foreach ($desktop in $desktopPaths) {
        $shortcut = Join-Path $desktop "Workflow Capture.lnk"
        if (Test-Path $shortcut) {
            Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "Removed desktop shortcut: $shortcut"
        }
    }
}

function Invoke-Uninstaller {
    param([string]$UninstallString)
    
    Write-Log "Running uninstaller..."
    
    # Parse uninstall string - it might be quoted
    $uninstallCmd = $UninstallString -replace '"', ''
    
    # Add silent flags for NSIS
    $arguments = "/S"
    
    try {
        if ($uninstallCmd -match "\.exe$") {
            $process = Start-Process -FilePath $uninstallCmd `
                                     -ArgumentList $arguments `
                                     -Wait `
                                     -PassThru `
                                     -NoNewWindow
            
            if ($process.ExitCode -eq 0) {
                Write-Log "Uninstaller completed successfully" -Level "SUCCESS"
                return $true
            } else {
                Write-Log "Uninstaller exited with code: $($process.ExitCode)" -Level "WARN"
                return $false
            }
        } else {
            # Try running as command
            $result = cmd /c "$UninstallString /S" 2>&1
            Write-Log "Uninstall command completed"
            return $true
        }
    } catch {
        Write-Log "Uninstaller failed: $_" -Level "ERROR"
        return $false
    }
}

function Remove-LeftoverFiles {
    param([string]$InstallLocation)
    
    # Wait for uninstaller to fully complete
    Start-Sleep -Seconds 2
    
    # Remove installation directory if it still exists
    if ($InstallLocation -and (Test-Path $InstallLocation)) {
        Write-Log "Removing leftover installation files: $InstallLocation"
        try {
            Remove-Item -Path $InstallLocation -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Log "Could not remove some installation files: $_" -Level "WARN"
        }
    }
    
    # Clean up common leftover locations
    $leftovers = @(
        "$env:LOCALAPPDATA\Programs\l7s-workflow-capture",
        "$env:APPDATA\l7s-workflow-capture"
    )
    
    foreach ($path in $leftovers) {
        if (Test-Path $path) {
            try {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                Write-Log "Removed leftover: $path"
            } catch {
                Write-Log "Could not remove: $path" -Level "WARN"
            }
        }
    }
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Log "=========================================="
Write-Log "$AppName - Silent Uninstallation"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $env:USERNAME"
Write-Log "=========================================="

# Stop any running instances
Stop-ApplicationProcesses

# Find installation
$installation = Find-UninstallString
if (-not $installation) {
    $installation = Find-ManualInstallation
}

if (-not $installation) {
    Write-Log "Application is not installed on this system" -Level "WARN"
    Remove-AutoStartEntry
    Remove-DesktopShortcuts
    exit 0
}

Write-Log "Found installation:"
Write-Log "  Name: $($installation.DisplayName)"
Write-Log "  Version: $($installation.Version)"
Write-Log "  Location: $($installation.InstallLocation)"

# Export data if requested
if ($ExportDataFirst -and $ExportPath) {
    $exportSuccess = Export-SessionData -Destination $ExportPath
    if (-not $exportSuccess) {
        Write-Log "Continuing with uninstall despite export failure..." -Level "WARN"
    }
}

# Run uninstaller
$uninstallSuccess = Invoke-Uninstaller -UninstallString $installation.UninstallString

if (-not $uninstallSuccess) {
    Write-Log "Uninstallation may have failed - attempting cleanup anyway" -Level "WARN"
}

# Remove leftover files
Remove-LeftoverFiles -InstallLocation $installation.InstallLocation

# Remove shortcuts and auto-start
Remove-AutoStartEntry
Remove-DesktopShortcuts

# Remove session data unless keeping
if (-not $KeepData) {
    Remove-SessionData
} else {
    Write-Log "Keeping session data as requested"
    Write-Log "Data location: C:\temp\L7SWorkflowCapture"
}

# Summary
Write-Log "=========================================="
Write-Log "Uninstallation Complete" -Level "SUCCESS"
Write-Log "=========================================="
Write-Log "Data Preserved: $(if ($KeepData) { 'Yes' } else { 'No' })"
Write-Log "Log File: $LogPath"
Write-Log "=========================================="

# Return result for Ninja RMM
$result = @{
    Success = $true
    ComputerName = $env:COMPUTERNAME
    DataPreserved = $KeepData.IsPresent
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

return $result
