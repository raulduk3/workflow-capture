# Workflow Capture - Installer

This directory contains the installer build system for Windows.

## Files

### Windows
- **install-obs.ps1** - PowerShell script that downloads, installs, and configures OBS Studio
- **installer.nsi** - Standalone NSIS installer script (optional, for custom builds)
- **nsis-include.nsh** - NSIS include script used by electron-builder
- **build-installer.bat** - Windows batch script to build everything

## Building the Installer

### Prerequisites

1. **Node.js** (v18+) - https://nodejs.org/
2. **NSIS** (optional, for standalone installer) - https://nsis.sourceforge.io/
   ```
   winget install NSIS.NSIS
   ```

### Build Steps

#### Using electron-builder (Recommended)

```bash
# From project root
npm install
npm run dist:win
```

This creates:
- `release/Workflow Capture-1.0.0-x64.exe` - NSIS installer
- `release/Workflow Capture-1.0.0-portable.exe` - Portable version
- `release/win-unpacked/` - Unpacked application directory

### Docker smoke test (Wine)

Run the Windows installer headlessly inside Wine to ensure it installs cleanly:

```bash
./docker/test-windows-installer.sh "release/Workflow Capture-1.0.0-x64.exe"
```

The script runs the installer silently and verifies files are written under `Program Files` in the Wine prefix.

#### Using build-installer.bat

```batch
cd installer
build-installer.bat
```

## What the Installer Does

### 1. Application Installation
- Installs Workflow Capture to `C:\Program Files\Layer 7 Systems\Workflow Capture`
- Creates Start Menu shortcuts
- Creates optional Desktop shortcut
- Registers uninstaller in Windows

### 2. OBS Studio Setup
The installer automatically:
- Downloads OBS Studio if not installed
- Installs OBS silently
- Configures WebSocket server (port 4455, no authentication)
- Creates an "L7S-ScreenCapture" profile
- Sets up a scene with all monitors captured
- Configures desktop audio capture
- Sets optimal recording settings (MP4, x264, 30fps)

### 3. Directory Setup
- Creates `C:\BandaStudy\Sessions\` for recordings

## OBS Configuration Details

### WebSocket Server
- Enabled on port 4455
- No authentication required
- Allows the app to control OBS programmatically

### Recording Settings
- Format: MP4
- Encoder: x264
- Resolution: Native monitor resolution
- Frame rate: 30 FPS
- Output path: `C:\BandaStudy\Sessions\`

### Scene Configuration
- Automatically detects all connected monitors
- Creates a source for each monitor
- Includes desktop audio capture
- Scene named "L7S Screen Capture"

## Customization

### Changing OBS Version
Edit `install-obs.ps1` and update:
```powershell
$OBS_VERSION = "30.0.2"
```

### Changing Recording Settings
Edit the profile settings in `install-obs.ps1`:
- Video resolution in `Configure-OBSProfile`
- Recording format in `$recordFormatIni`
- Frame rate in the `[Video]` section

### Multi-Monitor Layout
The script automatically arranges monitors based on their Windows display settings. Modify `Configure-OBSSceneCollection` for custom layouts.

## Troubleshooting

### OBS Won't Install
- Ensure you have admin privileges
- Check Windows Defender/antivirus isn't blocking the download
- Try running `install-obs.ps1` manually as Administrator

### WebSocket Connection Failed
- Ensure OBS is running
- Check port 4455 isn't blocked by firewall
- Verify the global.ini has correct WebSocket settings

### No Monitors Captured
- Run OBS manually once to initialize display permissions
- On Windows 10/11, ensure "Graphics capture" permission is granted
- Try running as Administrator

## Uninstallation

The uninstaller:
- Removes the Workflow Capture application
- Removes shortcuts and registry entries
- **Preserves** OBS Studio installation
- **Preserves** recordings in `C:\BandaStudy\`

To fully clean up:
1. Uninstall Workflow Capture from Windows Settings
2. Optionally uninstall OBS Studio separately
3. Manually delete `C:\BandaStudy\` if desired
