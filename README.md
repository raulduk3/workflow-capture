# Workflow Capture

Native screen recording application for workflow capture and analysis. Records all connected screens as MP4 video with session metadata.

## Download

Download the latest Windows release from the [Releases](../../releases) page:

- **Windows**: `Workflow Capture-x.x.x-x64.exe` (NSIS Installer)

## Features

- **Native Screen Recording** - Uses Electron's desktopCapturer API with FFmpeg
- **Multi-Monitor Support** - Captures all connected displays as a single video
- **Session Management** - Organize recordings with notes and metadata
- **ZIP Export** - Export sessions as portable ZIP archives
- **System Tray** - Runs in the background with quick access controls
- **No External Dependencies** - Everything bundled in the installer

## Development

### Prerequisites
- Node.js 20+
- npm

### Setup
```bash
npm install
npm run build
npm start
```

### Build Installers
```bash
# Windows
npm run dist:win

# macOS
npm run dist:mac
```

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
│   ├── native-recorder.ts    # Screen capture with desktopCapturer + FFmpeg
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
- **Windows**: `%TEMP%\L7SWorkflowCapture\Sessions\<session-id>\`
- **macOS/Linux**: `~/L7SWorkflowCapture/Sessions/<session-id>/`

Each session contains:
- `video.mp4` - Screen recording
- `session.json` - Metadata (timestamps, notes, machine name)

## System Requirements

- Windows 10/11 (64-bit)
- macOS 10.15+ (Catalina or later)
- Screen recording permissions (macOS will prompt on first use)

## License

MIT
