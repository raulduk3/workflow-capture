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
#   - Deploys config.json for remote configuration (no reinstall needed)
#   - Provides detailed NinjaRMM summary output
#
# Usage:
#   .\Install-WorkflowCapture.ps1                                    # Download from GitHub
#   .\Install-WorkflowCapture.ps1 -InstallerSource "\\server\share"  # Use network share
#   .\Install-WorkflowCapture.ps1 -Force                             # Force reinstall
#   .\Install-WorkflowCapture.ps1 -MaxRecordingMinutes 10            # Set 10 min limit
#
# Configuration Options:
#   -MaxRecordingMinutes <int>  : Max recording duration (default: 10)
#   -VideoBitrateMbps <int>     : Video quality bitrate (default: 5)
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
    [string]$InstallerFileName = "L7S-Workflow-Capture-1.1.4-x64.exe",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force = $true,
    
    # Configuration options (deployed to config.json)
    [Parameter(Mandatory=$false)]
    [int]$MaxRecordingMinutes = 1,
        
    [Parameter(Mandatory=$false)]
    [int]$VideoBitrateMbps = 5
)

# =============================================================================
# Configuration
# =============================================================================

$AppName = "L7S Workflow Capture"
$AppPublisher = "Layer 7 Systems"
$ReleaseVersion = "v1.1.4"
$GitHubRepo = "raulduk3/workflow-capture"
$GitHubReleaseUrl = "https://github.com/$GitHubRepo/releases/download/$ReleaseVersion/$InstallerFileName"
$InstallPath = "${env:ProgramFiles}\Workflow Capture"

# Use C:\temp instead of %TEMP% to avoid issues when running as SYSTEM
# SYSTEM's temp folder (C:\WINDOWS\TEMP) causes NSIS installers to crash
$TempDir = "C:\temp\L7SWorkflowCapture"
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}
$LogPath = "$TempDir\L7S-WorkflowCapture-Install.log"
$TempInstallerPath = "$TempDir\L7S-Workflow-Capture-Setup.exe"

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

function Get-ExePath {
    # Helper function to search for Workflow Capture.exe
    # Returns the full path if found, $null otherwise
    param([string]$SearchPath, [bool]$Recursive = $false)
    
    if (-not (Test-Path $SearchPath)) {
        return $null
    }
    
    if ($Recursive) {
        $foundExe = Get-ChildItem -Path $SearchPath -Filter "Workflow Capture.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($foundExe) {
            return $foundExe.FullName
        }
    } else {
        $exePath = Join-Path $SearchPath "Workflow Capture.exe"
        if (Test-Path $exePath) {
            return $exePath
        }
    }
    
    return $null
}

function Get-ProcessCount {
    # Helper function to safely get process count
    param([string]$ProcessName)
    
    $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($processes) {
        return ($processes | Measure-Object).Count
    }
    return 0
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

function Deploy-Configuration {
    # Deploy config.json with recording settings
    # This allows changing settings across clients without reinstalling
    param(
        [int]$MaxMinutes = 5,
        [int]$BitrateMbps = 5
    )
    
    $configDir = "C:\temp\L7SWorkflowCapture"
    $configPath = "$configDir\config.json"
    
    Write-Log "Deploying configuration to: $configPath"
    
    try {
        # Ensure directory exists
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        
        # Build config object
        $config = @{
            maxRecordingMinutes = $MaxMinutes
            videoBitrateMbps = $BitrateMbps
        }
        
        # Write config file (without BOM for proper JSON parsing)
        $configJson = $config | ConvertTo-Json -Depth 2
        # Use .NET method to write UTF-8 without BOM (PowerShell's -Encoding UTF8 adds BOM)
        [System.IO.File]::WriteAllText($configPath, $configJson)
        
        Write-Log "Configuration deployed:" -Level "SUCCESS"
        Write-Log "  - Max Recording: $MaxMinutes minutes"
        Write-Log "  - Video Bitrate: $BitrateMbps Mbps"
        return $true
    } catch {
        Write-Log "Failed to deploy configuration: $_" -Level "ERROR"
        return $false
    }
}

function Get-Installer {
    # Get installer from URL, Source, or GitHub (in priority order)
    param(
        [string]$Url = "",
        [string]$Source = "",
        [string]$FileName = $InstallerFileName
    )
    
    if ($Url) {
        Write-Log "Downloading installer from provided URL"
        return Get-InstallerFromUrl -Url $Url
    }
    
    if ($Source) {
        Write-Log "Getting installer from provided source path"
        return Get-InstallerFromSource -Source $Source -FileName $FileName
    }
    
    Write-Log "Downloading release $ReleaseVersion from GitHub: $GitHubRepo"
    return Get-InstallerFromGitHub
}

function Get-InstallerFromUrl {
    param([string]$Url)
    
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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

function Get-InstallerFromSource {
    param([string]$Source, [string]$FileName)
    
    Write-Log "Looking for installer in: $Source"
    
    if (-not (Test-Path $Source)) {
        Write-Log "Source path does not exist: $Source" -Level "ERROR"
        return $null
    }
    
    $installers = Get-ChildItem -Path $Source -Filter $FileName -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending
    
    if (-not $installers) {
        Write-Log "No installer found matching pattern: $FileName" -Level "ERROR"
        return $null
    }
    
    $latestInstaller = $installers[0]
    Write-Log "Found installer: $($latestInstaller.Name) ($('{0:N2}' -f ($latestInstaller.Length / 1MB)) MB)"
    
    try {
        Copy-Item -Path $latestInstaller.FullName -Destination $TempInstallerPath -Force
        Write-Log "Installer copied successfully"
        return $TempInstallerPath
    } catch {
        Write-Log "Failed to copy installer: $_" -Level "ERROR"
        return $null
    }
}

function Get-InstallerFromGitHub {
    try {
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
    
    # /S = Silent mode
    # /D = Installation directory (must be last parameter, no quotes around path)
    # Note: /D must be the LAST parameter and path must NOT be quoted
    $targetDir = "C:\Program Files\Workflow Capture"
    
    # Build argument list as array for proper handling of spaces
    # Using ArgumentList as array avoids quoting issues
    $arguments = @("/S", "/D=$targetDir")
    
    Write-Log "Installer path: $InstallerPath"
    Write-Log "Installer arguments: $($arguments -join ' ')"
    Write-Log "Target directory: $targetDir"
    
    try {
        # Use Start-Process with -ArgumentList as array
        $process = Start-Process -FilePath $InstallerPath `
                                    -ArgumentList $arguments `
                                    -Wait `
                                    -PassThru `
                                    -NoNewWindow
        
        $exitCode = $process.ExitCode
        
        if ($exitCode -eq 0) {
            Write-Log "Installation completed (exit code 0)" -Level "SUCCESS"
            
            # Give the installer time to finalize file operations
            Start-Sleep -Seconds 5
            
            # Log what exists at target directory
            if (Test-Path $targetDir) {
                Write-Log "Target directory exists: $targetDir" -Level "SUCCESS"
                $contents = Get-ChildItem -Path $targetDir -ErrorAction SilentlyContinue | Select-Object -First 10
                foreach ($item in $contents) {
                    Write-Log "  - $($item.Name)"
                }
            } else {
                Write-Log "Target directory does NOT exist after install: $targetDir" -Level "WARN"
                # Check if install went to a different location
                $programFilesContents = Get-ChildItem "C:\Program Files" -Directory -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -like "*Workflow*" -or $_.Name -like "*L7S*" -or $_.Name -like "*Capture*" }
                foreach ($dir in $programFilesContents) {
                    Write-Log "  Found related dir: $($dir.FullName)" -Level "INFO"
                }
            }
            
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
    
    Write-Log "Configuring auto-start for all users (machine-wide only)..."
    
    $successCount = 0
    
    # Method 1: Use Common Startup folder (applies to ALL users)
    # This is a machine-wide location that works reliably when running as SYSTEM
    $commonStartup = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    if (-not (Test-Path $commonStartup)) {
        try {
            New-Item -ItemType Directory -Path $commonStartup -Force | Out-Null
        } catch {
            Write-Log "Failed to create common startup folder: $_" -Level "WARN"
        }
    }
    
    $commonShortcutPath = Join-Path $commonStartup "Workflow Capture.lnk"
    try {
        # Remove existing shortcut first to avoid stale references
        if (Test-Path $commonShortcutPath) {
            Remove-Item $commonShortcutPath -Force -ErrorAction SilentlyContinue
        }
        
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($commonShortcutPath)
        $shortcut.TargetPath = $ExePath
        $shortcut.WorkingDirectory = Split-Path $ExePath
        $shortcut.Description = "L7S Workflow Capture - Screen Recording Tool"
        $shortcut.IconLocation = "$ExePath,0"
        $shortcut.Save()
        
        Write-Log "Auto-start shortcut created in Common Startup: $commonShortcutPath" -Level "SUCCESS"
        $successCount++
    } catch {
        Write-Log "Failed to create common startup shortcut: $_" -Level "WARN"
    }
    
    # Method 2: Also add to registry for all users (backup method)
    # HKLM Run works reliably when running as SYSTEM
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        Set-ItemProperty -Path $regPath -Name "WorkflowCapture" -Value "`"$ExePath`"" -Force
        Write-Log "Auto-start registry entry created: HKLM\...\Run\WorkflowCapture" -Level "SUCCESS"
        $successCount++
    } catch {
        Write-Log "Failed to create registry auto-start entry: $_" -Level "WARN"
    }
    
    if ($successCount -eq 0) {
        Write-Log "Failed to configure any auto-start method" -Level "ERROR"
        return $false
    }
    
    Write-Log "Configured $successCount auto-start method(s)" -Level "SUCCESS"
    return $true
}

function Set-DesktopShortcut {
    param([string]$ExePath)
    
    Write-Log "Creating desktop shortcut for all users (Public Desktop only)..."
    
    # Use ONLY Public Desktop - this appears on ALL user desktops and avoids
    # permission issues when running as SYSTEM with logged-in users
    # Individual user profile desktops may be inaccessible, redirected (OneDrive), or locked
    $publicDesktop = "C:\Users\Public\Desktop"
    
    if (-not (Test-Path $publicDesktop)) {
        Write-Log "Public Desktop not found, creating: $publicDesktop" -Level "WARN"
        try {
            New-Item -ItemType Directory -Path $publicDesktop -Force | Out-Null
        } catch {
            Write-Log "Failed to create Public Desktop: $_" -Level "ERROR"
            return $false
        }
    }
    
    $shortcutPath = Join-Path $publicDesktop "Workflow Capture.lnk"
    Write-Log "Creating shortcut at Public Desktop: $shortcutPath"
    
    try {
        # Remove existing shortcut first to avoid stale references
        if (Test-Path $shortcutPath) {
            Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
        }
        
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $ExePath
        $shortcut.WorkingDirectory = Split-Path $ExePath
        $shortcut.Description = "L7S Workflow Capture - Click to Record"
        $shortcut.IconLocation = "$ExePath,0"
        $shortcut.Save()
        
        Write-Log "Desktop shortcut created on Public Desktop: $shortcutPath" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Failed to create Public Desktop shortcut: $_" -Level "ERROR"
        return $false
    }
}

function Remove-BrokenShortcuts {
    # Find and remove any shortcuts pointing to non-existent executables
    Write-Log "Checking for broken shortcuts pointing to old installations..."
    
    $shortcutLocations = @(
        "C:\Users\Public\Desktop",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    )
    
    # Add all user desktops and startup folders
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users") }
    foreach ($profile in $userProfiles) {
        $shortcutLocations += "$($profile.FullName)\Desktop"
        $shortcutLocations += "$($profile.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    }
    
    $shortcutNames = @("Workflow Capture.lnk", "L7S Workflow Capture.lnk", "RECORD.lnk")
    $removedCount = 0
    
    foreach ($location in $shortcutLocations) {
        if (-not (Test-Path $location)) { continue }
        
        foreach ($name in $shortcutNames) {
            $shortcutPath = Join-Path $location $name
            if (Test-Path $shortcutPath) {
                try {
                    $shell = New-Object -ComObject WScript.Shell
                    $shortcut = $shell.CreateShortcut($shortcutPath)
                    $targetPath = $shortcut.TargetPath
                    
                    # Check if target exists
                    if (-not (Test-Path $targetPath)) {
                        Write-Log "Removing broken shortcut: $shortcutPath (target missing: $targetPath)"
                        Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
                        $removedCount++
                    }
                } catch {
                    Write-Log "Error checking shortcut ${shortcutPath}: $_" -Level "WARN"
                }
            }
        }
    }
    
    if ($removedCount -gt 0) {
        Write-Log "Removed $removedCount broken shortcut(s)" -Level "SUCCESS"
    }
    
    return $removedCount
}

function Remove-AutoStart {
    # Remove auto-start from Common Startup folder
    $commonStartup = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    $commonShortcut = Join-Path $commonStartup "Workflow Capture.lnk"
    if (Test-Path $commonShortcut) {
        Remove-Item $commonShortcut -Force -ErrorAction SilentlyContinue
        Write-Log "Removed common startup shortcut"
    }
    
    # Remove auto-start registry entry
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        if (Get-ItemProperty -Path $regPath -Name "WorkflowCapture" -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $regPath -Name "WorkflowCapture" -Force -ErrorAction SilentlyContinue
            Write-Log "Removed registry auto-start entry"
        }
    } catch {
        # Ignore if doesn't exist
    }
    
    # Remove auto-start shortcuts from all user profiles
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users") }
    
    foreach ($profile in $userProfiles) {
        $startupPath = "$($profile.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
        $shortcutPath = Join-Path $startupPath "Workflow Capture.lnk"
        
        if (Test-Path $shortcutPath) {
            Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
            Write-Log "Removed existing auto-start shortcut for $($profile.Name)"
        }
    }
}

function Uninstall-OldInstallations {
    Write-Log "Checking for old installations to remove..."
    Write-Log "NOTE: Session data in C:\temp\L7SWorkflowCapture\ is PRESERVED (not touched)"
    
    # IMPORTANT: Never touch the sessions/data directory
    $protectedPath = "C:\temp\L7SWorkflowCapture"
    
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
    
    # Also remove old installation directories manually - ALWAYS check all user profiles
    $oldInstallDirs = @(
        # Current user paths
        "$env:LOCALAPPDATA\Programs\l7s-workflow-capture",
        "$env:LOCALAPPDATA\Programs\workflow-capture",
        # System-wide paths
        "${env:ProgramFiles}\Workflow Capture",
        "${env:ProgramFiles(x86)}\Workflow Capture",
        "${env:ProgramFiles}\L7S Workflow Capture",
        "${env:ProgramFiles(x86)}\L7S Workflow Capture"
    )
    
    # ALWAYS check all user profiles for old installations (not just when running as SYSTEM)
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users") }
    foreach ($profile in $userProfiles) {
        $oldInstallDirs += "$($profile.FullName)\AppData\Local\Programs\l7s-workflow-capture"
        $oldInstallDirs += "$($profile.FullName)\AppData\Local\Programs\workflow-capture"
        $oldInstallDirs += "$($profile.FullName)\AppData\Local\Programs\Workflow Capture"
        $oldInstallDirs += "$($profile.FullName)\AppData\Local\l7s-workflow-capture"
    }
    
    foreach ($dir in $oldInstallDirs) {
        if (Test-Path $dir) {
            try {
                # SAFETY: Never remove the sessions/data directory
                if ($dir -like "*L7SWorkflowCapture*" -or $dir -like "*\temp\*") {
                    Write-Log "SKIPPING protected path: $dir" -Level "WARN"
                    continue
                }
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
    
    # Remove old desktop shortcuts - ALWAYS check all locations
    $desktopPaths = @(
        # Public desktop (appears on all users)
        "C:\Users\Public\Desktop"
    )
    
    # Add current user desktop
    $userDesktopPath = [Environment]::GetFolderPath("Desktop")
    $publicDesktopPath = [Environment]::GetFolderPath("CommonDesktopDirectory")
    if ($userDesktopPath) { $desktopPaths += $userDesktopPath }
    if ($publicDesktopPath -and $publicDesktopPath -notin $desktopPaths) { $desktopPaths += $publicDesktopPath }
    
    # ALWAYS check all user profile desktops (not just when running as SYSTEM)
    foreach ($profile in $userProfiles) {
        $profileDesktop = Join-Path $profile.FullName "Desktop"
        if ((Test-Path $profileDesktop) -and ($profileDesktop -notin $desktopPaths)) {
            $desktopPaths += $profileDesktop
        }
    }
    
    $shortcutNames = @(
        "Workflow Capture.lnk",
        "L7S Workflow Capture.lnk",
        "RECORD.lnk"
    )
    
    foreach ($desktopPath in $desktopPaths) {
        if (-not $desktopPath) { continue }
        foreach ($shortcutName in $shortcutNames) {
            $shortcut = Join-Path $desktopPath $shortcutName
            if (Test-Path $shortcut) {
                Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
                Write-Log "Removed old shortcut: $shortcut"
            }
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
    # Focus on Program Files paths (per-machine install target)
    # Still check user profiles to detect old per-user installs for cleanup
    $possiblePaths = @(
        "$InstallPath\Workflow Capture.exe",
        "${env:ProgramFiles}\Workflow Capture\Workflow Capture.exe",
        "${env:ProgramFiles(x86)}\Workflow Capture\Workflow Capture.exe"
    )
    
    # Check Program Files paths first (primary location)
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            Write-Log "Found existing installation at: $path"
            return $path
        }
    }
    
    # Also check user profiles for old per-user installs (these should be cleaned up)
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users") }
    foreach ($profile in $userProfiles) {
        $userPaths = @(
            "$($profile.FullName)\AppData\Local\Programs\l7s-workflow-capture\Workflow Capture.exe",
            "$($profile.FullName)\AppData\Local\Programs\workflow-capture\Workflow Capture.exe",
            "$($profile.FullName)\AppData\Local\Programs\Workflow Capture\Workflow Capture.exe"
        )
        foreach ($userPath in $userPaths) {
            if (Test-Path $userPath) {
                Write-Log "Found old per-user installation at: $userPath (will be migrated to Program Files)"
                # Return null to trigger reinstall to proper location
                return $null
            }
        }
    }
    
    # Fall back to recursive search in Program Files
    $searchPaths = @("$InstallPath", "${env:ProgramFiles}\Workflow Capture", "${env:ProgramFiles(x86)}\Workflow Capture")
    foreach ($searchPath in $searchPaths) {
        $result = Get-ExePath -SearchPath $searchPath -Recursive $true
        if ($result) {
            Write-Log "Found existing installation at: $result"
            return $result
        }
    }
    
    return $null
}

function Stop-RunningInstances {
    Write-Log "Checking for running instances of Workflow Capture..."
    
    # Use taskkill for robust termination across all sessions (works when running as SYSTEM)
    # This ensures processes in user sessions are killed, not just SYSTEM session
    $taskKillResult = & taskkill /F /IM "Workflow Capture.exe" 2>&1
    
    # Also try Get-Process as backup and for counting
    $processes = Get-Process -Name "Workflow Capture" -ErrorAction SilentlyContinue
    
    if ($processes) {
        $count = ($processes | Measure-Object).Count
        Write-Log "Found $count remaining instance(s) after taskkill - terminating via PowerShell..."
        
        $processes | ForEach-Object {
            try {
                $_ | Stop-Process -Force
                Write-Log "Terminated process ID: $($_.Id)"
            } catch {
                Write-Log "Failed to terminate process ID $($_.Id): $_" -Level "WARN"
            }
        }
        
        Start-Sleep -Seconds 2
        Write-Log "All running instances terminated" -Level "SUCCESS"
        return $count
    } elseif ($taskKillResult -notlike "*not found*" -and $taskKillResult -notlike "*ERROR*") {
        Write-Log "Terminated running instances via taskkill" -Level "SUCCESS"
        Start-Sleep -Seconds 2
        return 1
    }
    
    Write-Log "No running instances found"
    return 0
}

function Start-Application {
    param([string]$ExePath)
    
    # Check if running as SYSTEM - if so, don't try to start the app
    # Starting as SYSTEM launches in Session 0 which is invisible to users
    # The app will auto-start on next user login via Common Startup / HKLM Run
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")
    
    if ($isSystem) {
        Write-Log "Running as SYSTEM - skipping app launch (will auto-start on user login)" -Level "INFO"
        Write-Log "Auto-start is configured via Common Startup and HKLM Run" -Level "INFO"
        return $true
    }
    
    Write-Log "Starting $AppName..."
    
    $existingProcess = Get-Process -Name "Workflow Capture" -ErrorAction SilentlyContinue
    $processCount = Get-ProcessCount -ProcessName "Workflow Capture"
    
    if ($processCount -eq 1) {
        Write-Log "$AppName is already running (PID: $($existingProcess.Id)) - reusing existing instance" -Level "SUCCESS"
        return $true
    } elseif ($processCount -gt 1) {
        Write-Log "Multiple instances detected ($processCount) - keeping only the first one" -Level "WARN"
        $existingProcess | Select-Object -Skip 1 | ForEach-Object {
            try {
                $_ | Stop-Process -Force
                Write-Log "Terminated duplicate instance (PID: $($_.Id))"
            } catch {
                Write-Log "Failed to terminate duplicate instance: $_" -Level "WARN"
            }
        }
        Write-Log "$AppName running with single instance" -Level "SUCCESS"
        return $true
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
    
    # Determine app start status message
    $appStartStatus = if ($Result.ApplicationStarted) {
        if ($script:IsRunningAsSystem) { "Deferred to auto-start (SYSTEM context)" } else { "Yes" }
    } else {
        "No"
    }
    
    # Generate a clear summary message for NinjaRMM console
    $message = @"
================================================================================
L7S WORKFLOW CAPTURE - DEPLOYMENT SUMMARY
================================================================================
Computer Name:      $($Result.ComputerName)
Timestamp:          $($Result.Timestamp)
Status:             $(if ($Result.Success) { "SUCCESS" } else { "FAILED" })
Execution Context:  $(if ($script:IsRunningAsSystem) { "SYSTEM (NinjaRMM)" } else { "Interactive User" })
--------------------------------------------------------------------------------
ACTIONS PERFORMED:
  - Already Installed:    $(if ($Result.WasAlreadyInstalled) { "Yes (skipped download)" } else { "No (fresh install)" })
  - Instances Terminated: $($Result.InstancesTerminated)
  - Installation:         $(if ($Result.InstallationPerformed) { "Completed" } else { "Skipped (already installed)" })
  - Auto-Start:           Configured (Common Startup + HKLM Run)
  - Application Started:  $appStartStatus
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
    # Verify installation by finding the executable
    # First check our custom HKLM registry key (written by v1.1.3+ installer)
    Start-Sleep -Seconds 2
    
    Write-Log "Checking installation..."
    
    # Method 1: Check our custom HKLM registry key (most reliable for machine-wide install)
    try {
        $regPath = "HKLM:\Software\Layer7Systems\WorkflowCapture"
        if (Test-Path $regPath) {
            $installPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
            if ($installPath) {
                $exePath = Join-Path $installPath "Workflow Capture.exe"
                if (Test-Path $exePath) {
                    $fileInfo = Get-Item $exePath
                    Write-Log "Verified via HKLM registry: $exePath" -Level "SUCCESS"
                    Write-Log "  Version: $($fileInfo.VersionInfo.FileVersion)"
                    return $exePath
                }
            }
        }
    } catch {
        Write-Log "Registry check failed: $_" -Level "WARN"
    }
    
    # Method 2: Direct path checks
    $possiblePaths = @(
        # Per-machine paths (preferred)
        "C:\Program Files\Workflow Capture\Workflow Capture.exe",
        "$InstallPath\Workflow Capture.exe",
        "${env:ProgramFiles}\Workflow Capture\Workflow Capture.exe",
        "${env:ProgramFiles(x86)}\Workflow Capture\Workflow Capture.exe"
    )
    
    Write-Log "Checking standard paths..."
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $fileInfo = Get-Item $path
            Write-Log "Verified installation at: $path" -Level "SUCCESS"
            Write-Log "  Version: $($fileInfo.VersionInfo.FileVersion)"
            return $path
        }
    }
    
    # Method 3: Recursive search in Program Files only (machine-wide)
    Write-Log "Searching Program Files..."
    $searchPaths = @("C:\Program Files", "C:\Program Files (x86)")
    
    foreach ($searchPath in $searchPaths) {
        if (Test-Path $searchPath) {
            $foundExe = Get-ChildItem -Path $searchPath -Filter "Workflow Capture.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($foundExe) {
                Write-Log "Found executable: $($foundExe.FullName)" -Level "SUCCESS"
                Write-Log "  Version: $($foundExe.VersionInfo.FileVersion)"
                return $foundExe.FullName
            }
        }
    }
    
    # Method 4: Check if installer went to wrong location (per-user paths)
    Write-Log "Checking for incorrect per-user installation..." -Level "WARN"
    $perUserPaths = @(
        "C:\Windows\System32\config\systemprofile\AppData\Local\Programs",
        "$env:LOCALAPPDATA\Programs"
    )
    
    # Check all user profiles
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users") }
    foreach ($profile in $userProfiles) {
        $perUserPaths += "$($profile.FullName)\AppData\Local\Programs"
    }
    
    foreach ($searchPath in $perUserPaths) {
        if (Test-Path $searchPath) {
            $foundExe = Get-ChildItem -Path $searchPath -Filter "Workflow Capture.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($foundExe) {
                Write-Log "WARNING: Found in per-user location (incorrect): $($foundExe.FullName)" -Level "WARN"
                Write-Log "  This indicates the installer did not respect perMachine setting" -Level "WARN"
                # Still return it so we know it installed somewhere
                return $foundExe.FullName
            }
        }
    }
    
    Write-Log "Could not verify installation - executable not found" -Level "ERROR"
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

# Detect if running as SYSTEM account (NinjaRMM typically runs as SYSTEM)
$script:IsRunningAsSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")

Write-Log "=========================================="
Write-Log "$AppName - Silent Installation"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $env:USERNAME"
if ($script:IsRunningAsSystem) {
    Write-Log "Context: Running as SYSTEM (NinjaRMM deployment mode)"
    Write-Log "  - App will NOT be started (runs in Session 0)"
    Write-Log "  - Auto-start configured for next user login"
} else {
    Write-Log "Context: Running as interactive user"
}
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

# Remove any broken shortcuts pointing to old paths
$brokenShortcuts = Remove-BrokenShortcuts
Write-Log "Cleaned up $brokenShortcuts broken shortcut(s)"

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
    
    # Get installer from priority: URL > Source > GitHub
    $installerPath = Get-Installer -Url $InstallerUrl -Source $InstallerSource

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

# Check for existing session data (PRESERVED during install/upgrade)
$sessionsPath = "C:\temp\L7SWorkflowCapture\Sessions"
$existingRecordings = @()
if (Test-Path $sessionsPath) {
    $existingRecordings = Get-ChildItem $sessionsPath -Filter "*.webm" -File -ErrorAction SilentlyContinue
}
$existingCount = $existingRecordings.Count
if ($existingCount -gt 0) {
    $totalSizeMB = [math]::Round(($existingRecordings | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
    Write-Log "PRESERVED: $existingCount existing recording(s) ($totalSizeMB MB) in $sessionsPath" -Level "SUCCESS"
} else {
    Write-Log "No existing recordings found (fresh install or already extracted)"
}

# Deploy configuration file (allows remote config changes without reinstall)
Write-Log "Deploying configuration..."
$configDeployed = Deploy-Configuration -MaxMinutes $MaxRecordingMinutes -BitrateMbps $VideoBitrateMbps
if (-not $configDeployed) {
    Write-Log "Warning: Configuration deployment failed - app will use defaults" -Level "WARN"
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
Write-Log "Max Recording: $MaxRecordingMinutes minutes"
Write-Log "Video Bitrate: $VideoBitrateMbps Mbps"
Write-Log "Existing Recordings: $existingCount PRESERVED"
Write-Log "App Running: $(if ($appStarted) { 'Yes' } else { 'No' })"
Write-Log "Log File: $LogPath"
Write-Log "=========================================="

return $result
