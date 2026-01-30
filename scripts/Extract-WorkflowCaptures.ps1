# =============================================================================
# L7S Workflow Capture - Data Extraction Script for Ninja RMM
# =============================================================================
# This script collects all workflow capture recordings from the machine
# and copies them to a designated network share.
#
# Designed to be deployed via Ninja RMM for silent background extraction
# Runs 2-3 times per day - automatically deletes local recordings after upload
#
# IMPORTANT: Must run as the logged-in user (not SYSTEM) to access network share
# In Ninja RMM: Set "Run As" to "Logged-in User" or "Current User"
#
# Data Structure (Local):
#   C:\temp\L7SWorkflowCapture\Sessions\
#   └── YYYY-MM-DD_HHMMSS_machineName_taskDescription.webm
#
# Data Structure (Network Destination):
#   \\server\share\
#   └── {USERNAME}\                    (User-specific folder)
#       └── YYYY-MM-DD_HHMMSS_machineName_taskDescription.webm
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$DestinationPath = "\\Bulley-fs1\workflow",
    
    [Parameter(Mandatory=$false)]
    [switch]$Verbose = $false
)

# Configuration
$AppName = "L7SWorkflowCapture"
$SessionsFolder = "Sessions"
$BasePath = "C:\temp"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
}

function Get-SessionsPath {
    # User-agnostic path - all sessions stored in C:\temp
    return Join-Path $BasePath "$AppName\$SessionsFolder"
}

function Copy-Recordings {
    param(
        [string]$DestinationBase
    )
    
    $sessionsPath = Get-SessionsPath
    
    if (-not (Test-Path $sessionsPath)) {
        Write-Log "No sessions directory found at: $sessionsPath"
        return $null
    }
    
    Write-Log "Processing recordings from: $sessionsPath"
    
    # Get all .webm files
    $recordings = Get-ChildItem $sessionsPath -Filter "*.webm" -File -ErrorAction SilentlyContinue
    
    if (-not $recordings -or $recordings.Count -eq 0) {
        Write-Log "No recordings found"
        return $null
    }
    
    $totalSize = ($recordings | Measure-Object -Property Length -Sum).Sum
    Write-Log "Found $($recordings.Count) recording(s) ($('{0:N2}' -f ($totalSize / 1MB)) MB)"
    
    # Create destination folder using USERNAME
    $userFolder = Join-Path $DestinationBase $env:USERNAME
    
    if (-not (Test-Path $userFolder)) {
        New-Item -ItemType Directory -Path $userFolder -Force | Out-Null
        Write-Log "Created destination folder: $userFolder"
    }
    
    $copiedCount = 0
    $copiedFiles = @()
    
    foreach ($recording in $recordings) {
        $destPath = Join-Path $userFolder $recording.Name
        
        try {
            Copy-Item -Path $recording.FullName -Destination $destPath -Force
            Write-Log "Copied: $($recording.Name)"
            $copiedFiles += $recording.FullName
            $copiedCount++
        } catch {
            Write-Log "ERROR: Failed to copy $($recording.Name): $_"
        }
    }
    
    # Delete successfully copied files
    if ($copiedFiles.Count -gt 0) {
        Write-Log "Cleaning up $($copiedFiles.Count) copied recording(s)..."
        foreach ($file in $copiedFiles) {
            try {
                Remove-Item -Path $file -Force
                Write-Log "Deleted: $(Split-Path $file -Leaf)"
            } catch {
                Write-Log "WARNING: Could not delete $file`: $_"
            }
        }
    }
    
    return @{
        Recordings = $copiedCount
        SizeMB = [math]::Round($totalSize / 1MB, 2)
        Destination = $userFolder
    }
}

# =============================================================================
# Main Execution
# =============================================================================

# Verify script is running as a user (not SYSTEM)
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($currentUser -match "SYSTEM|LOCAL SERVICE|NETWORK SERVICE") {
    Write-Log "ERROR: This script must run as a logged-in user, not $currentUser"
    Write-Log "In Ninja RMM, set 'Run As' to 'Logged-in User' or 'Current User'"
    exit 1
}

Write-Log "=========================================="
Write-Log "L7S Workflow Capture - Data Extraction"
Write-Log "Running as: $currentUser"
Write-Log "Username: $env:USERNAME"
Write-Log "Source: $(Get-SessionsPath)"
Write-Log "Destination: $DestinationPath\$env:USERNAME"
Write-Log "Note: Local recordings will be deleted after upload"
Write-Log "=========================================="

# Validate destination
if (-not (Test-Path $DestinationPath)) {
    Write-Log "ERROR: Destination path does not exist: $DestinationPath"
    exit 1
}

# Copy recordings to network share
$result = Copy-Recordings -DestinationBase $DestinationPath

# Summary
Write-Log "=========================================="
Write-Log "Extraction Complete"
Write-Log "=========================================="

if ($result) {
    Write-Log "Total recordings copied: $($result.Recordings)"
    Write-Log "Total data size: $('{0:N2}' -f $result.SizeMB) MB"
    Write-Log "Destination: $($result.Destination)"
    Write-Log "Local recordings cleaned up: Yes"
} else {
    Write-Log "No new workflow capture recordings found on this machine"
}

Write-Log "=========================================="

# Return results for Ninja RMM reporting
return $result
