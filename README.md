# L7S Workflow Capture

Screen recording workflow analyzer using OBS Studio. Captures screen recordings with session metadata for workflow analysis.

## Download

Download the latest Windows release from the [Releases](../../releases) page:

- **Windows**: `L7S-Workflow-Analyzer-x.x.x-x64.exe` (NSIS Installer)
- **Windows Portable**: `L7S-Workflow-Analyzer-x.x.x-portable.exe`

## What the Installer Does

### Automatic OBS Setup
The installer automatically:
- Downloads and installs OBS Studio (if not already installed)
- Configures WebSocket server on port 4455 (no authentication)
- Creates an "L7S-ScreenCapture" profile with optimal settings
- Sets up screen capture for all connected monitors
- Configures desktop audio capture

### Existing OBS Installations
If you already have OBS installed:
- Your existing OBS installation is **preserved** (not reinstalled)
- Your existing profiles and scenes are **not modified**
- A new "L7S-ScreenCapture" profile is **added alongside** your profiles
- Your default OBS profile is **not changed**
- Only the WebSocket server setting is enabled

## Development

### Prerequisites
- Node.js 18+
- npm

### Setup
```bash
npm install
npm run build
npm run start
```

### Build Installers
```bash
# Windows
npm run dist:win
```

### Docker Smoke Test (Windows installer)

After building, you can run the installer inside Wine via Docker to ensure it installs cleanly:

```bash
# Example after building to release/...
./docker/test-windows-installer.sh "release/L7S Workflow Analyzer-0.1.2-x64.exe"
```

This runs the NSIS installer silently, verifies the app files were written under `Program Files`, and tears down the container afterward. On macOS/Linux hosts this avoids needing a local Wine install.

## Releases

Releases are automated via GitHub Actions. To create a new release:

```bash
# Tag a new version
git tag v1.0.0
git push origin v1.0.0
```

This will automatically:
1. Build Windows installer (NSIS + portable)
2. Create a GitHub Release with all artifacts

## Architecture

```
src/
├── main/
│   ├── index.ts              # Entry, window, IPC, lifecycle
│   ├── obs-supervisor.ts     # Spawn/monitor/restart OBS process
│   ├── obs-controller.ts     # WebSocket commands to OBS
│   ├── session-manager.ts    # Recording sessions with metadata
│   └── file-manager.ts       # Directory structure, ZIP export
├── renderer/
│   ├── index.html
│   ├── renderer.ts
│   └── styles.css
└── preload.ts
```

## Recording Storage

Sessions are stored in:
- **Windows**: `C:\BandaStudy\Sessions\<session-id>\`

Each session contains:
- `video.mp4` - Screen recording
- `session.json` - Metadata (timestamps, notes, machine name)

## License

MIT
