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

    # Probe duration from the converted MP4 — always has proper container metadata
    try {
        $output = & $FfprobePath -v error -show_entries format=duration `
                    -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null
        $durationStr = ($output | Out-String).Trim()
        if ($durationStr -and $durationStr -ne "N/A" -and $durationStr -match '^\d') {
            return [math]::Round([double]$durationStr, 1)
        }
    } catch {
        Write-Log "WARNING: ffprobe failed for $(Split-Path $FilePath -Leaf): $_" "WARN"
    }

    return -1
}

# =============================================================================
# Video Validation
# =============================================================================

function Test-VideoValidity {
    param(
        [string]$FilePath,
        [string]$FfprobePath
    )

    <#
    Validates that a video file:
    1. Contains video streams
    2. Has a reasonable duration
    3. Is above minimum file size
    Returns: $true if valid, $false otherwise
    #>

    # Check file size first (fast)
    $fileSizeBytes = (Get-Item $FilePath).Length
    $fileSizeMB = [math]::Round($fileSizeBytes / 1MB, 2)

    # Minimum 50 KB — anything smaller is likely corrupted/empty
    if ($fileSizeBytes -lt 50KB) {
        Write-Log "SKIP: File too small ($fileSizeMB MB, < 50 KB): $(Split-Path $FilePath -Leaf)" "WARN"
        return $false
    }

    # Probe for duration and stream info
    try {
        $output = & $FfprobePath -v error `
                    -select_streams v:0 `
                    -show_entries stream=codec_type,duration `
                    -show_entries format=duration `
                    -of default=noprint_wrappers=1 `
                    $FilePath 2>$null

        $outputStr = $output | Out-String

        # Check for video stream
        if ($outputStr -notmatch "codec_type=video") {
            Write-Log "SKIP: No video stream found: $(Split-Path $FilePath -Leaf)" "WARN"
            return $false
        }

        # Extract duration
        $durationMatch = $outputStr -match "duration=([0-9.]+)"
        if ($durationMatch) {
            $duration = [double]$matches[1]
        } else {
            Write-Log "SKIP: Could not determine duration: $(Split-Path $FilePath -Leaf)" "WARN"
            return $false
        }

        # Minimum 5 seconds of actual content
        if ($duration -lt 5) {
            Write-Log "SKIP: Duration too short ($([math]::Round($duration, 1))s, < 5s): $(Split-Path $FilePath -Leaf)" "WARN"
            return $false
        }

        # Maximum reasonable duration (12 hours)
        if ($duration -gt 43200) {
            Write-Log "SKIP: Duration suspiciously long ($([math]::Round($duration / 60, 1)) min): $(Split-Path $FilePath -Leaf)" "WARN"
            return $false
        }

        return $true

    } catch {
        Write-Log "SKIP: ffprobe validation failed: $(Split-Path $FilePath -Leaf) - $_" "WARN"
        return $false
    }
}

function Test-VideoHasFrames {
    param(
        [string]$FilePath,
        [string]$FfmpegExe
    )

    <#
    Quick check: attempt to extract the first frame.
    If this fails, the video is likely corrupted and has no decodable content.
    #>

    $tempFrame = "$env:TEMP\temp_frame_$(Get-Random).jpg"

    try {
        $process = Start-Process -FilePath $FfmpegExe `
                    -ArgumentList @(
                        "-i", $FilePath,
                        "-vf", "select=eq(n\,0)",
                        "-q:v", "2",
                        "-frames:v", "1",
                        "-y",
                        "-loglevel", "error",
                        $tempFrame
                    ) `
                    -Wait -PassThru -NoNewWindow -WindowStyle Hidden

        if ($process.ExitCode -eq 0 -and (Test-Path $tempFrame)) {
            $frameSize = (Get-Item $tempFrame).Length
            Remove-Item $tempFrame -Force -ErrorAction SilentlyContinue

            if ($frameSize -gt 1000) {  # Frame should be at least 1KB
                return $true
            }
        }

        Remove-Item $tempFrame -Force -ErrorAction SilentlyContinue
        return $false

    } catch {
        Remove-Item $tempFrame -Force -ErrorAction SilentlyContinue
        return $false
    }
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

    # pad to even dimensions — libx264 requires width and height divisible by 2
    # Multi-monitor captures can produce odd dimensions (e.g., 5760x1089)
    $ffmpegArgs = @(
        "-i", $InputPath,
        "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
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
Write-Log "Filtering: Videos < 50KB and duration < 5s will be skipped"
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
    Total       = $webmFiles.Count
    Converted   = 0
    Skipped     = 0
    Failed      = 0
    ParseErr    = 0
    InvalidVid  = 0
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

    # --- Validate video before attempting conversion ---
    if (-not (Test-VideoValidity -FilePath $sourcePath -FfprobePath $ffprobeExe)) {
        $stats.InvalidVid++
        continue
    }

    # --- Quick frame check to ensure video isn't corrupted ---
    if (-not (Test-VideoHasFrames -FilePath $sourcePath -FfmpegExe $ffmpegExe)) {
        Write-Log "SKIP: No decodable frames found: $(Split-Path $sourcePath -Leaf)" "WARN"
        $stats.InvalidVid++
        continue
    }

    if ($DryRun) {
        Write-Log "  DRY RUN: Would convert to $mp4Name"
        $stats.Converted++
        continue
    }

    # --- Convert ---
    $success = Convert-WebmToMp4 -InputPath $sourcePath -OutputPath $mp4Path `
                                  -FfmpegExe $ffmpegExe -Crf $CrfQuality -PresetName $Preset

    if ($success) {
        $mp4SizeMB = [math]::Round((Get-Item $mp4Path).Length / 1MB, 2)

        # Get duration from converted MP4 (WebM often lacks duration metadata)
        $duration = Get-VideoDuration -FilePath $mp4Path -FfprobePath $ffprobeExe

        Write-Log "  Converted: $mp4Name ($mp4SizeMB MB, ${duration}s)"

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
Write-Log "Total .webm files:    $($stats.Total)"
Write-Log "Converted:            $($stats.Converted)"
Write-Log "Skipped (existing):   $($stats.Skipped)"
Write-Log "Invalid/Corrupted:    $($stats.InvalidVid)"
Write-Log "Failed:               $($stats.Failed)"
Write-Log "Parse errors:         $($stats.ParseErr)"
Write-Log "CSV:                  $CsvPath"
Write-Log "=========================================="

if ($stats.Failed -gt 0 -or $stats.InvalidVid -gt 0) {
    Write-Log "Note: Invalid/corrupted videos were skipped and not added to CSV" "INFO"
}

if ($stats.Failed -gt 0) {
    exit 4
}

exit 0
