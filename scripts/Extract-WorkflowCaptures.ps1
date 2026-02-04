# =============================================================================
# L7S Workflow Capture - Data Extraction Script for Ninja RMM
# =============================================================================
# This script collects all workflow capture recordings from the machine
# and copies them to a designated network share.
#
# Designed to be deployed via Ninja RMM for silent background extraction
# Runs 2-3 times per day - archives local recordings after upload (not deleted)
#
# IMPORTANT: Must run as the logged-in user (not SYSTEM) to access network share
# In Ninja RMM: Set "Run As" to "Logged-in User" or "Current User"
#
# Data Structure (Local):
#   C:\temp\L7SWorkflowCapture\Sessions\
#   └── YYYY-MM-DD_HHMMSS_machineName_taskDescription.webm
#
# Archive Structure (Local - NOT uploaded):
#   C:\temp\L7SWorkflowCapture\Archive\
#   └── recordings_YYYY-MM-DD_HHMMSS_machineName.zip
#
# Data Structure (Network Destination):
#   \\server\share\
#   └── {USERNAME}\                    (User-specific folder)
#       └── YYYY-MM-DD_HHMMSS_machineName_taskDescription.webm
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$DestinationPath = "\\bulley-fs1\workflow",
    
    [Parameter(Mandatory=$false)]
    [switch]$VerboseOutput = $false
)

# Configuration
$AppName = "L7SWorkflowCapture"
$SessionsFolder = "Sessions"
$ArchiveFolder = "Archive"
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

function Get-ArchivePath {
    # Archive folder - separate from Sessions so it won't get picked up
    return Join-Path $BasePath "$AppName\$ArchiveFolder"
}

function Remove-OldArchives {
    param(
        [int]$DaysToKeep = 7
    )
    
    $archivePath = Get-ArchivePath
    
    if (-not (Test-Path $archivePath)) {
        return
    }
    
    $cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
    $oldArchives = Get-ChildItem $archivePath -Filter "*.zip" -File -ErrorAction SilentlyContinue | 
                   Where-Object { $_.LastWriteTime -lt $cutoffDate }
    
    if (-not $oldArchives -or $oldArchives.Count -eq 0) {
        Write-Log "No archives older than $DaysToKeep days found"
        return
    }
    
    Write-Log "Found $($oldArchives.Count) archive(s) older than $DaysToKeep days"
    
    foreach ($archive in $oldArchives) {
        try {
            Remove-Item -Path $archive.FullName -Force
            Write-Log "Deleted old archive: $($archive.Name)"
        } catch {
            Write-Log "WARNING: Could not delete $($archive.Name): $_"
        }
    }
}

function Archive-Recordings {
    param(
        [string[]]$FilesToArchive
    )
    
    if ($FilesToArchive.Count -eq 0) {
        return
    }
    
    $archivePath = Get-ArchivePath
    
    # Create archive folder if it doesn't exist
    if (-not (Test-Path $archivePath)) {
        New-Item -ItemType Directory -Path $archivePath -Force | Out-Null
        Write-Log "Created archive folder: $archivePath"
    }
    
    # Create zip filename with timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $zipName = "recordings_${timestamp}_$env:COMPUTERNAME.zip"
    $zipPath = Join-Path $archivePath $zipName
    
    Write-Log "Archiving $($FilesToArchive.Count) recording(s) to: $zipName"
    
    try {
        # Create the zip archive
        Compress-Archive -Path $FilesToArchive -DestinationPath $zipPath -Force
        Write-Log "Archive created: $zipPath"
        
        # Remove original files after successful archive
        foreach ($file in $FilesToArchive) {
            try {
                Remove-Item -Path $file -Force
                Write-Log "Removed original: $(Split-Path $file -Leaf)"
            } catch {
                Write-Log "WARNING: Could not remove $file`: $_"
            }
        }
        
        return $zipPath
    } catch {
        Write-Log "ERROR: Failed to create archive: $_"
        return $null
    }
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
    
    # Filter out files that might be actively recording (modified in last 2 minutes)
    $cutoffTime = (Get-Date).AddMinutes(-2)
    $safeRecordings = $recordings | Where-Object { $_.LastWriteTime -lt $cutoffTime }
    $skippedCount = $recordings.Count - $safeRecordings.Count
    
    if ($skippedCount -gt 0) {
        Write-Log "Skipping $skippedCount file(s) that may be actively recording (modified < 2 min ago)"
    }
    
    if (-not $safeRecordings -or $safeRecordings.Count -eq 0) {
        Write-Log "No safe recordings to process (all may be in active use)"
        return $null
    }
    
    $totalSize = ($safeRecordings | Measure-Object -Property Length -Sum).Sum
    Write-Log "Found $($safeRecordings.Count) recording(s) ready for extraction ($('{0:N2}' -f ($totalSize / 1MB)) MB)"
    
    # Create destination folder using USERNAME
    $userFolder = Join-Path $DestinationBase $env:USERNAME
    
    if (-not (Test-Path $userFolder)) {
        New-Item -ItemType Directory -Path $userFolder -Force | Out-Null
        Write-Log "Created destination folder: $userFolder"
    }
    
    $copiedCount = 0
    $copiedFiles = @()
    
    foreach ($recording in $safeRecordings) {
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
    
    # Archive successfully copied files (zip and move to archive folder)
    $archivePath = $null
    if ($copiedFiles.Count -gt 0) {
        Write-Log "Archiving $($copiedFiles.Count) copied recording(s)..."
        $archivePath = Archive-Recordings -FilesToArchive $copiedFiles
    }
    
    return @{
        Recordings = $copiedCount
        SizeMB = [math]::Round($totalSize / 1MB, 2)
        Destination = $userFolder
        ArchivePath = $archivePath
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
Write-Log "Archive: $(Get-ArchivePath)"
Write-Log "Destination: $DestinationPath\$env:USERNAME"
Write-Log "Note: Local recordings will be zipped and archived after upload"
Write-Log "=========================================="

# Validate destination
if (-not (Test-Path $DestinationPath)) {
    Write-Log "ERROR: Destination path does not exist: $DestinationPath"
    exit 1
}

# Copy recordings to network share
$result = Copy-Recordings -DestinationBase $DestinationPath

# Clean up old archives (older than 7 days)
Remove-OldArchives -DaysToKeep 7

# Summary
Write-Log "=========================================="
Write-Log "Extraction Complete"
Write-Log "=========================================="

if ($result) {
    Write-Log "Total recordings copied: $($result.Recordings)"
    Write-Log "Total data size: $('{0:N2}' -f $result.SizeMB) MB"
    Write-Log "Destination: $($result.Destination)"
    if ($result.ArchivePath) {
        Write-Log "Archived to: $($result.ArchivePath)"
    }
} else {
    Write-Log "No new workflow capture recordings found on this machine"
}

Write-Log "=========================================="

# Return results for Ninja RMM reporting
return $result
