#!/usr/bin/env python3
"""
Configure OBS Studio for L7S Workflow Analyzer on macOS.
This replicates what the Windows installer does.
Supports multi-monitor setups and auto-scales to fit.
"""

import os
import json
import subprocess
import uuid

# Paths
OBS_APPDATA = os.path.expanduser("~/Library/Application Support/obs-studio")
PROFILE_NAME = "L7S-ScreenCapture"
SESSIONS_PATH = os.path.expanduser("~/BandaStudy/Sessions")


def get_display_info():
    """Get information about all connected displays using Quartz."""
    try:
        # Try using Quartz for accurate display info
        from Quartz import CGDisplayBounds, CGMainDisplayID, CGGetActiveDisplayList
        
        max_displays = 16
        (err, display_ids, display_count) = CGGetActiveDisplayList(max_displays, None, None)
        
        displays = []
        total_width = 0
        max_height = 0
        
        for i, display_id in enumerate(display_ids[:display_count]):
            bounds = CGDisplayBounds(display_id)
            x = int(bounds.origin.x)
            y = int(bounds.origin.y)
            width = int(bounds.size.width)
            height = int(bounds.size.height)
            
            displays.append({
                'id': display_id,
                'index': i,
                'x': x,
                'y': y,
                'width': width,
                'height': height,
                'is_main': display_id == CGMainDisplayID()
            })
            
            # Calculate total canvas size needed
            right_edge = x + width
            if right_edge > total_width:
                total_width = right_edge
            if height > max_height:
                max_height = height
        
        return displays, total_width, max_height
        
    except ImportError:
        # Fallback: use system_profiler
        print("Note: Using fallback display detection")
        result = subprocess.run(
            ['system_profiler', 'SPDisplaysDataType', '-json'],
            capture_output=True, text=True
        )
        data = json.loads(result.stdout)
        
        displays = []
        x_offset = 0
        max_height = 0
        
        for gpu in data.get('SPDisplaysDataType', []):
            for i, display in enumerate(gpu.get('spdisplays_ndrvs', [])):
                res_str = display.get('_spdisplays_resolution', '1920 x 1080')
                # Parse resolution like "2560 x 1440 @ 60.00Hz"
                parts = res_str.split(' x ')
                width = int(parts[0])
                height = int(parts[1].split(' ')[0]) if len(parts) > 1 else 1080
                
                displays.append({
                    'id': i,
                    'index': i,
                    'x': x_offset,
                    'y': 0,
                    'width': width,
                    'height': height,
                    'is_main': i == 0
                })
                
                x_offset += width
                if height > max_height:
                    max_height = height
        
        if not displays:
            # Default fallback
            displays = [{'id': 0, 'index': 0, 'x': 0, 'y': 0, 'width': 1920, 'height': 1080, 'is_main': True}]
            x_offset = 1920
            max_height = 1080
            
        return displays, x_offset, max_height

def create_directories():
    """Create required directories."""
    dirs = [
        os.path.join(OBS_APPDATA, "basic", "profiles", PROFILE_NAME),
        os.path.join(OBS_APPDATA, "basic", "scenes"),
        SESSIONS_PATH
    ]
    for d in dirs:
        os.makedirs(d, exist_ok=True)
        print(f"Created: {d}")

def create_global_ini():
    """Create or update global.ini with WebSocket and profile settings."""
    content = """[General]
Pre19Defaults=false
Pre21Defaults=false
Pre23Defaults=false
Pre24.1Defaults=false
FirstRun=true
LastVersion=536870914
BrowserHWAccel=true
Pre31Migrated=true
MaxLogs=10
InfoIncrement=-1
ProcessPriority=Normal
EnableAutoUpdates=false
MacOSPermissionsDialogLastShown=1
OpenStatsOnStartup=false
RecordWhenStreaming=false
KeepRecordingWhenStreamStops=false
WarnBeforeStartingStream=false
WarnBeforeStoppingStream=false
SnappingEnabled=true
SnapDistance=10.0
SafeMode=false

[Basic]
Profile=L7S-ScreenCapture
ProfileDir=L7S-ScreenCapture
SceneCollection=L7S-ScreenCapture
SceneCollectionFile=L7S-ScreenCapture
ConfigOnNewProfile=true

[BasicWindow]
gridMode=false
PreviewEnabled=true
AlwaysOnTop=false
SceneDuplicationMode=true
SwapScenesMode=true
EditPropertiesMode=false
PreviewProgramMode=false
DocksLocked=false

[PropertiesWindow]
cx=720
cy=580

[Video]
Renderer=OpenGL
DisableOSXVSync=true
ResetOSXVSyncOnExit=true

[OBSWebSocket]
ServerEnabled=true
ServerPort=4455
AuthRequired=false
AlertsEnabled=false
FirstLoad=false
"""
    path = os.path.join(OBS_APPDATA, "global.ini")
    with open(path, 'w') as f:
        f.write(content)
    print(f"Created: {path}")

def create_profile(canvas_width, canvas_height):
    """Create the L7S profile configuration files with proper canvas size."""
    profile_path = os.path.join(OBS_APPDATA, "basic", "profiles", PROFILE_NAME)
    
    # basic.ini - use detected display dimensions for canvas
    basic_ini = f"""[General]
Name={PROFILE_NAME}

[Video]
BaseCX={canvas_width}
BaseCY={canvas_height}
OutputCX={canvas_width}
OutputCY={canvas_height}
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
RecFilePath={SESSIONS_PATH}
RecFileNameWithoutSpace=true
RecTracks=1
RecSplitFileType=Size
RecSplitFileResetTimestamps=false

[SimpleOutput]
FilePath={SESSIONS_PATH}
RecFormat=mp4
RecQuality=Small
RecEncoder=x264
RecRB=false
RecRBTime=20
RecRBSize=512
RecRBPrefix=Replay

[Output]
Mode=Simple
"""
    with open(os.path.join(profile_path, "basic.ini"), 'w') as f:
        f.write(basic_ini)
    print(f"Created: {profile_path}/basic.ini")
    
    # service.json
    service_json = {
        "settings": {
            "key": "",
            "server": "auto"
        },
        "type": "rtmp_common"
    }
    with open(os.path.join(profile_path, "service.json"), 'w') as f:
        json.dump(service_json, f, indent=4)
    print(f"Created: {profile_path}/service.json")
    
    # recordEncoder.json
    with open(os.path.join(profile_path, "recordEncoder.json"), 'w') as f:
        f.write("{}")
    print(f"Created: {profile_path}/recordEncoder.json")

def create_scene_collection(displays, canvas_width, canvas_height):
    """Create the scene collection for screen capture with all displays."""
    scenes_path = os.path.join(OBS_APPDATA, "basic", "scenes")
    
    sources = []
    scene_items = []
    
    # Create a display capture source for each monitor
    for i, display in enumerate(displays):
        source_uuid = str(uuid.uuid4())
        display_name = f"Display {i + 1}" if len(displays) > 1 else "Display Capture"
        
        # Display capture source
        source = {
            "prev_ver": 503316480,
            "name": display_name,
            "uuid": source_uuid,
            "id": "display_capture",
            "versioned_id": "display_capture",
            "settings": {
                "display": display['index'],
                "show_cursor": True,
                "show_hidden_windows": False,
                "hide_obs": True
            },
            "mixers": 0,
            "sync": 0,
            "flags": 0,
            "volume": 1.0,
            "balance": 0.5,
            "enabled": True,
            "muted": False,
            "push-to-mute": False,
            "push-to-mute-delay": 0,
            "push-to-talk": False,
            "push-to-talk-delay": 0,
            "hotkeys": {},
            "deinterlace_mode": 0,
            "deinterlace_field_order": 0,
            "monitoring_type": 0,
            "private_settings": {}
        }
        sources.append(source)
        
        # Scene item - position each display correctly in the canvas
        # Use bounds_type 2 (scale to inner bounds) to fit within canvas
        scene_item = {
            "name": display_name,
            "source_uuid": source_uuid,
            "visible": True,
            "locked": False,
            "rot": 0.0,
            "pos": {"x": float(display['x']), "y": float(display['y'])},
            "scale": {"x": 1.0, "y": 1.0},
            "align": 5,
            "bounds_type": 2,  # Scale to inner bounds - fits content to bounds
            "bounds_align": 0,
            "bounds": {"x": float(display['width']), "y": float(display['height'])},
            "crop_left": 0,
            "crop_top": 0,
            "crop_right": 0,
            "crop_bottom": 0,
            "id": i + 1,
            "group_item_backup": False,
            "scale_filter": "disable",
            "blend_method": "default",
            "blend_type": "normal",
            "show_transition": {"duration": 0},
            "hide_transition": {"duration": 0},
            "private_settings": {}
        }
        scene_items.append(scene_item)
    
    # Add desktop audio capture
    audio_uuid = str(uuid.uuid4())
    audio_source = {
        "prev_ver": 503316480,
        "name": "Desktop Audio",
        "uuid": audio_uuid,
        "id": "coreaudio_output_capture",
        "versioned_id": "coreaudio_output_capture",
        "settings": {
            "device_id": "default"
        },
        "mixers": 255,
        "sync": 0,
        "flags": 0,
        "volume": 1.0,
        "balance": 0.5,
        "enabled": True,
        "muted": False,
        "push-to-mute": False,
        "push-to-mute-delay": 0,
        "push-to-talk": False,
        "push-to-talk-delay": 0,
        "hotkeys": {},
        "deinterlace_mode": 0,
        "deinterlace_field_order": 0,
        "monitoring_type": 0,
        "private_settings": {}
    }
    sources.append(audio_source)
    
    # Create the main scene
    scene_uuid = str(uuid.uuid4())
    main_scene = {
        "name": "L7S Screen Capture",
        "uuid": scene_uuid,
        "id": "scene",
        "versioned_id": "scene",
        "settings": {
            "items": scene_items,
            "id_counter": len(displays) + 1,
            "custom_size": False
        },
        "mixers": 0,
        "sync": 0,
        "flags": 0,
        "volume": 1.0,
        "balance": 0.5,
        "enabled": True,
        "muted": False,
        "push-to-mute": False,
        "push-to-mute-delay": 0,
        "push-to-talk": False,
        "push-to-talk-delay": 0,
        "hotkeys": {},
        "deinterlace_mode": 0,
        "deinterlace_field_order": 0,
        "monitoring_type": 0,
        "private_settings": {}
    }
    sources.append(main_scene)
    
    scene_collection = {
        "current_scene": "L7S Screen Capture",
        "current_program_scene": "L7S Screen Capture",
        "scene_order": [
            {"name": "L7S Screen Capture"}
        ],
        "name": PROFILE_NAME,
        "sources": sources,
        "groups": [],
        "quick_transitions": [],
        "transitions": [],
        "saved_projectors": [],
        "current_transition": "Fade",
        "transition_duration": 300,
        "preview_locked": False,
        "scaling_enabled": False,
        "scaling_level": 0,
        "scaling_off_x": 0.0,
        "scaling_off_y": 0.0,
        "resolution": {
            "x": canvas_width,
            "y": canvas_height
        },
        "version": 1
    }
    
    scene_file = os.path.join(scenes_path, f"{PROFILE_NAME}.json")
    with open(scene_file, 'w') as f:
        json.dump(scene_collection, f, indent=4)
    print(f"Created: {scene_file}")
    print(f"  - {len(displays)} display(s) configured")
    for i, d in enumerate(displays):
        print(f"    Display {i+1}: {d['width']}x{d['height']} at position ({d['x']}, {d['y']})")

def main():
    print("=" * 50)
    print("L7S Workflow Analyzer - OBS Configuration (macOS)")
    print("=" * 50)
    print()
    
    # Detect displays
    print("Detecting displays...")
    displays, canvas_width, canvas_height = get_display_info()
    print(f"Found {len(displays)} display(s)")
    print(f"Total canvas size: {canvas_width}x{canvas_height}")
    print()
    
    create_directories()
    print()
    
    create_global_ini()
    print()
    
    create_profile(canvas_width, canvas_height)
    print()
    
    create_scene_collection(displays, canvas_width, canvas_height)
    print()
    
    print("=" * 50)
    print("Configuration Complete!")
    print("=" * 50)
    print()
    print(f"Profile: {PROFILE_NAME}")
    print(f"Canvas: {canvas_width}x{canvas_height}")
    print(f"Displays: {len(displays)}")
    print(f"WebSocket: ws://127.0.0.1:4455 (no auth)")
    print(f"Recording output: {SESSIONS_PATH}")
    print()
    print("When you open OBS, it will use the L7S-ScreenCapture profile.")
    print("All displays will be captured and fit within the canvas.")

if __name__ == "__main__":
    main()
