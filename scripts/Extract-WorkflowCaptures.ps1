# =============================================================================
# L7S Workflow Capture - Data Extraction Script for Ninja RMM
# =============================================================================
# This script collects all workflow capture sessions from the machine
# and uploads them to a designated location (network share, cloud, etc.)
#
# Designed to be deployed via Ninja RMM for silent background extraction
#
# Data Structure:
#   C:\temp\L7SWorkflowCapture\Sessions\
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

function Export-Sessions {
    param(
        [string]$DestinationBase
    )
    
    $sessionsPath = Get-SessionsPath
    
    if (-not (Test-Path $sessionsPath)) {
        Write-Log "No sessions directory found at: $sessionsPath"
        return $null
    }
    
    Write-Log "Processing sessions from: $sessionsPath"
    
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
        Write-Log "No valid sessions found"
        return $null
    }
    
    Write-Log "Found $sessionCount sessions ($('{0:N2}' -f ($totalSize / 1MB)) MB)"
    
    # Create zip archive
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $zipFileName = "${ClientName}_${timestamp}.zip"
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
            Write-Log "Cleaning up local sessions..."
            Remove-Item -Path $sessionsPath -Recurse -Force
        }
        
        return @{
            Sessions = $sessionCount
            SizeMB = [math]::Round($totalSize / 1MB, 2)
            Archive = $finalPath
        }
    } catch {
        Write-Log "Error creating archive: $_"
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
Write-Log "Source: $(Get-SessionsPath)"
Write-Log "Destination: $DestinationPath"
Write-Log "=========================================="

# Validate destination
if (-not (Test-Path $DestinationPath)) {
    Write-Log "ERROR: Destination path does not exist: $DestinationPath"
    exit 1
}

# Process sessions from the shared location
$result = Export-Sessions -DestinationBase $DestinationPath

# Summary
Write-Log "=========================================="
Write-Log "Extraction Complete"
Write-Log "=========================================="

if ($result) {
    Write-Log "Total sessions extracted: $($result.Sessions)"
    Write-Log "Total data size: $('{0:N2}' -f $result.SizeMB) MB"
    Write-Log "Archive: $($result.Archive)"
} else {
    Write-Log "No workflow capture sessions found on this machine"
}

Write-Log "=========================================="

# Return results for Ninja RMM reporting
return $result
