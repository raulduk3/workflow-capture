#!/bin/bash
# L7S Workflow Analyzer - macOS OBS Setup Script
# This script installs and configures OBS Studio for screen recording
#
# EXISTING OBS INSTALLATIONS:
# - Will NOT reinstall OBS if already present (unless --force is used)
# - Will NOT modify existing profiles or scene collections
# - ADDS a new "L7S-ScreenCapture" profile alongside existing ones
# - Only enables WebSocket server (non-destructive setting)
# - Does NOT change the default profile

set -e

# Configuration
OBS_VERSION="30.2.3"
OBS_DMG_URL="https://github.com/obsproject/obs-studio/releases/download/${OBS_VERSION}/OBS-Studio-${OBS_VERSION}-macOS-Universal.dmg"
OBS_APP_PATH="/Applications/OBS.app"
OBS_CONFIG_PATH="$HOME/Library/Application Support/obs-studio"
PROFILE_NAME="L7S-ScreenCapture"
SESSIONS_PATH="$HOME/BandaStudy/Sessions"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
FORCE=false
SET_AS_DEFAULT=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --force) FORCE=true ;;
        --set-default) SET_AS_DEFAULT=true ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO") echo -e "${NC}[$timestamp] [INFO] $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] [SUCCESS] $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] [WARNING] $message${NC}" ;;
        "ERROR") echo -e "${RED}[$timestamp] [ERROR] $message${NC}" ;;
    esac
}

check_obs_installed() {
    if [ -d "$OBS_APP_PATH" ]; then
        return 0
    else
        return 1
    fi
}

get_obs_version() {
    if [ -d "$OBS_APP_PATH" ]; then
        /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$OBS_APP_PATH/Contents/Info.plist" 2>/dev/null || echo "Unknown"
    fi
}

check_existing_config() {
    local profiles_path="$OBS_CONFIG_PATH/basic/profiles"
    local scenes_path="$OBS_CONFIG_PATH/basic/scenes"
    
    if [ -d "$profiles_path" ] && [ "$(ls -A $profiles_path 2>/dev/null)" ]; then
        return 0
    fi
    if [ -d "$scenes_path" ] && [ "$(ls -A $scenes_path 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

install_obs() {
    log "INFO" "Downloading OBS Studio $OBS_VERSION..."
    
    local dmg_path="/tmp/obs-studio.dmg"
    
    # Download OBS
    curl -L -o "$dmg_path" "$OBS_DMG_URL"
    log "SUCCESS" "Download complete"
    
    log "INFO" "Installing OBS Studio..."
    
    # Mount DMG
    local mount_point=$(hdiutil attach "$dmg_path" -nobrowse | grep Volumes | awk '{print $3}')
    
    # Copy to Applications
    if [ -d "$OBS_APP_PATH" ]; then
        rm -rf "$OBS_APP_PATH"
    fi
    cp -R "$mount_point/OBS.app" /Applications/
    
    # Unmount DMG
    hdiutil detach "$mount_point" -quiet
    
    # Clean up
    rm -f "$dmg_path"
    
    log "SUCCESS" "OBS Studio installed successfully"
}

configure_websocket() {
    log "INFO" "Configuring OBS WebSocket server..."
    
    # Create config directory if needed
    mkdir -p "$OBS_CONFIG_PATH"
    
    local global_config="$OBS_CONFIG_PATH/global.ini"
    
    # If config exists, preserve it and just update WebSocket section
    if [ -f "$global_config" ]; then
        # Remove existing WebSocket section
        sed -i '' '/^\[OBSWebSocket\]/,/^\[/{ /^\[OBSWebSocket\]/d; /^\[/!d; }' "$global_config" 2>/dev/null || true
    fi
    
    # Append WebSocket configuration
    cat >> "$global_config" << EOF

[OBSWebSocket]
ServerEnabled=true
ServerPort=4455
AuthRequired=false
AlertsEnabled=false
FirstLoad=false
EOF
    
    log "SUCCESS" "WebSocket server configured (port 4455, no auth)"
}

configure_profile() {
    log "INFO" "Creating L7S screen capture profile..."
    
    local profile_path="$OBS_CONFIG_PATH/basic/profiles/$PROFILE_NAME"
    
    mkdir -p "$profile_path"
    
    # Basic profile configuration
    cat > "$profile_path/basic.ini" << EOF
[General]
Name=$PROFILE_NAME

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
RecFilePath=$SESSIONS_PATH
RecFileNameWithoutSpace=true
RecTracks=1

[SimpleOutput]
FilePath=$SESSIONS_PATH
RecFormat=mp4
RecQuality=Small
RecEncoder=x264

[Output]
Mode=Simple
EOF
    
    # Encoder settings
    echo '{}' > "$profile_path/recordEncoder.json"
    
    # Service configuration
    cat > "$profile_path/service.json" << EOF
{
    "settings": {
        "key": "",
        "server": "auto"
    },
    "type": "rtmp_common"
}
EOF
    
    log "SUCCESS" "Profile '$PROFILE_NAME' created"
}

configure_scene_collection() {
    log "INFO" "Creating screen capture scene collection..."
    
    local scenes_path="$OBS_CONFIG_PATH/basic/scenes"
    mkdir -p "$scenes_path"
    
    local scene_file="$scenes_path/$PROFILE_NAME.json"
    
    # Get number of displays
    local display_count=$(system_profiler SPDisplaysDataType | grep -c "Resolution:" || echo "1")
    
    # Generate sources for each display
    local sources='['
    local scene_items='['
    
    for ((i=0; i<display_count; i++)); do
        local monitor_name="Monitor $((i+1))"
        local source_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
        
        # Add source
        if [ $i -gt 0 ]; then
            sources+=','
            scene_items+=','
        fi
        
        sources+="{
            \"name\": \"$monitor_name\",
            \"uuid\": \"$source_uuid\",
            \"id\": \"display_capture\",
            \"versioned_id\": \"display_capture\",
            \"settings\": {
                \"display\": $i,
                \"show_cursor\": true
            },
            \"enabled\": true,
            \"volume\": 1.0
        }"
        
        scene_items+="{
            \"name\": \"$monitor_name\",
            \"source_uuid\": \"$source_uuid\",
            \"visible\": true,
            \"id\": $((i+1))
        }"
    done
    
    # Add audio capture
    local audio_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    sources+=",{
        \"name\": \"Desktop Audio\",
        \"uuid\": \"$audio_uuid\",
        \"id\": \"coreaudio_output_capture\",
        \"versioned_id\": \"coreaudio_output_capture\",
        \"settings\": {
            \"device_id\": \"default\"
        },
        \"enabled\": true,
        \"volume\": 1.0
    }"
    
    # Add main scene
    local scene_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    sources+=",{
        \"name\": \"L7S Screen Capture\",
        \"uuid\": \"$scene_uuid\",
        \"id\": \"scene\",
        \"versioned_id\": \"scene\",
        \"settings\": {
            \"items\": $scene_items]
        },
        \"enabled\": true
    }"
    
    sources+=']'
    
    # Write scene collection
    cat > "$scene_file" << EOF
{
    "current_scene": "L7S Screen Capture",
    "current_program_scene": "L7S Screen Capture",
    "scene_order": [
        { "name": "L7S Screen Capture" }
    ],
    "name": "$PROFILE_NAME",
    "sources": $sources,
    "groups": [],
    "transitions": [],
    "current_transition": "Fade",
    "transition_duration": 300
}
EOF
    
    log "SUCCESS" "Scene collection created with $display_count display(s)"
}

set_default_profile() {
    if [ "$1" != "true" ]; then
        log "INFO" "Skipping default profile change (preserving user's existing default)"
        log "INFO" "The L7S app will select the correct profile when launching OBS"
        return
    fi
    
    log "INFO" "Setting L7S profile as default..."
    
    local global_config="$OBS_CONFIG_PATH/global.ini"
    
    # Update or add Basic section
    if grep -q "^\[Basic\]" "$global_config" 2>/dev/null; then
        # Update existing values
        sed -i '' "s/^Profile=.*/Profile=$PROFILE_NAME/" "$global_config"
        sed -i '' "s/^ProfileDir=.*/ProfileDir=$PROFILE_NAME/" "$global_config"
        sed -i '' "s/^SceneCollection=.*/SceneCollection=$PROFILE_NAME/" "$global_config"
        sed -i '' "s/^SceneCollectionFile=.*/SceneCollectionFile=$PROFILE_NAME/" "$global_config"
    else
        cat >> "$global_config" << EOF

[Basic]
Profile=$PROFILE_NAME
ProfileDir=$PROFILE_NAME
SceneCollection=$PROFILE_NAME
SceneCollectionFile=$PROFILE_NAME
EOF
    fi
    
    log "SUCCESS" "Default profile set to '$PROFILE_NAME'"
}

create_sessions_directory() {
    log "INFO" "Creating BandaStudy sessions directory..."
    
    if [ ! -d "$SESSIONS_PATH" ]; then
        mkdir -p "$SESSIONS_PATH"
        log "SUCCESS" "Created: $SESSIONS_PATH"
    else
        log "INFO" "Directory already exists: $SESSIONS_PATH"
    fi
}

show_existing_warning() {
    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo -e "${YELLOW}  Existing OBS Configuration Detected${NC}"
    echo -e "${YELLOW}============================================${NC}"
    echo ""
    log "INFO" "Your existing OBS profiles and scenes will be PRESERVED"
    log "INFO" "We will ADD a new 'L7S-ScreenCapture' profile for this app"
    log "INFO" "Your default OBS profile will NOT be changed"
    echo ""
}

# Main
main() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  L7S Workflow Analyzer - OBS Setup${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
    
    local is_new_install=false
    
    # Check if OBS is installed
    if check_obs_installed; then
        local version=$(get_obs_version)
        log "INFO" "OBS Studio is already installed (version: $version)"
        
        if check_existing_config; then
            show_existing_warning
        fi
        
        if [ "$FORCE" = true ]; then
            log "WARNING" "Force flag set, reinstalling OBS..."
            install_obs
        else
            log "INFO" "Skipping OBS installation (use --force to reinstall)"
        fi
    else
        log "INFO" "OBS Studio not found, installing..."
        install_obs
        is_new_install=true
    fi
    
    # Kill running OBS instances
    if pgrep -f "OBS" > /dev/null 2>&1; then
        log "WARNING" "Stopping running OBS instances..."
        pkill -f "OBS" || true
        sleep 2
    fi
    
    # Configure OBS
    configure_websocket
    configure_profile
    configure_scene_collection
    
    # Only set as default for new installs or if requested
    if [ "$is_new_install" = true ] || [ "$SET_AS_DEFAULT" = true ]; then
        set_default_profile "true"
    else
        set_default_profile "false"
    fi
    
    create_sessions_directory
    
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    log "SUCCESS" "OBS Studio is configured for screen capture"
    log "INFO" "WebSocket server: ws://127.0.0.1:4455 (no auth)"
    log "INFO" "Recording output: $SESSIONS_PATH"
    
    if [ "$is_new_install" = false ]; then
        echo ""
        log "INFO" "NOTE: Your existing OBS configuration was preserved"
        log "INFO" "The L7S profile was added alongside your existing profiles"
    fi
    
    echo ""
}

main
