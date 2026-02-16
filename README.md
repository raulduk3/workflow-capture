# Workflow Capture & Analysis Platform

A comprehensive workflow automation analysis system consisting of:
1. **Electron Desktop App** - Native screen recording with multi-monitor support
2. **Conversion Pipeline** - Processes video files with metadata extraction
3. **AI Analysis Pipeline** - Integrates with Google Gemini Vision API for workflow insights

## Features

### Screen Capture Application
- **Native Screen Recording** - Uses Electron's desktopCapturer API with FFmpeg
- **Multi-Monitor Support** - Captures all connected displays as a single video
- **Session Management** - Organize recordings with notes and metadata
- **ZIP Export** - Export sessions as portable ZIP archives
- **System Tray** - Runs in the background with quick access controls
- **No External Dependencies** - Everything bundled in the installer

### Analysis Pipeline
- **Video to Frame Extraction** - Process recordings and extract representative frames
- **Gemini Vision Integration** - AI-powered workflow analysis
- **Pattern Detection** - Identify automation opportunities and friction points
- **Report Generation** - Create actionable insights from workflow data

## Development

### Prerequisites
- Node.js 20+
- npm
- Python 3.10+ (for analysis pipeline)
- FFmpeg (for video processing)

### Setup

#### Screen Capture Application
```bash
npm install
npm run build
npm start
```

#### Analysis Pipeline
```bash
cd pipeline
pip install -r requirements.txt
cp .env.example .env
# Edit .env and add your Gemini API key
```

### Configure Google Gemini API
1. Get your API key from [Google AI Studio](https://aistudio.google.com/app/apikey)
2. Create `pipeline/.env` with:
   ```
   GEMINI_API_KEY=your-api-key-here
   ```

### Build Installers
```bash
# Windows
npm run dist:win

# macOS
npm run dist:mac
```

## Deployment

### Network Configuration
The pipeline scripts expect the following environment configuration:
- Source directory for workflow recordings (e.g., network share or local path)
- Output directory for processed results
- Proper file permissions for reading source and writing results

Configure paths via script parameters or environment variables (see individual script headers).

### Releases

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
- **Windows**: `C:\temp\L7SWorkflowCapture\Sessions\<session-id>\`
- **macOS/Linux**: `~/L7SWorkflowCapture/Sessions/<session-id>/`

Each session contains:
- `video.mp4` - Screen recording (or `video.webm` - raw recording)
- `session.json` - Metadata (timestamps, notes, machine name)

## Pipeline Processing

The analysis pipeline processes recordings through these stages:

1. **Source Discovery** - Reads workflow recordings from configured source directory
2. **Video Conversion** - Converts WebM to MP4 (if needed) using FFmpeg
3. **Frame Extraction** - Extracts representative frames from video
4. **Analysis** - Sends frames to Gemini Vision API for workflow analysis
5. **Pattern Detection** - Identifies automation opportunities
6. **CSV Export** - Generates results in tabular format

Configure source/output paths by editing script parameters or setting environment variables.

## System Requirements

### Screen Capture Application
- Windows 10/11 (64-bit)
- macOS 10.15+ (Catalina or later)
- Linux (experimental)
- Screen recording permissions (macOS will prompt on first use)

### Analysis Pipeline
- Windows, macOS, or Linux
- Python 3.10+
- FFmpeg installed and in PATH
- Network access to Gemini API (https://generativelanguage.googleapis.com)

## Privacy & Security

- **No Cloud Recording Storage** - Videos are processed locally. Only AI-generated analysis results are logged.
- **API Key Security** - Store Gemini API keys in `.env` files (never commit to version control)
- **Network Share Access** - Configure appropriate file permissions on network shares
- **.env Files Ignored** - Environment files with credentials are in .gitignore

## License

MIT
