# =============================================================================
# L7S Workflow Capture - Video Conversion & Session Data Extraction
# =============================================================================
# Converts .webm workflow recordings from the network share to .mp4 format
# and builds a cumulative CSV of all session metadata.
#
# Runs on the utility server with ffmpeg installed via Chocolatey.
# Designed to be idempotent - skips files already converted.
#
# Source:
#   \\bulley-fs1\workflow\{USERNAME}\
#   └── YYYY-MM-DD_HHMMSS_machineName_taskDescription.webm
#
# Output:
#   C:\temp\WorkflowProcessing\
#   ├── {username}_YYYY-MM-DD_HHMMSS_machineName_taskDescription.mp4
#   └── workflow_sessions.csv
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$SourceShare = "\\bulley-fs1\workflow",

    [Parameter(Mandatory=$false)]
    [string]$OutputRoot = "C:\temp\WorkflowProcessing",

    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "",

    [Parameter(Mandatory=$false)]
    [string]$FfmpegPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,

    [Parameter(Mandatory=$false)]
    [string]$SingleUser = "",

    [Parameter(Mandatory=$false)]
    [int]$CrfQuality = 23,

    [Parameter(Mandatory=$false)]
    [string]$Preset = "medium"
)

# Derive CSV path if not specified
if (-not $CsvPath) {
    $CsvPath = Join-Path $OutputRoot "workflow_sessions.csv"
}

# =============================================================================
# Logging
# =============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

# =============================================================================
# FFmpeg / FFprobe Discovery
# =============================================================================

function Find-Ffmpeg {
    param([string]$ExplicitPath)

    # 1. Explicit parameter
    if ($ExplicitPath -and (Test-Path $ExplicitPath)) {
        Write-Log "Using explicit ffmpeg: $ExplicitPath"
        return $ExplicitPath
    }

    # 2. Chocolatey install path
    $chocoPath = "C:\ProgramData\chocolatey\bin\ffmpeg.exe"
    if (Test-Path $chocoPath) {
        Write-Log "Found ffmpeg via Chocolatey: $chocoPath"
        return $chocoPath
    }

    # 3. PATH lookup
    $pathResult = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($pathResult) {
        Write-Log "Found ffmpeg on PATH: $($pathResult.Source)"
        return $pathResult.Source
    }

    return $null
}

function Find-Ffprobe {
    param([string]$FfmpegDir)

    # Same directory as ffmpeg
    if ($FfmpegDir) {
        $probePath = Join-Path $FfmpegDir "ffprobe.exe"
        if (Test-Path $probePath) { return $probePath }
    }

    # Chocolatey
    $chocoPath = "C:\ProgramData\chocolatey\bin\ffprobe.exe"
    if (Test-Path $chocoPath) { return $chocoPath }

    # PATH
    $pathResult = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($pathResult) { return $pathResult.Source }

    return $null
}

# =============================================================================
# Filename Parsing
# =============================================================================

function Parse-WorkflowFilename {
    param(
        [string]$FileName,
        [string]$Username
    )

    # Format: YYYY-MM-DD_HHMMSS_MACHINENAME_TaskDescription.webm
    # Machine names can contain hyphens (e.g., AALEKIC-LWX1)
    # Task descriptions can contain &, ', and other characters
    $pattern = '^(\d{4}-\d{2}-\d{2})_(\d{6})_([A-Za-z0-9]+-[A-Za-z0-9]+)_(.+)\.webm$'

    if ($FileName -match $pattern) {
        $dateStr = $Matches[1]
        $timeStr = $Matches[2]
        $machineName = $Matches[3]
        $taskRaw = $Matches[4]

        # Format time as HH:mm:ss
        $formattedTime = "$($timeStr.Substring(0,2)):$($timeStr.Substring(2,2)):$($timeStr.Substring(4,2))"

        # Convert underscores to spaces in task description
        $taskDescription = $taskRaw -replace '_', ' '

        # Build timestamp
        $timestamp = "${dateStr}T${formattedTime}"

        # Day of week
        try {
            $dt = [datetime]::ParseExact("${dateStr} ${formattedTime}", "yyyy-MM-dd HH:mm:ss", $null)
            $dayOfWeek = $dt.DayOfWeek.ToString()
            $hourOfDay = $dt.Hour
        } catch {
            $dayOfWeek = "Unknown"
            $hourOfDay = -1
        }

        return @{
            Date           = $dateStr
            Time           = $formattedTime
            Timestamp      = $timestamp
            MachineName    = $machineName
            TaskDescription = $taskDescription
            Username       = $Username
            DayOfWeek      = $dayOfWeek
            HourOfDay      = $hourOfDay
            ParsedOk       = $true
        }
    }

    # Fallback: try a looser pattern for edge cases
    $loosePattern = '^(\d{4}-\d{2}-\d{2})_(\d{6})_([^_]+)_(.+)\.webm$'
    if ($FileName -match $loosePattern) {
        $dateStr = $Matches[1]
        $timeStr = $Matches[2]
        $machineName = $Matches[3]
        $taskRaw = $Matches[4]

        $formattedTime = "$($timeStr.Substring(0,2)):$($timeStr.Substring(2,2)):$($timeStr.Substring(4,2))"
        $taskDescription = $taskRaw -replace '_', ' '
        $timestamp = "${dateStr}T${formattedTime}"

        try {
            $dt = [datetime]::ParseExact("${dateStr} ${formattedTime}", "yyyy-MM-dd HH:mm:ss", $null)
            $dayOfWeek = $dt.DayOfWeek.ToString()
            $hourOfDay = $dt.Hour
        } catch {
            $dayOfWeek = "Unknown"
            $hourOfDay = -1
        }

        return @{
            Date           = $dateStr
            Time           = $formattedTime
            Timestamp      = $timestamp
            MachineName    = $machineName
            TaskDescription = $taskDescription
            Username       = $Username
            DayOfWeek      = $dayOfWeek
            HourOfDay      = $hourOfDay
            ParsedOk       = $true
        }
    }

    Write-Log "WARNING: Could not parse filename: $FileName" "WARN"
    return @{ ParsedOk = $false }
}

# =============================================================================
# FFprobe Metadata
# =============================================================================

function Get-VideoDuration {
    param(
        [string]$FilePath,
        [string]$FfprobePath
    )

    try {
        # 2>$null discards stderr cleanly; 2>&1 would mix ErrorRecord objects into JSON
        $jsonOutput = & $FfprobePath -v quiet -print_format json -show_format $FilePath 2>$null

        if (-not $jsonOutput) {
            Write-Log "WARNING: ffprobe returned no output for $(Split-Path $FilePath -Leaf)" "WARN"
            return -1
        }

        # Join output lines into a single string for ConvertFrom-Json
        $jsonString = ($jsonOutput | Out-String).Trim()
        $formatInfo = $jsonString | ConvertFrom-Json

        if ($formatInfo.format -and $formatInfo.format.duration) {
            return [math]::Round([double]$formatInfo.format.duration, 1)
        }
    } catch {
        Write-Log "WARNING: ffprobe failed for $(Split-Path $FilePath -Leaf): $_" "WARN"
    }

    return -1
}

# =============================================================================
# Video Conversion
# =============================================================================

function Convert-WebmToMp4 {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [string]$FfmpegExe,
        [int]$Crf,
        [string]$PresetName
    )

    $ffmpegArgs = @(
        "-i", $InputPath,
        "-c:v", "libx264",
        "-crf", $Crf.ToString(),
        "-preset", $PresetName,
        "-c:a", "aac",
        "-b:a", "128k",
        "-movflags", "+faststart",
        "-y",
        "-loglevel", "error",
        $OutputPath
    )

    try {
        $process = Start-Process -FilePath $FfmpegExe -ArgumentList $ffmpegArgs -Wait -PassThru -NoNewWindow -RedirectStandardError "$env:TEMP\ffmpeg_err.log"

        if ($process.ExitCode -ne 0) {
            $errMsg = ""
            if (Test-Path "$env:TEMP\ffmpeg_err.log") {
                $errMsg = Get-Content "$env:TEMP\ffmpeg_err.log" -Raw -ErrorAction SilentlyContinue
            }
            Write-Log "ERROR: ffmpeg exited with code $($process.ExitCode) for $(Split-Path $InputPath -Leaf)" "ERROR"
            if ($errMsg) { Write-Log "  ffmpeg stderr: $errMsg" "ERROR" }

            # Clean up partial output
            if (Test-Path $OutputPath) {
                Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            }
            return $false
        }

        # Verify output exists and is non-zero
        if (-not (Test-Path $OutputPath)) {
            Write-Log "ERROR: ffmpeg produced no output for $(Split-Path $InputPath -Leaf)" "ERROR"
            return $false
        }

        $outSize = (Get-Item $OutputPath).Length
        if ($outSize -eq 0) {
            Write-Log "ERROR: ffmpeg produced empty output for $(Split-Path $InputPath -Leaf)" "ERROR"
            Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            return $false
        }

        return $true
    } catch {
        Write-Log "ERROR: Failed to run ffmpeg for $(Split-Path $InputPath -Leaf): $_" "ERROR"
        if (Test-Path $OutputPath) {
            Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# =============================================================================
# CSV Management
# =============================================================================

function Initialize-CsvFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        $header = "SourcePath,Mp4Path,Username,Date,Time,Timestamp,MachineName,TaskDescription,DayOfWeek,HourOfDay,DurationSeconds,FileSizeMB,ConvertedAt"
        [System.IO.File]::WriteAllText($Path, "$header`r`n", [System.Text.UTF8Encoding]::new($false))
        Write-Log "Created CSV: $Path"
    }
}

function Get-ExistingCsvEntries {
    param([string]$Path)

    $existing = @{}

    if (Test-Path $Path) {
        try {
            $rows = Import-Csv $Path -ErrorAction SilentlyContinue
            foreach ($row in $rows) {
                if ($row.SourcePath) {
                    $existing[$row.SourcePath] = $true
                }
            }
        } catch {
            Write-Log "WARNING: Could not read existing CSV: $_" "WARN"
        }
    }

    return $existing
}

function Append-CsvRow {
    param(
        [string]$Path,
        [hashtable]$Data
    )

    # Escape fields that may contain commas or quotes
    function Escape-CsvField {
        param([string]$Value)
        if ($Value -match '[,"\r\n]') {
            return '"' + ($Value -replace '"', '""') + '"'
        }
        return $Value
    }

    $row = @(
        (Escape-CsvField $Data.SourcePath),
        (Escape-CsvField $Data.Mp4Path),
        (Escape-CsvField $Data.Username),
        $Data.Date,
        $Data.Time,
        $Data.Timestamp,
        (Escape-CsvField $Data.MachineName),
        (Escape-CsvField $Data.TaskDescription),
        $Data.DayOfWeek,
        $Data.HourOfDay,
        $Data.DurationSeconds,
        $Data.FileSizeMB,
        $Data.ConvertedAt
    ) -join ","

    Add-Content -Path $Path -Value $row -Encoding UTF8
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Log "=========================================="
Write-Log "L7S Workflow Capture - Video Conversion"
Write-Log "=========================================="
Write-Log "Source:    $SourceShare"
Write-Log "Output:   $OutputRoot"
Write-Log "CSV:      $CsvPath"
Write-Log "Quality:  CRF $CrfQuality / Preset $Preset"
if ($DryRun) { Write-Log "MODE:     DRY RUN - no files will be converted" "WARN" }
if ($SingleUser) { Write-Log "Filter:   User = $SingleUser" }
Write-Log "=========================================="

# --- Pre-flight checks ---

# Find ffmpeg
$ffmpegExe = Find-Ffmpeg -ExplicitPath $FfmpegPath
if (-not $ffmpegExe) {
    Write-Log "ERROR: ffmpeg not found. Install via: choco install ffmpeg" "ERROR"
    Write-Log "  Or specify path: -FfmpegPath 'C:\path\to\ffmpeg.exe'"
    exit 1
}

# Find ffprobe (should be alongside ffmpeg)
$ffmpegDir = Split-Path $ffmpegExe -Parent
$ffprobeExe = Find-Ffprobe -FfmpegDir $ffmpegDir
if (-not $ffprobeExe) {
    Write-Log "ERROR: ffprobe not found (should be installed with ffmpeg)" "ERROR"
    exit 1
}

# Verify ffmpeg works
try {
    $versionOutput = & $ffmpegExe -version 2>&1 | Select-Object -First 1
    Write-Log "ffmpeg:   $versionOutput"
} catch {
    Write-Log "ERROR: ffmpeg is not functional: $_" "ERROR"
    exit 1
}

# Verify source share is accessible
if (-not (Test-Path $SourceShare)) {
    Write-Log "ERROR: Source share not accessible: $SourceShare" "ERROR"
    exit 2
}

# Create output directory
if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    Write-Log "Created output directory: $OutputRoot"
}

# --- Discover .webm files ---

Write-Log "Scanning for .webm files..."

$searchPath = $SourceShare
if ($SingleUser) {
    $searchPath = Join-Path $SourceShare $SingleUser
    if (-not (Test-Path $searchPath)) {
        Write-Log "ERROR: User folder not found: $searchPath" "ERROR"
        exit 3
    }
}

# Get all user folders (exclude _outputs and other _ prefixed system folders)
$webmFiles = @()
$userFolders = Get-ChildItem $searchPath -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike "_*" }

if ($SingleUser) {
    # When filtering to a single user, search directly
    $webmFiles = Get-ChildItem $searchPath -Filter "*.webm" -File -ErrorAction SilentlyContinue
    # Attach username info
    $webmFiles = $webmFiles | ForEach-Object {
        $_ | Add-Member -NotePropertyName "ParentUsername" -NotePropertyValue $SingleUser -PassThru
    }
} else {
    foreach ($folder in $userFolders) {
        $files = Get-ChildItem $folder.FullName -Filter "*.webm" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $f | Add-Member -NotePropertyName "ParentUsername" -NotePropertyValue $folder.Name -PassThru
            $webmFiles += $f
        }
    }
}

if ($webmFiles.Count -eq 0) {
    Write-Log "No .webm files found under: $searchPath"
    Write-Log "=========================================="
    exit 0
}

Write-Log "Found $($webmFiles.Count) .webm file(s) across $(if ($SingleUser) { '1' } else { $userFolders.Count }) user folder(s)"

# --- Load existing CSV to skip already-processed files ---

Initialize-CsvFile -Path $CsvPath
$existingEntries = Get-ExistingCsvEntries -Path $CsvPath
Write-Log "Previously processed: $($existingEntries.Count) file(s)"

# --- Process each file ---

$stats = @{
    Total     = $webmFiles.Count
    Converted = 0
    Skipped   = 0
    Failed    = 0
    ParseErr  = 0
}

foreach ($webm in $webmFiles) {
    $sourcePath = $webm.FullName
    $username = $webm.ParentUsername
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($webm.Name)

    # Output MP4 name: {username}_{original_basename}.mp4
    $mp4Name = "${username}_${baseName}.mp4"
    $mp4Path = Join-Path $OutputRoot $mp4Name

    # --- Skip if already processed ---
    if ($existingEntries.ContainsKey($sourcePath)) {
        if (Test-Path $mp4Path) {
            $mp4Size = (Get-Item $mp4Path).Length
            if ($mp4Size -gt 0) {
                $stats.Skipped++
                continue
            }
        }
    }

    # Also skip if MP4 exists and is non-zero (CSV entry may have been lost)
    if ((Test-Path $mp4Path) -and ((Get-Item $mp4Path).Length -gt 0)) {
        $stats.Skipped++
        continue
    }

    # --- Parse filename ---
    $parsed = Parse-WorkflowFilename -FileName $webm.Name -Username $username
    if (-not $parsed.ParsedOk) {
        $stats.ParseErr++
        continue
    }

    # --- Log what we're doing ---
    $fileSizeMB = [math]::Round($webm.Length / 1MB, 2)
    Write-Log "Processing: $($webm.Name) ($fileSizeMB MB) [user: $username]"

    if ($DryRun) {
        Write-Log "  DRY RUN: Would convert to $mp4Name"
        $stats.Converted++
        continue
    }

    # --- Get duration via ffprobe ---
    $duration = Get-VideoDuration -FilePath $sourcePath -FfprobePath $ffprobeExe

    # --- Convert ---
    $success = Convert-WebmToMp4 -InputPath $sourcePath -OutputPath $mp4Path `
                                  -FfmpegExe $ffmpegExe -Crf $CrfQuality -PresetName $Preset

    if ($success) {
        $mp4SizeMB = [math]::Round((Get-Item $mp4Path).Length / 1MB, 2)
        Write-Log "  Converted: $mp4Name ($mp4SizeMB MB)"

        # Append to CSV
        $csvData = @{
            SourcePath      = $sourcePath
            Mp4Path         = $mp4Path
            Username        = $username
            Date            = $parsed.Date
            Time            = $parsed.Time
            Timestamp       = $parsed.Timestamp
            MachineName     = $parsed.MachineName
            TaskDescription = $parsed.TaskDescription
            DayOfWeek       = $parsed.DayOfWeek
            HourOfDay       = $parsed.HourOfDay
            DurationSeconds = $duration
            FileSizeMB      = $fileSizeMB
            ConvertedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        }
        Append-CsvRow -Path $CsvPath -Data $csvData

        $stats.Converted++
    } else {
        $stats.Failed++
    }
}

# --- Summary ---

Write-Log "=========================================="
Write-Log "Conversion Complete"
Write-Log "=========================================="
Write-Log "Total .webm files:   $($stats.Total)"
Write-Log "Converted:           $($stats.Converted)"
Write-Log "Skipped (existing):  $($stats.Skipped)"
Write-Log "Failed:              $($stats.Failed)"
Write-Log "Parse errors:        $($stats.ParseErr)"
Write-Log "CSV:                 $CsvPath"
Write-Log "=========================================="

if ($stats.Failed -gt 0) {
    exit 4
}

exit 0
