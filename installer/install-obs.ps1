# L7S Workflow Capture - OBS Studio Installation Script
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
    [string]$SessionsPath = "C:\BandaStudy\Sessions",
    [switch]$Force,
    [switch]$SetAsDefault
)

# Use Continue for non-critical errors - we'll handle them explicitly
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Track if we had any warnings (non-fatal issues)
$script:WarningsEncountered = $false

# Configuration
$OBS_VERSION = "30.2.3"
$OBS_DOWNLOAD_URL = "https://github.com/obsproject/obs-studio/releases/download/$OBS_VERSION/OBS-Studio-$OBS_VERSION-Windows-Installer.exe"
$OBS_INSTALLER_PATH = "$env:TEMP\obs-studio-installer.exe"
$OBS_APPDATA = "$env:APPDATA\obs-studio"
$EXISTING_OBS_DETECTED = $false
$MIN_INSTALLER_SIZE_BYTES = 50000000  # ~50MB minimum expected size
$MIN_DISK_SPACE_MB = 500  # Minimum free space required

# Diagnostic log file - critical for VM debugging
$DIAGNOSTIC_LOG_PATH = "C:\BandaStudy\obs-setup-diagnostic.log"

function Initialize-DiagnosticLog {
    try {
        # Ensure directory exists
        $logDir = Split-Path $DIAGNOSTIC_LOG_PATH -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        
        # Start fresh log
        $header = @"
========================================
L7S OBS Setup Diagnostic Log
Started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Computer: $env:COMPUTERNAME
User: $env:USERNAME
PowerShell: $($PSVersionTable.PSVersion)
OS: $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)
========================================

"@
        Set-Content -Path $DIAGNOSTIC_LOG_PATH -Value $header -Encoding UTF8
    } catch {
        # Can't even create log file - write to console
        Write-Host "WARNING: Cannot create diagnostic log at $DIAGNOSTIC_LOG_PATH : $_" -ForegroundColor Yellow
    }
}

function Write-DiagnosticLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $DIAGNOSTIC_LOG_PATH -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Silently fail - don't break installation for logging
    }
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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
    # Also write to diagnostic log
    Write-DiagnosticLog -Message $Message -Level $Level
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

function Test-NetworkConnectivity {
    Write-Log "Checking network connectivity..." "INFO"
    try {
        $testUri = "https://github.com"
        $response = Invoke-WebRequest -Uri $testUri -UseBasicParsing -Method Head -TimeoutSec 10
        return $true
    } catch {
        Write-Log "Network connectivity check failed: $_" "WARNING"
        return $false
    }
}

function Test-DiskSpace {
    param([string]$Path, [int]$RequiredMB)
    try {
        $drive = (Get-Item $Path -ErrorAction SilentlyContinue).PSDrive
        if (-not $drive) {
            # Path doesn't exist yet, check the root
            $driveLetter = $Path.Substring(0, 1)
            $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
        }
        if ($drive -and $drive.Free) {
            $freeMB = [math]::Round($drive.Free / 1MB)
            return $freeMB -ge $RequiredMB
        }
        # Can't determine, assume OK
        return $true
    } catch {
        return $true  # Can't check, proceed anyway
    }
}

function Test-FileWritable {
    param([string]$FilePath)
    try {
        $dir = Split-Path $FilePath -Parent
        if (-not (Test-Path $dir)) {
            return $true  # Directory doesn't exist yet, should be creatable
        }
        if (Test-Path $FilePath) {
            # Try to open file for writing
            $stream = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
            $stream.Close()
            return $true
        }
        return $true
    } catch {
        return $false
    }
}

function Install-OBS {
    Write-Log "Downloading OBS Studio $OBS_VERSION..."
    
    # Check network connectivity first
    if (-not (Test-NetworkConnectivity)) {
        throw "Cannot reach GitHub. Please check your internet connection and firewall settings."
    }
    
    try {
        # Enable TLS 1.2 and 1.3 for secure downloads
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        
        # Remove any existing partial download
        if (Test-Path $OBS_INSTALLER_PATH) {
            Remove-Item $OBS_INSTALLER_PATH -Force -ErrorAction SilentlyContinue
        }
        
        # Try primary download URL
        try {
            Invoke-WebRequest -Uri $OBS_DOWNLOAD_URL -OutFile $OBS_INSTALLER_PATH -UseBasicParsing -TimeoutSec 300
        } catch {
            Write-Log "Primary download failed, this OBS version may no longer be available: $_" "WARNING"
            Write-Log "Please download OBS Studio manually from https://obsproject.com/download" "ERROR"
            throw "Failed to download OBS installer. The version $OBS_VERSION may no longer be available."
        }
        
        # Validate download size
        $downloadedSize = (Get-Item $OBS_INSTALLER_PATH).Length
        if ($downloadedSize -lt $MIN_INSTALLER_SIZE_BYTES) {
            throw "Downloaded file is too small ($downloadedSize bytes). Expected at least $MIN_INSTALLER_SIZE_BYTES bytes. Download may be corrupt or incomplete."
        }
        
        Write-Log "Download complete ($([math]::Round($downloadedSize / 1MB, 1)) MB)" "SUCCESS"
    } catch {
        Write-Log "Failed to download OBS: $_" "ERROR"
        # Clean up partial download
        if (Test-Path $OBS_INSTALLER_PATH) {
            Remove-Item $OBS_INSTALLER_PATH -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    Write-Log "Installing OBS Studio silently..."
    
    try {
        # NSIS installers require /D= to be the LAST argument and path must NOT be quoted
        # For paths with spaces, NSIS handles it correctly when /D= is last
        $installerArgs = @("/S", "/D=$InstallPath")
        
        $process = Start-Process -FilePath $OBS_INSTALLER_PATH -ArgumentList $installerArgs -Wait -PassThru
        
        if ($process.ExitCode -ne 0) {
            throw "OBS installer exited with code $($process.ExitCode)"
        }
        
        # Verify installation actually succeeded
        Start-Sleep -Seconds 2
        if (-not (Test-OBSInstalled)) {
            throw "OBS installation appeared to complete but obs64.exe was not found at expected location"
        }
        
        Write-Log "OBS Studio installed successfully" "SUCCESS"
    } catch {
        Write-Log "Failed to install OBS: $_" "ERROR"
        throw
    } finally {
        # Clean up installer
        if (Test-Path $OBS_INSTALLER_PATH) {
            Remove-Item $OBS_INSTALLER_PATH -Force -ErrorAction SilentlyContinue
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

    # Read existing config, preserving section order
    $config = [ordered]@{}
    if (Test-Path $globalConfigPath) {
        $currentSection = ""
        Get-Content $globalConfigPath -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            # Skip empty lines and comments
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(';') -or $line.StartsWith('#')) {
                return
            }
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
    
    # Use UTF8 without BOM (OBS expects this format)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($globalConfigPath, $output, $utf8NoBom)
    
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
    
    # Get display information for canvas sizing
    $canvasWidth = 1920
    $canvasHeight = 1080
    
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screens = [System.Windows.Forms.Screen]::AllScreens
        
        # Validate we have at least one screen
        if ($null -eq $screens -or $screens.Count -eq 0) {
            Write-Log "No displays detected, using default 1920x1080" "WARNING"
            $script:WarningsEncountered = $true
        } else {
        # Calculate total canvas size (virtual screen bounds)
        $minX = 0
        $minY = 0
        $maxX = 0
        $maxY = 0
        
        foreach ($screen in $screens) {
            $bounds = $screen.Bounds
            if ($bounds.X -lt $minX) { $minX = $bounds.X }
            if ($bounds.Y -lt $minY) { $minY = $bounds.Y }
            if (($bounds.X + $bounds.Width) -gt $maxX) { $maxX = $bounds.X + $bounds.Width }
            if (($bounds.Y + $bounds.Height) -gt $maxY) { $maxY = $bounds.Y + $bounds.Height }
        }
        
        $canvasWidth = $maxX - $minX
        $canvasHeight = $maxY - $minY
        
        # Sanity check canvas dimensions
        if ($canvasWidth -le 0 -or $canvasHeight -le 0) {
            Write-Log "Invalid canvas dimensions detected ($canvasWidth x $canvasHeight), using default 1920x1080" "WARNING"
            $script:WarningsEncountered = $true
            $canvasWidth = 1920
            $canvasHeight = 1080
        }
        
        Write-Log "Detected $($screens.Count) display(s), canvas size: ${canvasWidth}x${canvasHeight}" "INFO"
        }
    } catch {
        Write-Log "Failed to detect display configuration, using defaults: $_" "WARNING"
        $script:WarningsEncountered = $true
        $canvasWidth = 1920
        $canvasHeight = 1080
    }
    
    # Normalize sessions path for OBS (use forward slashes for cross-platform compatibility in OBS)
    $obsSessionsPath = $SessionsPath -replace '\\', '/'
    
    # Basic profile configuration with dynamic canvas size
    $basicIni = @"
[General]
Name=$ProfileName

[Video]
BaseCX=$canvasWidth
BaseCY=$canvasHeight
OutputCX=$canvasWidth
OutputCY=$canvasHeight
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
RecFilePath=$obsSessionsPath
RecFileNameWithoutSpace=true
RecTracks=1
RecSplitFileType=Size
RecSplitFileResetTimestamps=false

[SimpleOutput]
FilePath=$obsSessionsPath
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

    # Use UTF8 without BOM for OBS compatibility
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText("$profilePath\basic.ini", $basicIni, $utf8NoBom)
    
    # Encoder settings
    if (-not (Test-Path "$profilePath\recordEncoder.json")) {
        [System.IO.File]::WriteAllText("$profilePath\recordEncoder.json", '{}', $utf8NoBom)
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
    [System.IO.File]::WriteAllText("$profilePath\service.json", $serviceJson, $utf8NoBom)
    
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
    $screens = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $screens = [System.Windows.Forms.Screen]::AllScreens
    } catch {
        Write-Log "Failed to detect screens for scene collection: $_" "WARNING"
        $script:WarningsEncountered = $true
    }
    
    # Handle case where no screens are detected
    if ($null -eq $screens -or $screens.Count -eq 0) {
        Write-Log "No displays detected for scene collection, creating default single-monitor setup" "WARNING"
        $script:WarningsEncountered = $true
        # Create a minimal scene with default values
        $screens = @(@{
            Bounds = @{
                X = 0
                Y = 0
                Width = 1920
                Height = 1080
            }
        })
    }
    
    # Calculate canvas bounds (for proper positioning)
    $minX = 0
    $minY = 0
    foreach ($screen in $screens) {
        $bounds = if ($screen -is [System.Windows.Forms.Screen]) { $screen.Bounds } else { $screen.Bounds }
        if ($bounds.X -lt $minX) { $minX = $bounds.X }
        if ($bounds.Y -lt $minY) { $minY = $bounds.Y }
    }
    
    $sources = @()
    $sceneItems = @()
    $itemIndex = 1
    
    foreach ($screen in $screens) {
        $bounds = if ($screen -is [System.Windows.Forms.Screen]) { $screen.Bounds } else { $screen.Bounds }
        $monitorName = if ($screens.Count -gt 1) { "Monitor $itemIndex" } else { "Display Capture" }
        
        # Adjust position relative to canvas origin (handle negative coordinates)
        $posX = $bounds.X - $minX
        $posY = $bounds.Y - $minY
        
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
        
        # Use bounds_type 2 (scale to inner bounds) for proper fitting
        $sceneItem = @{
            "name" = $monitorName
            "source_uuid" = $sourceUuid
            "visible" = $true
            "locked" = $false
            "rot" = 0.0
            "pos" = @{ "x" = [double]$posX; "y" = [double]$posY }
            "scale" = @{ "x" = 1.0; "y" = 1.0 }
            "align" = 5
            "bounds_type" = 2  # Scale to inner bounds - fits content properly
            "bounds_align" = 0
            "bounds" = @{ "x" = [double]$bounds.Width; "y" = [double]$bounds.Height }
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
    
    # Calculate canvas size for resolution field
    $minX = 0
    $minY = 0
    $maxX = 0
    $maxY = 0
    foreach ($screen in $screens) {
        $bounds = if ($screen -is [System.Windows.Forms.Screen]) { $screen.Bounds } else { $screen.Bounds }
        if ($bounds.X -lt $minX) { $minX = $bounds.X }
        if ($bounds.Y -lt $minY) { $minY = $bounds.Y }
        if (($bounds.X + $bounds.Width) -gt $maxX) { $maxX = $bounds.X + $bounds.Width }
        if (($bounds.Y + $bounds.Height) -gt $maxY) { $maxY = $bounds.Y + $bounds.Height }
    }
    $canvasWidth = $maxX - $minX
    $canvasHeight = $maxY - $minY
    
    # Sanity check
    if ($canvasWidth -le 0) { $canvasWidth = 1920 }
    if ($canvasHeight -le 0) { $canvasHeight = 1080 }
    
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
    
    # Scene collection JSON with resolution info
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
        "resolution" = @{
            "x" = $canvasWidth
            "y" = $canvasHeight
        }
        "version" = 1
    }
    
    # Use depth 20 to handle complex nested structures properly
    $sceneCollectionJson = $sceneCollection | ConvertTo-Json -Depth 20
    
    # Use UTF8 without BOM for OBS compatibility
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($sceneFile, $sceneCollectionJson, $utf8NoBom)
    
    Write-Log "Scene collection created with $($screens.Count) monitor(s)" "SUCCESS"
    foreach ($screen in $screens) {
        $bounds = if ($screen -is [System.Windows.Forms.Screen]) { $screen.Bounds } else { $screen.Bounds }
        Write-Log "  Display: $($bounds.Width)x$($bounds.Height) at position ($($bounds.X), $($bounds.Y))" "INFO"
    }
    Write-Log "Canvas size: ${canvasWidth}x${canvasHeight}" "INFO"
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
    
    # Read existing config, preserving section order
    $config = [ordered]@{}
    if (Test-Path $globalConfigPath) {
        $currentSection = ""
        Get-Content $globalConfigPath -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            # Skip empty lines and comments
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(';') -or $line.StartsWith('#')) {
                return
            }
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
    
    # Use UTF8 without BOM (OBS expects this format)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($globalConfigPath, $output, $utf8NoBom)
    
    Write-Log "Default profile set to '$ProfileName'" "SUCCESS"
}

function Create-BandaStudyDirectory {
    Write-Log "Creating sessions directory..."
    
    if (-not (Test-Path $SessionsPath)) {
        try {
            New-Item -ItemType Directory -Path $SessionsPath -Force | Out-Null
            Write-Log "Created: $SessionsPath" "SUCCESS"
        } catch {
            Write-Log "Failed to create sessions directory: $_" "ERROR"
            Write-Log "Please manually create: $SessionsPath" "WARNING"
        }
    } else {
        Write-Log "Directory already exists: $SessionsPath" "INFO"
    }
    
    # Verify the directory is writable
    try {
        $testFile = Join-Path $SessionsPath ".write-test-$(Get-Random).tmp"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force
    } catch {
        Write-Log "Warning: Sessions directory may not be writable: $_" "WARNING"
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

function Write-DiagnosticSummary {
    Write-DiagnosticLog "" "INFO"
    Write-DiagnosticLog "=== DIAGNOSTIC SUMMARY ===" "INFO"
    Write-DiagnosticLog "" "INFO"
    
    # Check OBS executable
    $obsExe = "$InstallPath\bin\64bit\obs64.exe"
    if (Test-Path $obsExe) {
        Write-DiagnosticLog "[OK] OBS executable found: $obsExe" "SUCCESS"
        try {
            $version = (Get-Item $obsExe).VersionInfo.ProductVersion
            Write-DiagnosticLog "     OBS Version: $version" "INFO"
        } catch {
            Write-DiagnosticLog "     OBS Version: Unknown" "WARNING"
        }
    } else {
        Write-DiagnosticLog "[FAIL] OBS executable NOT found: $obsExe" "ERROR"
    }
    
    # Check global.ini (WebSocket settings)
    $globalIni = "$OBS_APPDATA\global.ini"
    if (Test-Path $globalIni) {
        Write-DiagnosticLog "[OK] global.ini found: $globalIni" "SUCCESS"
        try {
            $content = Get-Content $globalIni -Raw
            if ($content -match "ServerEnabled\s*=\s*true") {
                Write-DiagnosticLog "     WebSocket ServerEnabled: true" "SUCCESS"
            } else {
                Write-DiagnosticLog "[WARN] WebSocket ServerEnabled: NOT FOUND or false" "WARNING"
            }
            if ($content -match "ServerPort\s*=\s*(\d+)") {
                Write-DiagnosticLog "     WebSocket Port: $($matches[1])" "INFO"
            }
            if ($content -match "AuthRequired\s*=\s*false") {
                Write-DiagnosticLog "     AuthRequired: false (good)" "SUCCESS"
            } else {
                Write-DiagnosticLog "[WARN] AuthRequired: NOT FOUND or true - may cause connection issues" "WARNING"
            }
            if ($content -match "SafeMode\s*=\s*false") {
                Write-DiagnosticLog "     SafeMode: false (good)" "SUCCESS"
            } else {
                Write-DiagnosticLog "[WARN] SafeMode: NOT FOUND or true - OBS may prompt for safe mode" "WARNING"
            }
        } catch {
            Write-DiagnosticLog "     Failed to read global.ini: $_" "WARNING"
        }
    } else {
        Write-DiagnosticLog "[FAIL] global.ini NOT found: $globalIni" "ERROR"
    }
    
    # Check profile
    $profilePath = "$OBS_APPDATA\basic\profiles\$ProfileName"
    if (Test-Path $profilePath) {
        Write-DiagnosticLog "[OK] Profile folder found: $profilePath" "SUCCESS"
        $basicIni = "$profilePath\basic.ini"
        if (Test-Path $basicIni) {
            Write-DiagnosticLog "     basic.ini exists" "SUCCESS"
        } else {
            Write-DiagnosticLog "[WARN] basic.ini NOT found in profile" "WARNING"
        }
    } else {
        Write-DiagnosticLog "[FAIL] Profile folder NOT found: $profilePath" "ERROR"
    }
    
    # Check scene collection
    $sceneFile = "$OBS_APPDATA\basic\scenes\$ProfileName.json"
    if (Test-Path $sceneFile) {
        Write-DiagnosticLog "[OK] Scene collection found: $sceneFile" "SUCCESS"
        try {
            $size = (Get-Item $sceneFile).Length
            Write-DiagnosticLog "     Scene file size: $size bytes" "INFO"
        } catch {}
    } else {
        Write-DiagnosticLog "[FAIL] Scene collection NOT found: $sceneFile" "ERROR"
    }
    
    # Check sessions directory
    if (Test-Path $SessionsPath) {
        Write-DiagnosticLog "[OK] Sessions directory found: $SessionsPath" "SUCCESS"
    } else {
        Write-DiagnosticLog "[FAIL] Sessions directory NOT found: $SessionsPath" "ERROR"
    }
    
    # Check if any OBS processes are running
    $obsProcs = Get-Process -Name "obs64" -ErrorAction SilentlyContinue
    if ($obsProcs) {
        Write-DiagnosticLog "[WARN] OBS is currently running (PID: $($obsProcs.Id -join ', '))" "WARNING"
    } else {
        Write-DiagnosticLog "[OK] No OBS processes running (ready for app to start)" "SUCCESS"
    }
    
    # Check port 4455 availability
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 4455)
        $listener.Start()
        $listener.Stop()
        Write-DiagnosticLog "[OK] Port 4455 is available" "SUCCESS"
    } catch {
        Write-DiagnosticLog "[WARN] Port 4455 may be in use: $_" "WARNING"
    }
    
    Write-DiagnosticLog "" "INFO"
    Write-DiagnosticLog "=== END DIAGNOSTIC SUMMARY ===" "INFO"
    Write-DiagnosticLog "Warnings encountered during install: $script:WarningsEncountered" "INFO"
}

# Main installation flow
function Main {
    # Initialize diagnostic logging first
    Initialize-DiagnosticLog
    Write-DiagnosticLog "=== Installation Started ===" "INFO"
    
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  L7S Workflow Capture - OBS Setup" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Log environment details
    Write-DiagnosticLog "Install Path: $InstallPath" "INFO"
    Write-DiagnosticLog "Profile Name: $ProfileName" "INFO"
    Write-DiagnosticLog "Sessions Path: $SessionsPath" "INFO"
    Write-DiagnosticLog "OBS AppData: $OBS_APPDATA" "INFO"
    Write-DiagnosticLog "Force: $Force" "INFO"
    Write-DiagnosticLog "SetAsDefault: $SetAsDefault" "INFO"
    
    # Check for administrator privileges if installing to Program Files
    if ($InstallPath -like "*Program Files*" -and -not (Test-Administrator)) {
        Write-Log "Installing to '$InstallPath' requires administrator privileges" "ERROR"
        Write-Log "Please run this script as Administrator" "ERROR"
        throw "Administrator privileges required for installation to Program Files"
    }
    
    # Check disk space
    if (-not (Test-DiskSpace -Path $InstallPath -RequiredMB $MIN_DISK_SPACE_MB)) {
        Write-Log "Insufficient disk space. At least ${MIN_DISK_SPACE_MB}MB required." "ERROR"
        throw "Insufficient disk space for installation"
    }
    
    # Check if config files are writable (not locked by OneDrive, etc.)
    $globalConfigPath = "$OBS_APPDATA\global.ini"
    if ((Test-Path $globalConfigPath) -and -not (Test-FileWritable $globalConfigPath)) {
        Write-Log "OBS config file is locked by another process (possibly cloud sync)" "ERROR"
        Write-Log "Please close any cloud sync applications and try again" "ERROR"
        throw "Cannot write to OBS configuration files - file is locked"
    }
    
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
        $obsProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        
        # Wait for OBS to fully terminate with timeout
        $maxWaitSeconds = 10
        $waited = 0
        while ($waited -lt $maxWaitSeconds) {
            Start-Sleep -Seconds 1
            $waited++
            $stillRunning = Get-Process -Name "obs64" -ErrorAction SilentlyContinue
            if (-not $stillRunning) {
                Write-Log "OBS stopped successfully" "INFO"
                break
            }
            if ($waited -ge $maxWaitSeconds) {
                Write-Log "OBS is still running after $maxWaitSeconds seconds. Configuration may fail." "WARNING"
            }
        }
    }
    
    # Configure OBS
    Configure-OBSWebSocket
    Configure-OBSProfile -IsNewInstall $isNewInstall
    Configure-OBSSceneCollection -IsNewInstall $isNewInstall
    
    # Only set as default for new installs or if explicitly requested
    Set-OBSDefaultProfile -ForceDefault ($isNewInstall -or $SetAsDefault)
    
    Create-BandaStudyDirectory
    
    # Write diagnostic summary for debugging
    Write-DiagnosticSummary
    
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Installation Complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Log "OBS Studio is configured for screen capture" "SUCCESS"
    Write-Log "WebSocket server: ws://127.0.0.1:4455 (no auth)" "INFO"
    Write-Log "Recording output: $SessionsPath" "INFO"
    Write-Log "Diagnostic log: $DIAGNOSTIC_LOG_PATH" "INFO"
    
    if ($script:EXISTING_OBS_DETECTED -and -not $isNewInstall) {
        Write-Host ""
        Write-Log "NOTE: Your existing OBS configuration was preserved" "INFO"
        Write-Log "The L7S profile was added alongside your existing profiles" "INFO"
    }
    
    Write-Host ""
    
    # Return appropriate exit code
    if ($script:WarningsEncountered) {
        Write-DiagnosticLog "=== Installation Completed with Warnings (exit code 2) ===" "WARNING"
        return 2  # Warnings but OK
    }
    Write-DiagnosticLog "=== Installation Completed Successfully (exit code 0) ===" "SUCCESS"
    return 0  # Success
}

# Run main with error handling
try {
    $result = Main
    exit $result
} catch {
    Write-Log "Installation failed: $_" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1  # Fatal error
}
