# =============================================================================
# L7S Workflow Capture - Silent Installation Script for Ninja RMM
# =============================================================================
# This script downloads and installs the Workflow Capture application silently
# on Windows 11 Pro client machines.
#
# Designed to be deployed via Ninja RMM for mass deployment
#
# Usage:
#   .\Install-WorkflowCapture.ps1                                    # Download from GitHub
#   .\Install-WorkflowCapture.ps1 -InstallerSource "\\server\share"  # Use network share
#   .\Install-WorkflowCapture.ps1 -AutoStart                         # Enable auto-start
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Installer not found
#   3 - Installation failed
#   4 - Unsupported OS
# =============================================================================

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$false)]
    [string]$InstallerSource = "",
    
    [Parameter(Mandatory=$false)]
    [string]$InstallerUrl = "",
    
    [Parameter(Mandatory=$false)]
    [string]$InstallerFileName = "L7S-Workflow-Capture-1.0.7-x64.exe",
    
    [Parameter(Mandatory=$false)]
    [switch]$AutoStart = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$AllUsers = $false
)

# =============================================================================
# Configuration
# =============================================================================

$AppName = "L7S Workflow Capture"
$AppPublisher = "Layer 7 Systems"
$ReleaseVersion = "v1.0.7"
$GitHubRepo = "raulduk3/workflow-capture"
$GitHubReleaseUrl = "https://github.com/$GitHubRepo/releases/download/$ReleaseVersion/$InstallerFileName"
$InstallPath = "$env:LOCALAPPDATA\Programs\l7s-workflow-capture"
$LogPath = "$env:TEMP\L7S-WorkflowCapture-Install.log"
$TempInstallerPath = "$env:TEMP\L7S-Workflow-Capture-Setup.exe"

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
    
    # Write to console with color
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARN"    { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage }
    }
    
    # Append to log file
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
}


function Get-InstallerFromSource {
    param([string]$Source)
    
    Write-Log "Looking for installer in: $Source"
    
    if (-not (Test-Path $Source)) {
        Write-Log "Source path does not exist: $Source" -Level "ERROR"
        return $null
    }
    
    # Find the latest installer matching the pattern
    $installers = Get-ChildItem -Path $Source -Filter $InstallerFileName -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending
    
    if (-not $installers) {
        Write-Log "No installer found matching pattern: $InstallerFileName" -Level "ERROR"
        return $null
    }
    
    $latestInstaller = $installers[0]
    Write-Log "Found installer: $($latestInstaller.Name) ($('{0:N2}' -f ($latestInstaller.Length / 1MB)) MB)"
    
    # Copy to temp location
    Write-Log "Copying installer to temp location..."
    try {
        Copy-Item -Path $latestInstaller.FullName -Destination $TempInstallerPath -Force
        Write-Log "Installer copied successfully"
        return $TempInstallerPath
    } catch {
        Write-Log "Failed to copy installer: $_" -Level "ERROR"
        return $null
    }
}

function Get-InstallerFromUrl {
    param([string]$Url)
    
    Write-Log "Downloading installer from: $Url"
    
    try {
        # Configure TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        # Download with progress
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($Url, $TempInstallerPath)
        
        if (Test-Path $TempInstallerPath) {
            $fileSize = (Get-Item $TempInstallerPath).Length
            Write-Log "Downloaded successfully ($('{0:N2}' -f ($fileSize / 1MB)) MB)"
            return $TempInstallerPath
        }
    } catch {
        Write-Log "Failed to download installer: $_" -Level "ERROR"
    }
    
    return $null
}

function Get-InstallerFromGitHub {
    Write-Log "Downloading release $ReleaseVersion from GitHub: $GitHubRepo"
    
    try {
        # Configure TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        Write-Log "Download URL: $GitHubReleaseUrl"
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "L7S-Workflow-Capture-Installer")
        $webClient.DownloadFile($GitHubReleaseUrl, $TempInstallerPath)
        
        if (Test-Path $TempInstallerPath) {
            $downloadedSize = (Get-Item $TempInstallerPath).Length
            Write-Log "Downloaded successfully ($('{0:N2}' -f ($downloadedSize / 1MB)) MB)" -Level "SUCCESS"
            return $TempInstallerPath
        }
    } catch {
        Write-Log "Failed to download from GitHub: $_" -Level "ERROR"
    }
    
    return $null
}

function Install-Application {
    param([string]$InstallerPath)
    
    Write-Log "Starting silent installation..."
    
    # NSIS installer arguments for silent install
    # /S = Silent mode
    # /D = Installation directory (must be last parameter, no quotes)
    # /NCRC = Skip CRC check (optional, for faster install)
    $arguments = @("/S")
    
    if ($AllUsers) {
        # Install for all users (requires admin)
        $arguments += "/ALLUSERS"
    }
    
    Write-Log "Installer arguments: $($arguments -join ' ')"
    
    try {
        $process = Start-Process -FilePath $InstallerPath `
                                 -ArgumentList $arguments `
                                 -Wait `
                                 -PassThru `
                                 -NoNewWindow
        
        $exitCode = $process.ExitCode
        
        if ($exitCode -eq 0) {
            Write-Log "Installation completed successfully" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Installation failed with exit code: $exitCode" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "Installation process failed: $_" -Level "ERROR"
        return $false
    }
}

function Set-AutoStart {
    param([string]$ExePath)
    
    Write-Log "Configuring auto-start..."
    
    $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $shortcutPath = Join-Path $startupPath "Workflow Capture.lnk"
    
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $ExePath
        $shortcut.WorkingDirectory = Split-Path $ExePath
        $shortcut.Description = "L7S Workflow Capture - Screen Recording Tool"
        $shortcut.Save()
        
        Write-Log "Auto-start shortcut created: $shortcutPath" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Failed to create auto-start shortcut: $_" -Level "WARN"
        return $false
    }
}

function Remove-AutoStart {
    $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $shortcutPath = Join-Path $startupPath "Workflow Capture.lnk"
    
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
        Write-Log "Removed existing auto-start shortcut"
    }
}

function Test-Installation {
    # Wait a moment for installation to finalize
    Start-Sleep -Seconds 2
    
    # Check for the installed executable (actual name is "Workflow Capture.exe")
    $possiblePaths = @(
        "$InstallPath\Workflow Capture.exe",
        "${env:ProgramFiles}\Workflow Capture\Workflow Capture.exe",
        "${env:ProgramFiles(x86)}\Workflow Capture\Workflow Capture.exe"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $fileInfo = Get-Item $path
            Write-Log "Verified installation at: $path"
            Write-Log "  Version: $($fileInfo.VersionInfo.FileVersion)"
            return $path
        }
    }
    
    Write-Log "Could not verify installation - executable not found" -Level "WARN"
    return $null
}

function Remove-TempFiles {
    if (Test-Path $TempInstallerPath) {
        Remove-Item $TempInstallerPath -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up temporary installer"
    }
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Log "=========================================="
Write-Log "$AppName - Silent Installation"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $env:USERNAME"
Write-Log "=========================================="

# Get installer - Priority: URL > Source > GitHub
$installerPath = $null

if ($InstallerUrl) {
    # Explicit URL provided
    Write-Log "Using provided URL for installer"
    $installerPath = Get-InstallerFromUrl -Url $InstallerUrl
} elseif ($InstallerSource) {
    # Network/local source provided
    Write-Log "Using provided source path for installer"
    $installerPath = Get-InstallerFromSource -Source $InstallerSource
} else {
    # Default: Download specific release from GitHub
    Write-Log "No installer source specified - downloading $ReleaseVersion from GitHub"
    $installerPath = Get-InstallerFromGitHub
}

if (-not $installerPath) {
    Write-Log "Failed to obtain installer" -Level "ERROR"
    exit 2
}

# Perform installation
$installSuccess = Install-Application -InstallerPath $installerPath

if (-not $installSuccess) {
    Remove-TempFiles
    exit 3
}

# Verify installation
$installedPath = Test-Installation

if (-not $installedPath) {
    Write-Log "Installation verification failed" -Level "ERROR"
    Remove-TempFiles
    exit 3
}

# Configure auto-start if requested
if ($AutoStart) {
    Set-AutoStart -ExePath $installedPath
} else {
    # Ensure no stale auto-start entries
    Remove-AutoStart
}

# Cleanup
Remove-TempFiles

# Summary
Write-Log "=========================================="
Write-Log "Installation Complete" -Level "SUCCESS"
Write-Log "=========================================="
Write-Log "Application: $AppName"
Write-Log "Location: $installedPath"
Write-Log "Auto-Start: $(if ($AutoStart) { 'Enabled' } else { 'Disabled' })"
Write-Log "Log File: $LogPath"
Write-Log "=========================================="

# Return success object for Ninja RMM
$result = @{
    Success = $true
    ComputerName = $env:COMPUTERNAME
    InstalledPath = $installedPath
    AutoStart = $AutoStart.IsPresent
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

return $result
