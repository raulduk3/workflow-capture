# =============================================================================
# L7S Workflow Analysis - Scheduled Task Deployment
# =============================================================================
# Registers (or updates) a Windows Scheduled Task on the utility server to
# run the full analysis pipeline daily.
#
# What gets scheduled:
#   Run-WorkflowPipeline.ps1  (Stage 1: WebM→MP4, Stage 2: Gemini analysis)
#
# The task runs once a day at the configured time. On failure it retries up to
# 3 times with a 30-minute interval. It writes a transcript log for every run.
#
# Prerequisites:
#   - Run this script as Administrator on the utility server
#   - ffmpeg installed (choco install ffmpeg)
#   - Python 3.10+ with pipeline deps (pip install -r pipeline/requirements.txt)
#   - Gemini API key configured in pipeline/.env
#   - Network share \\bulley-fs1\workflow accessible to the RunAs account
#
# Usage:
#   .\Schedule-WorkflowPipeline.ps1                          # Install daily at 02:00
#   .\Schedule-WorkflowPipeline.ps1 -Time "04:00"            # Install daily at 04:00
#   .\Schedule-WorkflowPipeline.ps1 -RunAs "DOMAIN\svcacct"  # Run as service account
#   .\Schedule-WorkflowPipeline.ps1 -Uninstall               # Remove scheduled task
#   .\Schedule-WorkflowPipeline.ps1 -RunNow                  # Trigger immediately
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$Time = "02:00",

    [Parameter(Mandatory=$false)]
    [string]$RunAs = "",

    [Parameter(Mandatory=$false)]
    [switch]$Uninstall = $false,

    [Parameter(Mandatory=$false)]
    [switch]$RunNow = $false,

    [Parameter(Mandatory=$false)]
    [switch]$GenerateReport = $false,

    [Parameter(Mandatory=$false)]
    [switch]$Force = $false
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Configuration
# =============================================================================

$TaskName        = "L7S-WorkflowAnalysisPipeline"
$TaskDescription = "L7S Workflow Analysis - Daily pipeline: converts .webm recordings to .mp4 and runs Gemini Vision analysis to produce workflow insights."
$TaskFolder      = "\L7S\"

$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot        = Split-Path -Parent $ScriptDir
$PipelineRunner  = Join-Path $ScriptDir "Run-WorkflowPipeline.ps1"
$LogDir          = "C:\temp\WorkflowProcessing\logs"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

# =============================================================================
# Validation
# =============================================================================

function Test-Prerequisites {
    $ok = $true

    # Must be admin
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        Write-Log "ERROR: This script must be run as Administrator" "ERROR"
        $ok = $false
    }

    # Pipeline runner must exist
    if (-not (Test-Path $PipelineRunner)) {
        Write-Log "ERROR: Pipeline runner not found: $PipelineRunner" "ERROR"
        $ok = $false
    }

    # Python must be available
    $pythonExe = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonExe) {
        $pythonExe = Get-Command python3 -ErrorAction SilentlyContinue
    }
    if (-not $pythonExe) {
        Write-Log "WARNING: Python not found in PATH. Ensure it's available for the RunAs account." "WARN"
    }

    # ffmpeg must be available
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        $chocoPath = "C:\ProgramData\chocolatey\bin\ffmpeg.exe"
        if (-not (Test-Path $chocoPath)) {
            Write-Log "WARNING: ffmpeg not found. Install via: choco install ffmpeg" "WARN"
        }
    }

    # .env must exist for Gemini key
    $envFile = Join-Path $RepoRoot "pipeline\.env"
    if (-not (Test-Path $envFile)) {
        Write-Log "WARNING: pipeline\.env not found. Gemini analysis will fail without API key." "WARN"
    }

    return $ok
}

# =============================================================================
# Uninstall
# =============================================================================

if ($Uninstall) {
    Write-Log "Removing scheduled task: $TaskName"

    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Confirm:$false
        Write-Log "Scheduled task removed successfully"
    } else {
        Write-Log "Task not found — nothing to remove"
    }
    exit 0
}

# =============================================================================
# Run Now (trigger existing task)
# =============================================================================

if ($RunNow) {
    Write-Log "Triggering immediate run of: $TaskName"

    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Log "ERROR: Task not registered. Run this script without -RunNow first." "ERROR"
        exit 1
    }

    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder
    Write-Log "Task triggered. Check logs at: $LogDir"
    exit 0
}

# =============================================================================
# Register / Update Scheduled Task
# =============================================================================

if (-not (Test-Prerequisites)) {
    exit 1
}

# Check for existing task
$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    Write-Log "Task already exists. Use -Force to overwrite, or -Uninstall to remove first."
    Write-Log "  Current schedule: $($existing.Triggers | ForEach-Object { $_.StartBoundary })"
    exit 0
}

# Build the command that the task will execute
# The wrapper script uses PowerShell transcript logging for full audit trail
$reportFlag = if ($GenerateReport) { "-GenerateReport" } else { "" }

$wrapperCommand = @"
`$ErrorActionPreference = 'Continue'
`$logDir = '$LogDir'
if (-not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
`$logFile = Join-Path `$logDir "scheduled_`$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
`$lockFile = Join-Path `$logDir "pipeline.lock"

# --- Lock file: prevent overlapping runs ---
if (Test-Path `$lockFile) {
    `$lockContent = Get-Content `$lockFile -Raw -ErrorAction SilentlyContinue
    `$lockAge = (Get-Date) - (Get-Item `$lockFile).LastWriteTime
    if (`$lockAge.TotalHours -lt 6) {
        Add-Content -Path `$logFile -Value "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] SKIPPED: Pipeline already running (lock age: `$(`$lockAge.ToString('hh\:mm\:ss')))"
        exit 0
    }
    # Stale lock (>6h) — previous run probably crashed, proceeding
    Add-Content -Path `$logFile -Value "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: Clearing stale lock file (age: `$(`$lockAge.ToString('hh\:mm\:ss')))"
}

# Acquire lock
Set-Content -Path `$lockFile -Value "PID=`$PID started=`$(Get-Date -Format 'o')"

try {
    Start-Transcript -Path `$logFile -Append
    & '$PipelineRunner' $reportFlag
    `$exitCode = `$LASTEXITCODE
    Stop-Transcript
} catch {
    Add-Content -Path `$logFile -Value "FATAL: `$_"
    `$exitCode = 99
} finally {
    # Release lock
    Remove-Item -Path `$lockFile -Force -ErrorAction SilentlyContinue
}

# --- Write health marker for monitoring ---
`$healthFile = Join-Path `$logDir "last_run.json"
`$health = @{
    timestamp  = (Get-Date -Format 'o')
    exit_code  = `$exitCode
    log_file   = `$logFile
    success    = (`$exitCode -eq 0)
} | ConvertTo-Json
Set-Content -Path `$healthFile -Value `$health -Encoding UTF8

exit `$exitCode
"@

# Write the wrapper to a file so Task Scheduler can invoke it
$wrapperPath = Join-Path $ScriptDir "Run-WorkflowPipeline-Scheduled.ps1"
Set-Content -Path $wrapperPath -Value $wrapperCommand -Encoding UTF8
Write-Log "Created scheduled wrapper: $wrapperPath"

# --- Build Task Scheduler objects ---

# Action: run PowerShell with the wrapper script
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapperPath`"" `
    -WorkingDirectory $RepoRoot

# Trigger: daily at the specified time
$trigger = New-ScheduledTaskTrigger -Daily -At $Time

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 30) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -MultipleInstances IgnoreNew

# Principal (who the task runs as)
if ($RunAs) {
    Write-Log "Task will run as: $RunAs"
    Write-Log "You will be prompted for the password."
    $principal = New-ScheduledTaskPrincipal -UserId $RunAs -LogonType Password -RunLevel Highest
} else {
    # Default: run as current user, only when logged in
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Log "Task will run as: $currentUser (interactive)"
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
}

# Register
if ($existing) {
    Write-Log "Updating existing scheduled task..."
    Set-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskFolder `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal | Out-Null
} else {
    Write-Log "Registering new scheduled task..."
    Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskFolder `
        -Description $TaskDescription `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal | Out-Null
}

# =============================================================================
# Summary
# =============================================================================

Write-Log ""
Write-Log "=========================================="
Write-Log "Scheduled Task Configured"
Write-Log "=========================================="
Write-Log "Task:       $TaskFolder$TaskName"
Write-Log "Schedule:   Daily at $Time"
Write-Log "Runner:     $PipelineRunner"
Write-Log "Wrapper:    $wrapperPath"
Write-Log "Logs:       $LogDir"
Write-Log "Health:     $LogDir\last_run.json"
Write-Log ""
Write-Log "Features:"
Write-Log "  - Lock file prevents overlapping runs"
Write-Log "  - Stale locks auto-cleared after 6 hours"
Write-Log "  - Transcript logging for full audit trail"
Write-Log "  - Health marker (last_run.json) for monitoring"
Write-Log "  - Retries 3x with 30-min intervals on failure"
Write-Log "  - 4-hour execution time limit"
Write-Log ""
Write-Log "Management:"
Write-Log "  Trigger now:  .\Schedule-WorkflowPipeline.ps1 -RunNow"
Write-Log "  Update:       .\Schedule-WorkflowPipeline.ps1 -Force -Time `"03:00`""
Write-Log "  Remove:       .\Schedule-WorkflowPipeline.ps1 -Uninstall"
Write-Log "  View logs:    Get-ChildItem $LogDir\scheduled_*.log"
Write-Log "  Health check: Get-Content $LogDir\last_run.json"
Write-Log "=========================================="
