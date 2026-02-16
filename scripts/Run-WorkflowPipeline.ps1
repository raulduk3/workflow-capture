# =============================================================================
# Workflow Analysis - Full Pipeline Runner
# =============================================================================
# Wrapper script for Windows Task Scheduler or manual execution.
# Runs both stages of the pipeline in sequence:
#   1. PowerShell: Convert .webm → .mp4 + session CSV (ffmpeg)
#   2. Python: Extract frames → Gemini Vision → analysis CSV + patterns
#
# Prerequisites:
#   - ffmpeg installed via Chocolatey (choco install ffmpeg)
#   - Python 3.10+ with pipeline dependencies (pip install -r pipeline/requirements.txt)
#   - Gemini API key configured in pipeline/.env
#   - Source directory with workflow recordings accessible
#
# Usage:
#   .\Run-WorkflowPipeline.ps1                      # Full pipeline
#   .\Run-WorkflowPipeline.ps1 -SkipConversion       # Skip MP4 conversion
#   .\Run-WorkflowPipeline.ps1 -MetadataOnly         # Skip Gemini analysis
#   .\Run-WorkflowPipeline.ps1 -GenerateReport       # Include insights report
#   .\.\Run-WorkflowPipeline.ps1 -User "username"      # Single user
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [switch]$SkipConversion = $false,

    [Parameter(Mandatory=$false)]
    [switch]$MetadataOnly = $false,

    [Parameter(Mandatory=$false)]
    [switch]$GenerateReport = $true,

    [Parameter(Mandatory=$false)]
    [string]$User = "",

    [Parameter(Mandatory=$false)]
    [int]$Limit = 0,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,

    [Parameter(Mandatory=$false)]
    [int]$LogRetentionDays = 14
)

$ErrorActionPreference = "Continue"

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$PipelineDir = Join-Path $RepoRoot "pipeline"
$ConvertScript = Join-Path $ScriptDir "Convert-WorkflowSessions.ps1"
$PipelineScript = Join-Path $PipelineDir "run_pipeline.py"
$LogDir = "C:\temp\WorkflowProcessing\logs"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line

    # Also write to log file
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $logFile = Join-Path $LogDir "pipeline_$(Get-Date -Format 'yyyy-MM-dd').log"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# =============================================================================
# Main Execution
# =============================================================================

$startTime = Get-Date

Write-Log "=========================================="
Write-Log "L7S Workflow Analysis - Full Pipeline"
Write-Log "=========================================="
Write-Log "Repo:        $RepoRoot"
Write-Log "Pipeline:    $PipelineDir"
if ($SkipConversion) { Write-Log "Stage 1:     SKIPPED (--SkipConversion)" }
if ($MetadataOnly)   { Write-Log "Stage 2:     METADATA ONLY (no Gemini)" }
if ($DryRun)         { Write-Log "Mode:        DRY RUN" }
if ($User)           { Write-Log "Filter:      User = $User" }
if ($Limit -gt 0)    { Write-Log "Limit:       $Limit videos" }
Write-Log "=========================================="

$overallSuccess = $true

# =============================================================================
# Pre-flight: Validate source directory connectivity
# =============================================================================

$sourceShare = [Environment]::GetEnvironmentVariable("WORKFLOW_SOURCE_SHARE") ?? "\\\\SERVER\\SHARE\\workflow"
$shareRetries = 3
$shareAvailable = $false

for ($i = 0; $i -lt $shareRetries; $i++) {
    if (Test-Path $sourceShare) {
        $shareAvailable = $true
        Write-Log "Source directory accessible: $sourceShare"
        break
    }
    if ($i -lt ($shareRetries - 1)) {
        Write-Log "Network share not reachable, retrying in 5s... (attempt $($i+1)/$shareRetries)" "WARN"
        Start-Sleep -Seconds 5
    }
}

if (-not $shareAvailable) {
    Write-Log "ERROR: Network share unreachable after $shareRetries attempts: $sourceShare" "ERROR"
    Write-Log "Pipeline cannot proceed without source data. Exiting." "ERROR"
    exit 2
}

# =============================================================================
# Pre-flight: Rotate old log files
# =============================================================================

if ($LogRetentionDays -gt 0) {
    $logCutoff = (Get-Date).AddDays(-$LogRetentionDays)
    $oldLogs = Get-ChildItem $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $logCutoff }
    if ($oldLogs -and $oldLogs.Count -gt 0) {
        Write-Log "Cleaning up $($oldLogs.Count) log file(s) older than $LogRetentionDays days"
        $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Stage 1: WebM → MP4 Conversion
# =============================================================================

if (-not $SkipConversion) {
    Write-Log ""
    Write-Log "=== STAGE 1: Video Conversion (WebM → MP4) ==="

    if (-not (Test-Path $ConvertScript)) {
        Write-Log "ERROR: Conversion script not found: $ConvertScript" "ERROR"
        $overallSuccess = $false
    } else {
        $convertArgs = @{}
        if ($User) { $convertArgs["SingleUser"] = $User }
        if ($DryRun) { $convertArgs["DryRun"] = $true }

        try {
            & $ConvertScript @convertArgs
            $convertExit = $LASTEXITCODE

            if ($convertExit -eq 0) {
                Write-Log "Stage 1 completed successfully"
            } else {
                Write-Log "Stage 1 completed with warnings (exit code: $convertExit)" "WARN"
                if ($convertExit -ge 3) { $overallSuccess = $false }
            }
        } catch {
            Write-Log "Stage 1 FAILED: $_" "ERROR"
            $overallSuccess = $false
        }
    }
} else {
    Write-Log ""
    Write-Log "=== STAGE 1: SKIPPED ==="
}

# =============================================================================
# Stage 2: Analysis Pipeline (Python)
# =============================================================================

Write-Log ""
Write-Log "=== STAGE 2: Analysis Pipeline (Frames → Gemini → CSV) ==="

# Find Python
$pythonExe = $null
$pythonCandidates = @(
    "python",
    "python3",
    "C:\Python312\python.exe",
    "C:\Python311\python.exe",
    "C:\Python310\python.exe"
)

foreach ($candidate in $pythonCandidates) {
    $result = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($result) {
        $pythonExe = $result.Source
        break
    }
}

if (-not $pythonExe) {
    Write-Log "ERROR: Python not found. Install Python 3.10+ and add to PATH." "ERROR"
    $overallSuccess = $false
} elseif (-not (Test-Path $PipelineScript)) {
    Write-Log "ERROR: Pipeline script not found: $PipelineScript" "ERROR"
    $overallSuccess = $false
} else {
    Write-Log "Python: $pythonExe"

    # Build args
    $pyArgs = @($PipelineScript)
    if ($User) { $pyArgs += "--user"; $pyArgs += $User }
    if ($Limit -gt 0) { $pyArgs += "--limit"; $pyArgs += $Limit.ToString() }
    if ($DryRun) { $pyArgs += "--dry-run" }
    if ($MetadataOnly) { $pyArgs += "--metadata-only" }
    if ($GenerateReport) { $pyArgs += "--report" }

    try {
        # Run with working directory set to pipeline folder
        Push-Location $PipelineDir
        & $pythonExe @pyArgs
        $pyExit = $LASTEXITCODE
        Pop-Location

        if ($pyExit -eq 0) {
            Write-Log "Stage 2 completed successfully"
        } else {
            Write-Log "Stage 2 completed with errors (exit code: $pyExit)" "WARN"
            $overallSuccess = $false
        }
    } catch {
        Write-Log "Stage 2 FAILED: $_" "ERROR"
        Pop-Location -ErrorAction SilentlyContinue
        $overallSuccess = $false
    }
}

# =============================================================================
# Summary
# =============================================================================

$elapsed = (Get-Date) - $startTime

Write-Log ""
Write-Log "=========================================="
Write-Log "Pipeline Complete"
Write-Log "=========================================="
Write-Log "Elapsed:  $($elapsed.ToString('hh\:mm\:ss'))"
Write-Log "Status:   $(if ($overallSuccess) { 'SUCCESS' } else { 'COMPLETED WITH ERRORS' })"
Write-Log "=========================================="

# =============================================================================
# Write health marker for monitoring tools
# =============================================================================

$healthFile = Join-Path $LogDir "last_pipeline_run.json"
$health = @{
    timestamp      = (Get-Date -Format 'o')
    elapsed        = $elapsed.ToString('hh\:mm\:ss')
    success        = $overallSuccess
    skip_conversion = [bool]$SkipConversion
    metadata_only  = [bool]$MetadataOnly
    user_filter    = $User
    log_file       = (Join-Path $LogDir "pipeline_$(Get-Date -Format 'yyyy-MM-dd').log")
} | ConvertTo-Json

try {
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Set-Content -Path $healthFile -Value $health -Encoding UTF8
    Write-Log "Health marker written: $healthFile"
} catch {
    Write-Log "WARNING: Could not write health marker: $_" "WARN"
}

if ($overallSuccess) {
    exit 0
} else {
    exit 1
}
