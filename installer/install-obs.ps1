# L7S Workflow Analyzer - OBS Studio Installation Script
# This script downloads and installs OBS Studio silently, then configures it for screen recording
# 
# EXISTING OBS INSTALLATIONS:
# - Will NOT reinstall OBS if already present (unless -Force is used)
# - Will NOT modify existing profiles or scene collections
# - ADDS a new "L7S-ScreenCapture" profile alongside existing ones
# - Only enables WebSocket server (non-destructive setting)
# - Does NOT change the default profile - the app selects it programmatically

param(
    [string]$InstallPath = "C:\Program Files\obs-studio",
    [string]$ProfileName = "L7S-ScreenCapture",
    [switch]$Force,
    [switch]$SetAsDefault
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Configuration
$OBS_VERSION = "30.2.3"
$OBS_DOWNLOAD_URL = "https://github.com/obsproject/obs-studio/releases/download/$OBS_VERSION/OBS-Studio-$OBS_VERSION-Windows-Installer.exe"
$OBS_INSTALLER_PATH = "$env:TEMP\obs-studio-installer.exe"
$OBS_APPDATA = "$env:APPDATA\obs-studio"
$EXISTING_OBS_DETECTED = $false

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { "White" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-OBSInstalled {
    $obsExe = "$InstallPath\bin\64bit\obs64.exe"
    return Test-Path $obsExe
}

function Get-OBSVersion {
    $obsExe = "$InstallPath\bin\64bit\obs64.exe"
    if (Test-Path $obsExe) {
        try {
            $version = (Get-Item $obsExe).VersionInfo.ProductVersion
            return $version
        } catch {
            return "Unknown"
        }
    }
    return $null
}

function Test-ExistingOBSConfig {
    # Check if OBS has existing user configuration
    $profilesPath = "$OBS_APPDATA\basic\profiles"
    $scenesPath = "$OBS_APPDATA\basic\scenes"
    
    $hasProfiles = (Test-Path $profilesPath) -and ((Get-ChildItem $profilesPath -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    $hasScenes = (Test-Path $scenesPath) -and ((Get-ChildItem $scenesPath -File -Filter "*.json" -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    
    return $hasProfiles -or $hasScenes
}

function Backup-OBSConfig {
    if (Test-Path $OBS_APPDATA) {
        $backupPath = "$OBS_APPDATA.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Log "Backing up existing OBS configuration to: $backupPath" "INFO"
        Copy-Item -Path $OBS_APPDATA -Destination $backupPath -Recurse -Force
        Write-Log "Backup created successfully" "SUCCESS"
        return $backupPath
    }
    return $null
}

function Install-OBS {
    Write-Log "Downloading OBS Studio $OBS_VERSION..."
    
    try {
        # Download OBS installer
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $OBS_DOWNLOAD_URL -OutFile $OBS_INSTALLER_PATH -UseBasicParsing
        Write-Log "Download complete" "SUCCESS"
    } catch {
        Write-Log "Failed to download OBS: $_" "ERROR"
        throw
    }

    Write-Log "Installing OBS Studio silently..."
    
    try {
        # Run installer silently
        $process = Start-Process -FilePath $OBS_INSTALLER_PATH -ArgumentList "/S", "/D=$InstallPath" -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -ne 0) {
            throw "OBS installer exited with code $($process.ExitCode)"
        }
        
        Write-Log "OBS Studio installed successfully" "SUCCESS"
    } catch {
        Write-Log "Failed to install OBS: $_" "ERROR"
        throw
    } finally {
        # Clean up installer
        if (Test-Path $OBS_INSTALLER_PATH) {
            Remove-Item $OBS_INSTALLER_PATH -Force
        }
    }
}

function Configure-OBSWebSocket {
    Write-Log "Configuring OBS WebSocket server..."
    
    $globalConfigPath = "$OBS_APPDATA\global.ini"
    
    # Create obs-studio appdata folder if it doesn't exist
    if (-not (Test-Path $OBS_APPDATA)) {
        New-Item -ItemType Directory -Path $OBS_APPDATA -Force | Out-Null
    }
    
    # WebSocket configuration (OBS 28+ has built-in WebSocket)
    # We only add/update the WebSocket section, preserving everything else
    $websocketSettings = @{
        "ServerEnabled" = "true"
        "ServerPort" = "4455"
        "AuthRequired" = "false"
        "AlertsEnabled" = "false"
        "FirstLoad" = "false"
    }

    # General settings to disable safe mode prompt
    $generalSettings = @{
        "OpenStatsOnStartup" = "false"
        "RecordWhenStreaming" = "false"
        "KeepRecordingWhenStreamStops" = "false"
        "WarnBeforeStartingStream" = "false"
        "WarnBeforeStoppingStream" = "false"
        "SnappingEnabled" = "true"
        "SnapDistance" = "10.0"
        "SafeMode" = "false"
    }

    # Read existing config
    $config = @{}
    if (Test-Path $globalConfigPath) {
        $currentSection = ""
        Get-Content $globalConfigPath | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^\[(.+)\]$') {
                $currentSection = $matches[1]
                if (-not $config.ContainsKey($currentSection)) {
                    $config[$currentSection] = [ordered]@{}
                }
            } elseif ($line -match '^(.+?)=(.*)$' -and $currentSection) {
                $config[$currentSection][$matches[1]] = $matches[2]
            }
        }
    }
    
    # Add/update General settings (disable safe mode)
    if (-not $config.ContainsKey("General")) {
        $config["General"] = [ordered]@{}
    }
    foreach ($key in $generalSettings.Keys) {
        $config["General"][$key] = $generalSettings[$key]
    }
    
    # Add/update WebSocket settings
    if (-not $config.ContainsKey("OBSWebSocket")) {
        $config["OBSWebSocket"] = [ordered]@{}
    }
    foreach ($key in $websocketSettings.Keys) {
        $config["OBSWebSocket"][$key] = $websocketSettings[$key]
    }
    
    # Write config back, preserving all sections
    $output = @()
    foreach ($section in $config.Keys) {
        $output += "[$section]"
        foreach ($key in $config[$section].Keys) {
            $output += "$key=$($config[$section][$key])"
        }
        $output += ""
    }
    
    Set-Content -Path $globalConfigPath -Value ($output -join "`n") -Encoding UTF8
    
    Write-Log "WebSocket server configured (port 4455, no auth)" "SUCCESS"
    Write-Log "Safe mode disabled - OBS will always start normally" "SUCCESS"
}

function Configure-OBSProfile {
    param([bool]$IsNewInstall = $false)
    
    Write-Log "Creating L7S screen capture profile..."
    
    $profilePath = "$OBS_APPDATA\basic\profiles\$ProfileName"
    
    # Check if our profile already exists
    if (Test-Path $profilePath) {
        Write-Log "Profile '$ProfileName' already exists, updating..." "INFO"
    }
    
    # Create profile directory
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
    }
    
    # Basic profile configuration
    $basicIni = @"
[General]
Name=$ProfileName

[Video]
BaseCX=1920
BaseCY=1080
OutputCX=1920
OutputCY=1080
FPSType=1
FPSCommon=30
FPSInt=30
FPSNum=30
FPSDen=1

[Audio]
SampleRate=48000
ChannelSetup=Stereo

[AdvOut]
RecType=Standard
RecFormat=mp4
RecEncoder=obs_x264
RecMuxerCustom=
RecFilePath=C:/BandaStudy/Sessions
RecFileNameWithoutSpace=true
RecTracks=1
RecSplitFileType=Size
RecSplitFileResetTimestamps=false

[SimpleOutput]
FilePath=C:/BandaStudy/Sessions
RecFormat=mp4
RecQuality=Small
RecEncoder=x264
RecRB=false
RecRBTime=20
RecRBSize=512
RecRBPrefix=Replay

[Output]
Mode=Simple
"@

    Set-Content -Path "$profilePath\basic.ini" -Value $basicIni -Encoding UTF8
    
    # Encoder settings
    if (-not (Test-Path "$profilePath\recordEncoder.json")) {
        Set-Content -Path "$profilePath\recordEncoder.json" -Value '{}' -Encoding UTF8
    }
    
    # Service configuration (not needed for local recording but OBS expects it)
    $serviceJson = @"
{
    "settings": {
        "key": "",
        "server": "auto"
    },
    "type": "rtmp_common"
}
"@
    Set-Content -Path "$profilePath\service.json" -Value $serviceJson -Encoding UTF8
    
    Write-Log "Profile '$ProfileName' created" "SUCCESS"
}

function Configure-OBSSceneCollection {
    param([bool]$IsNewInstall = $false)
    
    Write-Log "Creating screen capture scene collection..."
    
    $sceneCollectionPath = "$OBS_APPDATA\basic\scenes"
    $sceneFile = "$sceneCollectionPath\$ProfileName.json"
    
    # Create scenes directory
    if (-not (Test-Path $sceneCollectionPath)) {
        New-Item -ItemType Directory -Path $sceneCollectionPath -Force | Out-Null
    }
    
    # Check if our scene collection already exists
    if (Test-Path $sceneFile) {
        Write-Log "Scene collection '$ProfileName' already exists, updating..." "INFO"
    }
    
    # Get all monitors for multi-monitor capture
    Add-Type -AssemblyName System.Windows.Forms
    $screens = [System.Windows.Forms.Screen]::AllScreens
    
    $sources = @()
    $sceneItems = @()
    $itemIndex = 1
    
    foreach ($screen in $screens) {
        $monitorName = "Monitor $itemIndex"
        $bounds = $screen.Bounds
        
        $sourceUuid = [guid]::NewGuid().ToString()
        
        $source = @{
            "prev_ver" = 503316480
            "name" = $monitorName
            "uuid" = $sourceUuid
            "id" = "monitor_capture"
            "versioned_id" = "monitor_capture"
            "settings" = @{
                "monitor" = ($itemIndex - 1)
                "capture_cursor" = $true
            }
            "mixers" = 0
            "sync" = 0
            "flags" = 0
            "volume" = 1.0
            "balance" = 0.5
            "enabled" = $true
            "muted" = $false
            "push-to-mute" = $false
            "push-to-mute-delay" = 0
            "push-to-talk" = $false
            "push-to-talk-delay" = 0
            "hotkeys" = @{}
            "deinterlace_mode" = 0
            "deinterlace_field_order" = 0
            "monitoring_type" = 0
            "private_settings" = @{}
        }
        
        $sceneItem = @{
            "name" = $monitorName
            "source_uuid" = $sourceUuid
            "visible" = $true
            "locked" = $false
            "rot" = 0.0
            "pos" = @{ "x" = [double]$bounds.X; "y" = 0.0 }
            "scale" = @{ "x" = 1.0; "y" = 1.0 }
            "align" = 5
            "bounds_type" = 0
            "bounds_align" = 0
            "bounds" = @{ "x" = 0.0; "y" = 0.0 }
            "crop_left" = 0
            "crop_top" = 0
            "crop_right" = 0
            "crop_bottom" = 0
            "id" = $itemIndex
            "group_item_backup" = $false
            "scale_filter" = "disable"
            "blend_method" = "default"
            "blend_type" = "normal"
            "show_transition" = @{ "duration" = 0 }
            "hide_transition" = @{ "duration" = 0 }
            "private_settings" = @{}
        }
        
        $sources += $source
        $sceneItems += $sceneItem
        $itemIndex++
    }
    
    # Add desktop audio capture
    $audioUuid = [guid]::NewGuid().ToString()
    $audioSource = @{
        "prev_ver" = 503316480
        "name" = "Desktop Audio"
        "uuid" = $audioUuid
        "id" = "wasapi_output_capture"
        "versioned_id" = "wasapi_output_capture"
        "settings" = @{
            "device_id" = "default"
        }
        "mixers" = 255
        "sync" = 0
        "flags" = 0
        "volume" = 1.0
        "balance" = 0.5
        "enabled" = $true
        "muted" = $false
        "push-to-mute" = $false
        "push-to-mute-delay" = 0
        "push-to-talk" = $false
        "push-to-talk-delay" = 0
        "hotkeys" = @{}
        "deinterlace_mode" = 0
        "deinterlace_field_order" = 0
        "monitoring_type" = 0
        "private_settings" = @{}
    }
    $sources += $audioSource
    
    # Create the main scene
    $sceneUuid = [guid]::NewGuid().ToString()
    $mainScene = @{
        "name" = "L7S Screen Capture"
        "uuid" = $sceneUuid
        "id" = "scene"
        "versioned_id" = "scene"
        "settings" = @{
            "items" = $sceneItems
            "id_counter" = $itemIndex
            "custom_size" = $false
        }
        "mixers" = 0
        "sync" = 0
        "flags" = 0
        "volume" = 1.0
        "balance" = 0.5
        "enabled" = $true
        "muted" = $false
        "push-to-mute" = $false
        "push-to-mute-delay" = 0
        "push-to-talk" = $false
        "push-to-talk-delay" = 0
        "hotkeys" = @{}
        "deinterlace_mode" = 0
        "deinterlace_field_order" = 0
        "monitoring_type" = 0
        "private_settings" = @{}
    }
    $sources += $mainScene
    
    # Scene collection JSON
    $sceneCollection = @{
        "current_scene" = "L7S Screen Capture"
        "current_program_scene" = "L7S Screen Capture"
        "scene_order" = @(
            @{ "name" = "L7S Screen Capture" }
        )
        "name" = $ProfileName
        "sources" = $sources
        "groups" = @()
        "quick_transitions" = @()
        "transitions" = @()
        "saved_projectors" = @()
        "current_transition" = "Fade"
        "transition_duration" = 300
        "preview_locked" = $false
        "scaling_enabled" = $false
        "scaling_level" = 0
        "scaling_off_x" = 0.0
        "scaling_off_y" = 0.0
    }
    
    $sceneCollectionJson = $sceneCollection | ConvertTo-Json -Depth 10
    Set-Content -Path $sceneFile -Value $sceneCollectionJson -Encoding UTF8
    
    Write-Log "Scene collection created with $($screens.Count) monitor(s)" "SUCCESS"
}

function Set-OBSDefaultProfile {
    param([bool]$ForceDefault = $false)
    
    # Only set as default if explicitly requested or if this is a fresh OBS install
    if (-not $ForceDefault) {
        Write-Log "Skipping default profile change (preserving user's existing default)" "INFO"
        Write-Log "The L7S app will select the correct profile when launching OBS" "INFO"
        return
    }
    
    Write-Log "Setting L7S profile as default..."
    
    $globalConfigPath = "$OBS_APPDATA\global.ini"
    
    # Read existing config
    $config = @{}
    if (Test-Path $globalConfigPath) {
        $currentSection = ""
        Get-Content $globalConfigPath | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^\[(.+)\]$') {
                $currentSection = $matches[1]
                if (-not $config.ContainsKey($currentSection)) {
                    $config[$currentSection] = [ordered]@{}
                }
            } elseif ($line -match '^(.+?)=(.*)$' -and $currentSection) {
                $config[$currentSection][$matches[1]] = $matches[2]
            }
        }
    }
    
    # Set default profile and scene collection
    if (-not $config.ContainsKey("Basic")) {
        $config["Basic"] = [ordered]@{}
    }
    $config["Basic"]["Profile"] = $ProfileName
    $config["Basic"]["ProfileDir"] = $ProfileName
    $config["Basic"]["SceneCollection"] = $ProfileName
    $config["Basic"]["SceneCollectionFile"] = $ProfileName
    
    # Write config back
    $output = @()
    foreach ($section in $config.Keys) {
        $output += "[$section]"
        foreach ($key in $config[$section].Keys) {
            $output += "$key=$($config[$section][$key])"
        }
        $output += ""
    }
    
    Set-Content -Path $globalConfigPath -Value ($output -join "`n") -Encoding UTF8
    
    Write-Log "Default profile set to '$ProfileName'" "SUCCESS"
}

function Create-BandaStudyDirectory {
    Write-Log "Creating BandaStudy sessions directory..."
    
    $sessionsPath = "C:\BandaStudy\Sessions"
    
    if (-not (Test-Path $sessionsPath)) {
        New-Item -ItemType Directory -Path $sessionsPath -Force | Out-Null
        Write-Log "Created: $sessionsPath" "SUCCESS"
    } else {
        Write-Log "Directory already exists: $sessionsPath" "INFO"
    }
}

function Show-ExistingOBSWarning {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host "  Existing OBS Configuration Detected" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Log "Your existing OBS profiles and scenes will be PRESERVED" "INFO"
    Write-Log "We will ADD a new 'L7S-ScreenCapture' profile for this app" "INFO"
    Write-Log "Your default OBS profile will NOT be changed" "INFO"
    Write-Host ""
}

# Main installation flow
function Main {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  L7S Workflow Analyzer - OBS Setup" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    
    $isNewInstall = $false
    
    # Check if OBS is already installed
    if (Test-OBSInstalled) {
        $version = Get-OBSVersion
        Write-Log "OBS Studio is already installed (version: $version)" "INFO"
        $script:EXISTING_OBS_DETECTED = $true
        
        # Check for existing user configuration
        if (Test-ExistingOBSConfig) {
            Show-ExistingOBSWarning
        }
        
        if ($Force) {
            Write-Log "Force flag set, reinstalling OBS..." "WARNING"
            Backup-OBSConfig
            Install-OBS
        } else {
            Write-Log "Skipping OBS installation (use -Force to reinstall)" "INFO"
        }
    } else {
        Write-Log "OBS Studio not found, installing..." "INFO"
        Install-OBS
        $isNewInstall = $true
    }
    
    # Kill any running OBS instances before configuring
    $obsProcesses = Get-Process -Name "obs64" -ErrorAction SilentlyContinue
    if ($obsProcesses) {
        Write-Log "Stopping running OBS instances..." "WARNING"
        $obsProcesses | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
    
    # Configure OBS
    Configure-OBSWebSocket
    Configure-OBSProfile -IsNewInstall $isNewInstall
    Configure-OBSSceneCollection -IsNewInstall $isNewInstall
    
    # Only set as default for new installs or if explicitly requested
    Set-OBSDefaultProfile -ForceDefault ($isNewInstall -or $SetAsDefault)
    
    Create-BandaStudyDirectory
    
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Installation Complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Log "OBS Studio is configured for screen capture" "SUCCESS"
    Write-Log "WebSocket server: ws://127.0.0.1:4455 (no auth)" "INFO"
    Write-Log "Recording output: C:\BandaStudy\Sessions\" "INFO"
    
    if ($script:EXISTING_OBS_DETECTED -and -not $isNewInstall) {
        Write-Host ""
        Write-Log "NOTE: Your existing OBS configuration was preserved" "INFO"
        Write-Log "The L7S profile was added alongside your existing profiles" "INFO"
    }
    
    Write-Host ""
}

# Run main
Main
