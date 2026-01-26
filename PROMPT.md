# l7s-workflow-capture

Initialize an Electron + TypeScript project that captures screen recordings by managing OBS Studio as a child process.

## Architecture

Electron is the **single supervisor**—it launches OBS, controls it via obs-websocket, and terminates it on exit. OBS never runs independently.

```
l7s-workflow-capture/
├── src/
│   ├── main/
│   │   ├── index.ts              # Entry, window, IPC, lifecycle
│   │   ├── obs-supervisor.ts     # Spawn/monitor/restart OBS process
│   │   ├── obs-controller.ts     # WebSocket commands to OBS
│   │   ├── session-manager.ts    # Recording sessions with metadata
│   │   └── file-manager.ts       # Directory structure, ZIP export
│   ├── renderer/
│   │   ├── index.html
│   │   ├── renderer.ts
│   │   └── styles.css
│   └── preload.ts
├── package.json
├── tsconfig.json
└── electron-builder.yml
```

## OBS Supervisor

Manages OBS as a child process using `child_process.spawn()`. Launches OBS with `--minimize-to-tray --disable-updater --multi`. Monitors for unexpected exits and auto-restarts. Terminates OBS gracefully on app quit via `app.on('before-quit')`. Emits events: `obs-started`, `obs-stopped`, `obs-crashed`. OBS path typically `C:\Program Files\obs-studio\bin\64bit\obs64.exe`.

## OBS Controller

Connects to OBS via obs-websocket-js (port 4455, no auth). Retries connection with 2s intervals while OBS initializes. Methods: `startRecording(outputPath)`, `stopRecording()`, `getRecordingStatus()`. Sets output directory per-session via `SetRecordDirectory`. On WebSocket disconnect, notifies supervisor to check OBS health.

## Startup Sequence

1. Electron ready → create window showing "Starting..."
2. Kill any orphaned OBS processes
3. Spawn OBS as child process (hidden)
4. Wait for WebSocket connection (retry up to 10x)
5. Verify OBS ready → enter idle state

## Session Manager

Each recording creates `C:\BandaStudy\Sessions\<uuid>\` containing `video.mp4` and `session.json`:

```json
{"session_id":"uuid","started_at":"ISO","ended_at":"ISO","note":"user text","machine_name":"hostname"}
```

## File Manager

Ensures `C:\BandaStudy\Sessions\` exists. Creates session directories. Exports all sessions to `BandaStudy_<hostname>_<date>.zip` using `archiver`. Opens folders via `shell.openPath()`.

## UI

Minimal 400x300 window. States: Starting (yellow), Idle (gray), Recording (red pulse + timer), Reconnecting (yellow), Error (red + retry). Controls: task note input, Start/Stop button, Open Folder, Export All. Vanilla HTML/CSS/TS, Segoe UI font, no frameworks.

## IPC Channels

`start-recording`, `stop-recording`, `get-status`, `open-sessions-folder`, `export-sessions`, `retry-connection`. Push `system-status` updates to renderer via `onStatusUpdate` callback.

## Dependencies

```json
{
  "dependencies": {
    "obs-websocket-js": "^5.0.0",
    "uuid": "^9.0.0",
    "archiver": "^6.0.0"
  },
  "devDependencies": {
    "electron": "^28.0.0",
    "electron-builder": "^24.0.0",
    "typescript": "^5.0.0",
    "@types/node": "^20.0.0"
  }
}
```

## Build

Portable Windows exe via electron-builder. App ID: `com.layer7.workflowanalyzer`. Single instance lock enforced.

## Constraints

No backend, no auth, no auto-updates, no tray icon, no settings UI. OBS must be pre-installed with WebSocket enabled. All data local. Explicit TypeScript types, async/await, structured logging with prefixes `[Main]`, `[OBS-Supervisor]`, `[OBS-Controller]`, `[Session]`.