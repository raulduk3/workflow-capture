# =============================================================================
# L7S Workflow Capture - Silent Installation Script for Ninja RMM
# =============================================================================
# This script downloads and installs the Workflow Capture application silently
# on Windows 11 Pro client machines.
#
# Designed to be deployed via Ninja RMM for mass deployment
#
# Features:
#   - Checks if already installed (skips download if so)
#   - Kills all running instances before install/restart
#   - Always enables auto-start at Windows login
#   - Starts the application after installation
#   - Provides detailed NinjaRMM summary output
#
# Usage:
#   .\Install-WorkflowCapture.ps1                                    # Download from GitHub
#   .\Install-WorkflowCapture.ps1 -InstallerSource "\\server\share"  # Use network share
#   .\Install-WorkflowCapture.ps1 -Force                             # Force reinstall
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
    [string]$InstallerFileName = "L7S-Workflow-Capture-1.0.9-x64.exe",
    
    [Parameter(Mandatory=$false)]    [switch]$AllUsers = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force = $false
)

# =============================================================================
# Configuration
# =============================================================================

$AppName = "L7S Workflow Capture"
$AppPublisher = "Layer 7 Systems"
$ReleaseVersion = "v1.0.9"
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

function Initialize-SessionsDirectory {
    # Create the sessions directory with appropriate ACL permissions
    # This allows all users to write recording files to a shared location
    # Flat structure: all .webm files directly in Sessions folder
    
    $captureDir = "C:\temp\L7SWorkflowCapture"
    $sessionsDir = "$captureDir\Sessions"
    
    Write-Log "Initializing sessions directory: $captureDir"
    
    try {
        # Create directory structure if it doesn't exist
        if (-not (Test-Path $sessionsDir)) {
            New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null
            Write-Log "Created sessions directory: $sessionsDir"
        }
        
        # Set ACL to allow all users to write
        $acl = Get-Acl $captureDir
        $usersRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Users",
            "Modify",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.SetAccessRule($usersRule)
        Set-Acl $captureDir $acl
        
        Write-Log "Set permissions for all users on: $captureDir" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Failed to initialize sessions directory: $_" -Level "ERROR"
        return $false
    }
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

function Set-DesktopShortcut {
    param([string]$ExePath)
    
    Write-Log "Creating desktop shortcut..."
    
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktopPath "RECORD.lnk"
    
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $ExePath
        $shortcut.WorkingDirectory = Split-Path $ExePath
        $shortcut.Description = "L7S Workflow Capture - Click to Record"
        $shortcut.Save()
        
        Write-Log "Desktop shortcut created: $shortcutPath" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Failed to create desktop shortcut: $_" -Level "WARN"
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

function Uninstall-OldInstallations {
    Write-Log "Checking for old installations to remove..."
    
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    
    $uninstalledCount = 0
    
    foreach ($regPath in $uninstallPaths) {
        if (Test-Path $regPath) {
            $apps = Get-ChildItem $regPath -ErrorAction SilentlyContinue
            foreach ($app in $apps) {
                $displayName = (Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).DisplayName
                $uninstallString = (Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).UninstallString
                
                if ($displayName -like "*Workflow Capture*" -or $displayName -like "*L7S*Workflow*") {
                    Write-Log "Found old installation: $displayName"
                    
                    if ($uninstallString) {
                        try {
                            # Handle NSIS uninstaller (add /S for silent)
                            if ($uninstallString -match '"([^"]+)"') {
                                $uninstallerPath = $matches[1]
                            } else {
                                $uninstallerPath = $uninstallString.Split(' ')[0]
                            }
                            
                            if (Test-Path $uninstallerPath) {
                                Write-Log "Running uninstaller: $uninstallerPath /S"
                                $process = Start-Process -FilePath $uninstallerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
                                if ($process.ExitCode -eq 0) {
                                    Write-Log "Successfully uninstalled: $displayName" -Level "SUCCESS"
                                    $uninstalledCount++
                                } else {
                                    Write-Log "Uninstaller exited with code: $($process.ExitCode)" -Level "WARN"
                                }
                            }
                        } catch {
                            Write-Log "Failed to run uninstaller for ${displayName}: $_" -Level "WARN"
                        }
                    }
                }
            }
        }
    }
    
    # Also remove old installation directories manually
    $oldInstallDirs = @(
        "$env:LOCALAPPDATA\Programs\l7s-workflow-capture",
        "$env:LOCALAPPDATA\Programs\workflow-capture",
        "${env:ProgramFiles}\Workflow Capture",
        "${env:ProgramFiles(x86)}\Workflow Capture",
        "${env:ProgramFiles}\L7S Workflow Capture",
        "${env:ProgramFiles(x86)}\L7S Workflow Capture"
    )
    
    foreach ($dir in $oldInstallDirs) {
        if (Test-Path $dir) {
            try {
                # Don't remove if this is where we're installing to
                if ($dir -ne $InstallPath) {
                    Write-Log "Removing old installation directory: $dir"
                    Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed directory: $dir" -Level "SUCCESS"
                }
            } catch {
                Write-Log "Failed to remove directory ${dir}: $_" -Level "WARN"
            }
        }
    }
    
    # Remove old desktop shortcuts
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $oldShortcuts = @(
        (Join-Path $desktopPath "Workflow Capture.lnk"),
        (Join-Path $desktopPath "L7S Workflow Capture.lnk")
    )
    
    foreach ($shortcut in $oldShortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "Removed old shortcut: $shortcut"
        }
    }
    
    # Remove old auto-start entries
    Remove-AutoStart
    
    if ($uninstalledCount -gt 0) {
        Write-Log "Uninstalled $uninstalledCount old installation(s)" -Level "SUCCESS"
        # Wait for uninstallation to complete
        Start-Sleep -Seconds 3
    } else {
        Write-Log "No old installations found to remove"
    }
    
    return $uninstalledCount
}

function Test-AlreadyInstalled {
    # Check if the application is already installed
    $possiblePaths = @(
        "$InstallPath\Workflow Capture.exe",
        "${env:ProgramFiles}\Workflow Capture\Workflow Capture.exe",
        "${env:ProgramFiles(x86)}\Workflow Capture\Workflow Capture.exe"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

function Stop-RunningInstances {
    Write-Log "Checking for running instances of Workflow Capture..."
    
    $processes = Get-Process -Name "Workflow Capture" -ErrorAction SilentlyContinue
    
    if ($processes) {
        $count = ($processes | Measure-Object).Count
        Write-Log "Found $count running instance(s) - terminating..."
        
        $processes | ForEach-Object {
            try {
                $_ | Stop-Process -Force
                Write-Log "Terminated process ID: $($_.Id)"
            } catch {
                Write-Log "Failed to terminate process ID $($_.Id): $_" -Level "WARN"
            }
        }
        
        # Wait for processes to fully terminate
        Start-Sleep -Seconds 2
        Write-Log "All running instances terminated" -Level "SUCCESS"
        return $count
    } else {
        Write-Log "No running instances found"
        return 0
    }
}

function Start-Application {
    param([string]$ExePath)
    
    Write-Log "Starting $AppName..."
    
    # Check if already running - reuse existing instance instead of starting new one
    $existingProcess = Get-Process -Name "Workflow Capture" -ErrorAction SilentlyContinue
    if ($existingProcess) {
        $processCount = ($existingProcess | Measure-Object).Count
        if ($processCount -eq 1) {
            Write-Log "$AppName is already running (PID: $($existingProcess.Id)) - reusing existing instance" -Level "SUCCESS"
            return $true
        } elseif ($processCount -gt 1) {
            # Multiple instances running - kill all but the first one
            Write-Log "Multiple instances detected ($processCount) - keeping only the first one" -Level "WARN"
            $existingProcess | Select-Object -Skip 1 | ForEach-Object {
                try {
                    $_ | Stop-Process -Force
                    Write-Log "Terminated duplicate instance (PID: $($_.Id))"
                } catch {
                    Write-Log "Failed to terminate duplicate instance: $_" -Level "WARN"
                }
            }
            $remainingProcess = Get-Process -Name "Workflow Capture" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($remainingProcess) {
                Write-Log "$AppName running with single instance (PID: $($remainingProcess.Id))" -Level "SUCCESS"
                return $true
            }
        }
    }
    
    # No instance running - start a new one
    try {
        Start-Process -FilePath $ExePath -WindowStyle Normal
        Start-Sleep -Seconds 2
        
        $process = Get-Process -Name "Workflow Capture" -ErrorAction SilentlyContinue
        if ($process) {
            Write-Log "$AppName started successfully (PID: $($process.Id))" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Application started but process not detected" -Level "WARN"
            return $false
        }
    } catch {
        Write-Log "Failed to start application: $_" -Level "ERROR"
        return $false
    }
}

function Write-NinjaRMMMessage {
    param(
        [hashtable]$Result
    )
    
    # Generate a clear summary message for NinjaRMM console
    $message = @"
================================================================================
L7S WORKFLOW CAPTURE - DEPLOYMENT SUMMARY
================================================================================
Computer Name:      $($Result.ComputerName)
Timestamp:          $($Result.Timestamp)
Status:             $(if ($Result.Success) { "SUCCESS" } else { "FAILED" })
--------------------------------------------------------------------------------
ACTIONS PERFORMED:
  - Already Installed:    $(if ($Result.WasAlreadyInstalled) { "Yes (skipped download)" } else { "No (fresh install)" })
  - Instances Terminated: $($Result.InstancesTerminated)
  - Installation:         $(if ($Result.InstallationPerformed) { "Completed" } else { "Skipped (already installed)" })
  - Auto-Start:           Configured
  - Application Started:  $(if ($Result.ApplicationStarted) { "Yes" } else { "No" })
--------------------------------------------------------------------------------
INSTALLATION DETAILS:
  - Install Path:         $($Result.InstalledPath)
  - Sessions Directory:   C:\temp\L7SWorkflowCapture\Sessions
  - Log File:             $($Result.LogFile)
================================================================================
"@
    
    Write-Host $message
    Write-Log "NinjaRMM summary message generated"
    
    return $message
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

# Initialize result object for NinjaRMM
$result = @{
    Success = $false
    ComputerName = $env:COMPUTERNAME
    InstalledPath = $null
    WasAlreadyInstalled = $false
    InstallationPerformed = $false
    InstancesTerminated = 0
    ApplicationStarted = $false
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    LogFile = $LogPath
}

# Stop all running instances first
$result.InstancesTerminated = Stop-RunningInstances

# Uninstall any old installations
$uninstalledCount = Uninstall-OldInstallations
Write-Log "Removed $uninstalledCount old installation(s)"

# Check if already installed
$existingInstallPath = Test-AlreadyInstalled

if ($existingInstallPath -and -not $Force) {
    Write-Log "Application already installed at: $existingInstallPath" -Level "SUCCESS"
    Write-Log "Skipping download and installation (use -Force to reinstall)"
    $result.WasAlreadyInstalled = $true
    $result.InstalledPath = $existingInstallPath
    $installedPath = $existingInstallPath
} else {
    if ($existingInstallPath -and $Force) {
        Write-Log "Force reinstall requested - proceeding with installation"
    }
    
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
        $result.Success = $false
        Write-NinjaRMMMessage -Result $result
        exit 2
    }

    # Perform installation
    $installSuccess = Install-Application -InstallerPath $installerPath
    $result.InstallationPerformed = $true

    if (-not $installSuccess) {
        Remove-TempFiles
        $result.Success = $false
        Write-NinjaRMMMessage -Result $result
        exit 3
    }

    # Verify installation
    $installedPath = Test-Installation

    if (-not $installedPath) {
        Write-Log "Installation verification failed" -Level "ERROR"
        Remove-TempFiles
        $result.Success = $false
        Write-NinjaRMMMessage -Result $result
        exit 3
    }
    
    $result.InstalledPath = $installedPath
}

# Initialize sessions directory with proper permissions for all users
$sessionsInitialized = Initialize-SessionsDirectory
if (-not $sessionsInitialized) {
    Write-Log "Warning: Sessions directory initialization failed - users may need to run as admin once" -Level "WARN"
}

# Always configure auto-start (no flag condition)
Write-Log "Configuring auto-start (always enabled)..."
Set-AutoStart -ExePath $installedPath

# Create desktop RECORD shortcut
Write-Log "Creating desktop RECORD shortcut..."
Set-DesktopShortcut -ExePath $installedPath

# Cleanup temp files
Remove-TempFiles

# Start the application
$appStarted = Start-Application -ExePath $installedPath
$result.ApplicationStarted = $appStarted

# Mark as success
$result.Success = $true

# Generate NinjaRMM summary message
$ninjaMessage = Write-NinjaRMMMessage -Result $result

# Summary
Write-Log "=========================================="
Write-Log "Installation Complete" -Level "SUCCESS"
Write-Log "=========================================="
Write-Log "Application: $AppName"
Write-Log "Location: $installedPath"
Write-Log "Auto-Start: Always Enabled"
Write-Log "App Running: $(if ($appStarted) { 'Yes' } else { 'No' })"
Write-Log "Log File: $LogPath"
Write-Log "=========================================="

return $result
