# =============================================================================
# L7S Workflow Capture - Data Extraction Script for Ninja RMM
# =============================================================================
# This script collects all workflow capture sessions from a user's machine
# and uploads them to a designated location (network share, cloud, etc.)
#
# Designed to be deployed via Ninja RMM for silent background extraction
#
# Data Structure:
#   %LOCALAPPDATA%\L7SWorkflowCapture\Sessions\
#   └── YYYY-MM-DD\                    (Date-organized folders)
#       └── {session-uuid}\            (Individual session)
#           ├── session.json           (Metadata: machine name, timestamps, notes)
#           └── recording_*.webm       (Screen recording)
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$DestinationPath = "\\server\share\WorkflowCaptures",
    
    [Parameter(Mandatory=$false)]
    [string]$ClientName = $env:COMPUTERNAME,
    
    [Parameter(Mandatory=$false)]
    [switch]$DeleteAfterUpload = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$Verbose = $false
)

# Configuration
$AppName = "L7SWorkflowCapture"
$SessionsFolder = "Sessions"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
}

function Get-SessionsPath {
    param([string]$UserProfile)
    
    $localAppData = Join-Path $UserProfile "AppData\Local"
    $sessionsPath = Join-Path $localAppData "$AppName\$SessionsFolder"
    
    return $sessionsPath
}

function Get-AllUserProfiles {
    # Get all user profile paths (excluding system accounts)
    $profiles = Get-ChildItem "C:\Users" -Directory | 
        Where-Object { 
            $_.Name -notin @("Public", "Default", "Default User", "All Users") -and
            -not $_.Name.StartsWith(".")
        } |
        Select-Object -ExpandProperty FullName
    
    return $profiles
}

function Get-SessionMetadata {
    param([string]$SessionPath)
    
    $metadataFile = Join-Path $SessionPath "session.json"
    
    if (Test-Path $metadataFile) {
        try {
            $content = Get-Content $metadataFile -Raw
            $metadata = $content | ConvertFrom-Json
            return $metadata
        } catch {
            Write-Log "Warning: Could not parse metadata at $metadataFile"
            return $null
        }
    }
    
    return $null
}

function Export-UserSessions {
    param(
        [string]$UserProfile,
        [string]$DestinationBase
    )
    
    $username = Split-Path $UserProfile -Leaf
    $sessionsPath = Get-SessionsPath -UserProfile $UserProfile
    
    if (-not (Test-Path $sessionsPath)) {
        if ($Verbose) { Write-Log "No sessions found for user: $username" }
        return $null
    }
    
    Write-Log "Processing sessions for user: $username"
    
    # Count sessions
    $sessionCount = 0
    $totalSize = 0
    
    # Collect all sessions (supports date-organized structure)
    $dateFolders = Get-ChildItem $sessionsPath -Directory -ErrorAction SilentlyContinue
    
    foreach ($dateFolder in $dateFolders) {
        # Check if this is a date folder (YYYY-MM-DD) or legacy session folder
        if ($dateFolder.Name -match '^\d{4}-\d{2}-\d{2}$') {
            # New date-organized structure
            $sessionFolders = Get-ChildItem $dateFolder.FullName -Directory -ErrorAction SilentlyContinue
            foreach ($session in $sessionFolders) {
                $metadata = Get-SessionMetadata -SessionPath $session.FullName
                if ($metadata) {
                    $sessionCount++
                    $folderSize = (Get-ChildItem $session.FullName -Recurse | Measure-Object -Property Length -Sum).Sum
                    $totalSize += $folderSize
                }
            }
        } else {
            # Legacy structure (session folder directly under Sessions)
            $metadata = Get-SessionMetadata -SessionPath $dateFolder.FullName
            if ($metadata) {
                $sessionCount++
                $folderSize = (Get-ChildItem $dateFolder.FullName -Recurse | Measure-Object -Property Length -Sum).Sum
                $totalSize += $folderSize
            }
        }
    }
    
    if ($sessionCount -eq 0) {
        if ($Verbose) { Write-Log "No valid sessions found for user: $username" }
        return $null
    }
    
    Write-Log "Found $sessionCount sessions for $username ($('{0:N2}' -f ($totalSize / 1MB)) MB)"
    
    # Create zip archive
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $zipFileName = "${ClientName}_${username}_${timestamp}.zip"
    $tempZipPath = Join-Path $env:TEMP $zipFileName
    
    try {
        # Create the zip file
        Write-Log "Creating archive: $zipFileName"
        Compress-Archive -Path $sessionsPath -DestinationPath $tempZipPath -Force
        
        # Move to destination
        $destinationFolder = Join-Path $DestinationBase $ClientName
        if (-not (Test-Path $destinationFolder)) {
            New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
        }
        
        $finalPath = Join-Path $destinationFolder $zipFileName
        Move-Item -Path $tempZipPath -Destination $finalPath -Force
        
        Write-Log "Uploaded: $finalPath"
        
        # Optionally delete local sessions after successful upload
        if ($DeleteAfterUpload) {
            Write-Log "Cleaning up local sessions for user: $username"
            Remove-Item -Path $sessionsPath -Recurse -Force
        }
        
        return @{
            User = $username
            Sessions = $sessionCount
            SizeMB = [math]::Round($totalSize / 1MB, 2)
            Archive = $finalPath
        }
    } catch {
        Write-Log "Error creating archive for $username : $_"
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue
        }
        return $null
    }
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Log "=========================================="
Write-Log "L7S Workflow Capture - Data Extraction"
Write-Log "Client: $ClientName"
Write-Log "Destination: $DestinationPath"
Write-Log "=========================================="

# Validate destination
if (-not (Test-Path $DestinationPath)) {
    Write-Log "ERROR: Destination path does not exist: $DestinationPath"
    exit 1
}

# Get all user profiles
$userProfiles = Get-AllUserProfiles
Write-Log "Found $($userProfiles.Count) user profile(s) to check"

# Process each user
$results = @()

foreach ($profile in $userProfiles) {
    $result = Export-UserSessions -UserProfile $profile -DestinationBase $DestinationPath
    if ($result) {
        $results += $result
    }
}

# Summary
Write-Log "=========================================="
Write-Log "Extraction Complete"
Write-Log "=========================================="

if ($results.Count -gt 0) {
    $totalSessions = ($results | Measure-Object -Property Sessions -Sum).Sum
    $totalSizeMB = ($results | Measure-Object -Property SizeMB -Sum).Sum
    
    Write-Log "Total users with sessions: $($results.Count)"
    Write-Log "Total sessions extracted: $totalSessions"
    Write-Log "Total data size: $('{0:N2}' -f $totalSizeMB) MB"
    
    foreach ($r in $results) {
        Write-Log "  - $($r.User): $($r.Sessions) sessions ($($r.SizeMB) MB)"
    }
} else {
    Write-Log "No workflow capture sessions found on this machine"
}

Write-Log "=========================================="

# Return results for Ninja RMM reporting
return $results
