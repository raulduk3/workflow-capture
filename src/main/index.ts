import { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import { NativeRecorder } from './native-recorder';
import { SessionManager } from './session-manager';
import { FileManager } from './file-manager';
import { SystemState, SystemStatus, APP_CONSTANTS, ExternalConfig, CONFIG_DEFAULTS } from '../shared/types';

// =============================================================================
// Production Log File
// =============================================================================
// Write logs to a file so errors can be diagnosed on deployed Windows machines
// Log location: C:\temp\L7SWorkflowCapture\app.log (Windows) or /tmp/L7SWorkflowCapture/app.log
const LOG_MAX_SIZE = 2 * 1024 * 1024; // 2MB max log file size
let logFilePath: string | null = null;

function initLogFile(): void {
  try {
    const basePath = process.platform === 'win32' ? 'C:\\temp' : '/tmp';
    const logDir = path.join(basePath, APP_CONSTANTS.APP_NAME);
    // Ensure directory exists (sync is fine here - runs once at startup)
    if (!fs.existsSync(logDir)) {
      fs.mkdirSync(logDir, { recursive: true });
    }
    logFilePath = path.join(logDir, 'app.log');
    // Rotate log if too large
    try {
      const stats = fs.statSync(logFilePath);
      if (stats.size > LOG_MAX_SIZE) {
        const rotatedPath = logFilePath + '.old';
        try { fs.unlinkSync(rotatedPath); } catch {}
        fs.renameSync(logFilePath, rotatedPath);
      }
    } catch {}
    // Write startup marker
    const startMsg = `\n${'='.repeat(60)}\n[${new Date().toISOString()}] Application starting (v${app.getVersion()})\n${'='.repeat(60)}\n`;
    fs.appendFileSync(logFilePath, startMsg);
  } catch (err) {
    // Can't write logs - continue without file logging
    console.error('Failed to initialize log file:', err);
    logFilePath = null;
  }
}

function writeToLogFile(message: string): void {
  if (!logFilePath) return;
  try {
    const timestamp = new Date().toISOString();
    fs.appendFileSync(logFilePath, `[${timestamp}] ${message}\n`);
  } catch {
    // Silently ignore log write failures
  }
}

// Global error handlers
process.on('uncaughtException', (error) => {
  const msg = `[Main] Uncaught Exception: ${error.message}\n${error.stack || ''}`;
  console.error(msg);
  writeToLogFile(msg);
});

process.on('unhandledRejection', (reason, promise) => {
  const msg = `[Main] Unhandled Rejection: ${reason}`;
  console.error('[Main] Unhandled Rejection at:', promise, 'reason:', reason);
  writeToLogFile(msg);
});

// Re-export types from shared for backwards compatibility
export type { SystemState, SystemStatus } from '../shared/types';

// Runtime configuration (loaded from config.json or defaults)
let runtimeConfig: Required<ExternalConfig> = { ...CONFIG_DEFAULTS };

/**
 * Load external configuration from config.json
 * Config file location: C:\temp\L7SWorkflowCapture\config.json (Windows)
 * This allows changing settings across clients without reinstalling
 */
function loadExternalConfig(): void {
  const basePath = process.platform === 'win32' ? 'C:\\temp' : '/tmp';
  const configPath = path.join(basePath, APP_CONSTANTS.APP_NAME, APP_CONSTANTS.CONFIG_FILENAME);
  
  log(`Loading config - Platform: ${process.platform}, Config path: ${configPath}`);
  
  try {
    const configExists = fs.existsSync(configPath);
    log(`Config file exists: ${configExists}`);
    
    if (configExists) {
      let configData = fs.readFileSync(configPath, 'utf-8');
      
      // ISSUE FIX: Handle BOM more robustly - handle UTF-8 BOM (0xFEFF) and other encodings
      // Windows PowerShell -Encoding UTF8 adds BOM; trim it if present
      configData = configData.replace(/^\uFEFF/, '');
      
      log(`Config file loaded (${configData.length} chars after BOM strip)`);
      
      // ISSUE FIX: Wrap JSON.parse in try-catch to handle invalid JSON gracefully
      let externalConfig: ExternalConfig;
      try {
        externalConfig = JSON.parse(configData);
      } catch (parseErr) {
        log(`Warning: Invalid JSON in config file, using defaults: ${parseErr instanceof Error ? parseErr.message : String(parseErr)}`);
        externalConfig = {};
      }
      
      // Merge with defaults, validating values
      // ISSUE FIX: Validate config values are within reasonable ranges
      if (typeof externalConfig.maxRecordingMinutes === 'number' && externalConfig.maxRecordingMinutes > 0) {
        // Clamp to 1 minute - 8 hours (reasonable for workflow capture)
        const clamped = Math.max(1, Math.min(480, Math.floor(externalConfig.maxRecordingMinutes)));
        if (clamped !== externalConfig.maxRecordingMinutes) {
          log(`Warning: maxRecordingMinutes ${externalConfig.maxRecordingMinutes} outside range [1-480], clamped to ${clamped}`);
        }
        runtimeConfig.maxRecordingMinutes = clamped;
        log(`Applied maxRecordingMinutes: ${runtimeConfig.maxRecordingMinutes}`);
      }
      if (typeof externalConfig.videoBitrateMbps === 'number' && externalConfig.videoBitrateMbps > 0) {
        // Clamp to 1-50 Mbps (reasonable for H.265 or VP9)
        const clamped = Math.max(1, Math.min(50, Math.floor(externalConfig.videoBitrateMbps)));
        if (clamped !== externalConfig.videoBitrateMbps) {
          log(`Warning: videoBitrateMbps ${externalConfig.videoBitrateMbps} outside range [1-50], clamped to ${clamped}`);
        }
        runtimeConfig.videoBitrateMbps = clamped;
        log(`Applied videoBitrateMbps: ${runtimeConfig.videoBitrateMbps}`);
      }
      
      log(`Loaded external config from ${configPath}:`);
      log(`  - Max recording: ${runtimeConfig.maxRecordingMinutes} minutes`);
      log(`  - Video bitrate: ${runtimeConfig.videoBitrateMbps} Mbps`);
    } else {
      log(`No external config found at ${configPath}, using defaults`);
      log(`  - Max recording: ${runtimeConfig.maxRecordingMinutes} minutes`);
    }
  } catch (error) {
    log(`Warning: Failed to load config from ${configPath}: ${error}`);
    log(`Using default configuration`);
  }
}

/**
 * Get the max recording duration in milliseconds (from config or default)
 */
function getMaxRecordingDurationMs(): number {
  return runtimeConfig.maxRecordingMinutes * 60 * 1000;
}

/**
 * Get the video bitrate in bits per second (from config or default)
 */
function getVideoBitrate(): number {
  return runtimeConfig.videoBitrateMbps * 1_000_000;
}

// Globals
let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let nativeRecorder: NativeRecorder | null = null;
let sessionManager: SessionManager | null = null;
let fileManager: FileManager | null = null;
let recordingStartTime: number | null = null;
let recordingTimer: NodeJS.Timeout | null = null;
let maxDurationTimer: NodeJS.Timeout | null = null;
// ISSUE FIX: Track recording config at time of recording start (Issue 8)
let recordingMaxDurationMs: number = 0;
let recordingVideoBitrate: number = 0;
let isQuitting = false;
let normalTrayIcon: Electron.NativeImage | null = null;
let pauseTrayIcon: Electron.NativeImage | null = null;
// ISSUE FIX: Single source of truth for recording state (Issue 14)
let isRecordingState = false;
// Concurrency guard for toggleRecording
let isToggling = false;

function log(message: string): void {
  console.log(`[Main] ${message}`);
  writeToLogFile(`[Main] ${message}`);
}

/**
 * Show and focus the main window, restoring it if minimized
 */
function showAndFocusWindow(): void {
  if (!mainWindow || mainWindow.isDestroyed()) {
    createWindow();
    return;
  }
  
  if (mainWindow.isMinimized()) {
    mainWindow.restore();
  }
  mainWindow.show();
  mainWindow.focus();
  log('Window shown and focused');
}

function sendStatus(status: SystemStatus): void {
  // Track current state for tray menu
  currentSystemState = status.state;
  
  // Log error states to file for production debugging
  if (status.state === 'error') {
    log(`ERROR STATE: message="${status.message}", error="${status.error || '(none)'}"`);
  }
  
  if (mainWindow && !mainWindow.isDestroyed()) {
    // Ensure webContents is ready before sending
    if (mainWindow.webContents.isLoading()) {
      mainWindow.webContents.once('did-finish-load', () => {
        mainWindow?.webContents.send('system-status', status);
      });
    } else {
      mainWindow.webContents.send('system-status', status);
    }
  }
  
  // Update tray to reflect new state
  updateTrayMenu();
}

function sendRecordingSavedNotification(outputPath: string): void {
  if (mainWindow && !mainWindow.isDestroyed()) {
    // Extract just the filename from the full path
    const filename = path.basename(outputPath);
    
    if (mainWindow.webContents.isLoading()) {
      mainWindow.webContents.once('did-finish-load', () => {
        mainWindow?.webContents.send('recording-saved', filename);
      });
    } else {
      mainWindow.webContents.send('recording-saved', filename);
    }
  }
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 400,
    height: 320,
    resizable: false,
    maximizable: false,
    skipTaskbar: false,
    alwaysOnTop: false,
    show: true,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'Workflow Capture',
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  mainWindow.setMenu(null);

  // Ensure window is shown and focused on startup
  mainWindow.once('ready-to-show', () => {
    mainWindow?.show();
    mainWindow?.focus();
  });

  // Handle renderer process crash
  mainWindow.webContents.on('render-process-gone', (event, details) => {
    log(`Renderer process gone: ${details.reason}`);
    if (details.reason === 'crashed' || details.reason === 'killed') {
      // Reset recording state if renderer crashes during recording
      if (isRecordingState) {
        stopRecordingTimer();
        isRecordingState = false;
        nativeRecorder?.reset();
        sessionManager?.endCurrentSession();
      }
      currentSystemState = 'error';
      updateTrayMenu();
    }
  });

  // Handle unresponsive renderer
  mainWindow.webContents.on('unresponsive', () => {
    log('Renderer became unresponsive');
  });

  mainWindow.webContents.on('responsive', () => {
    log('Renderer became responsive again');
  });

  // Close behavior: minimize while recording (stays in taskbar), hide to tray when idle
  mainWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      
      // ISSUE FIX: Single source of truth - use isRecordingState (Issue 14)
      if (isRecordingState) {
        // While recording: minimize (stays visible in taskbar)
        mainWindow?.minimize();
        log('Window minimized - recording continues, visible in taskbar');
      } else {
        // While idle: hide to tray
        mainWindow?.hide();
        log('Window hidden to tray');
      }
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  log('Window created');
}

// Track current system state for tray menu
let currentSystemState: SystemState = 'starting';

function updateTrayMenu(): void {
  if (!tray) return;
  
  // ISSUE FIX: Use single source of truth for recording state (Issue 14)
  const isProcessing = currentSystemState === 'processing';
  
  const contextMenu = Menu.buildFromTemplate([
    { 
      label: isProcessing ? 'Saving...' : (isRecordingState ? 'Stop Recording' : 'Start Recording'),
      enabled: !isProcessing, // Disable menu item while processing
      click: async () => {
        await toggleRecording();
      }
    },
    { 
      label: 'Open Sessions Folder', 
      click: async () => {
        if (fileManager) {
          await fileManager.openSessionsFolder();
        }
      }
    },
    { type: 'separator' },
    { 
      label: 'Quit', 
      enabled: !isRecordingState && !isProcessing, // Disable quit while recording or processing
      click: () => {
        app.quit();
      }
    }
  ]);
  
  const tooltip = isProcessing 
    ? 'Workflow Capture - Saving...'
    : isRecordingState 
      ? 'Workflow Capture - Recording (Click to stop)' 
      : 'Workflow Capture (Click to start recording)';
  tray.setToolTip(tooltip);
  tray.setContextMenu(contextMenu);
}

/**
 * Toggle recording state - start if idle, stop if recording
 * Called by tray icon click and tray menu
 */
async function toggleRecording(): Promise<void> {
  if (isToggling) {
    log('Toggle already in progress, ignoring');
    return;
  }
  isToggling = true;

  try {
    const isProcessing = currentSystemState === 'processing';

    if (isProcessing) {
      // Currently saving, ignore
      return;
    }

    if (!nativeRecorder || !mainWindow || !sessionManager) {
      log('Cannot toggle recording: system not initialized');
      return;
    }

    if (isRecordingState) {
      // Stop recording
      let outputPath: string | null = null;
      try {
        stopRecordingTimer();
        isRecordingState = false;
        currentSystemState = 'processing';
        updateTrayMenu();
        updateTrayIcon();
        sendStatus({ state: 'processing', message: 'Saving...' });

        outputPath = await nativeRecorder.stopRecording(mainWindow);
        await sessionManager.endCurrentSession();

        log(`Recording stopped, saved to: ${outputPath}`);
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'Unknown error';
        log(`Failed to stop recording: ${errorMessage}`);
      }

      currentSystemState = 'idle';
      updateTrayMenu();
      updateTrayIcon();
      sendStatus({ state: 'idle', message: 'Ready' });

      if (outputPath) {
        sendRecordingSavedNotification(outputPath);
      }
    } else {
      // Start recording with empty note (quick capture from tray/shortcut)
      try {
        // ISSUE FIX: Store recording config at start time (Issue 8)
        recordingMaxDurationMs = runtimeConfig.maxRecordingMinutes * 60 * 1000;
        recordingVideoBitrate = runtimeConfig.videoBitrateMbps * 1_000_000;

        // Set recording state BEFORE starting capture to prevent window hiding
        isRecordingState = true;
        currentSystemState = 'recording';
        updateTrayMenu();
        updateTrayIcon();

        const recordingPath = await sessionManager.startSession('');
        nativeRecorder.setOutputPath(recordingPath);
        await nativeRecorder.startRecording(mainWindow, recordingVideoBitrate);

        startRecordingTimer();
        sendStatus({ state: 'recording', message: 'Recording', recordingDuration: 0 });

        log(`Recording started: ${recordingPath}`);
      } catch (error) {
        // Reset state on failure
        isRecordingState = false;
        currentSystemState = 'idle';
        updateTrayMenu();
        updateTrayIcon();
        const errorMessage = error instanceof Error ? error.message : 'Unknown error';
        log(`Failed to start recording: ${errorMessage}`);
        sendStatus({ state: 'error', message: 'Failed to start recording', error: errorMessage });
      }
    }
  } finally {
    isToggling = false;
  }
}

function loadTrayIcons(): void {
  // Load normal icon
  let iconPath: string;
  let pauseIconPath: string;
  
  if (app.isPackaged) {
    // In packaged app, use resources directory
    iconPath = path.join(process.resourcesPath, 'icon.ico');
    pauseIconPath = path.join(process.resourcesPath, 'icon-pause.ico');
  } else {
    // In development, use build directory
    iconPath = path.join(__dirname, '..', '..', 'build', 'icon.ico');
    pauseIconPath = path.join(__dirname, '..', '..', 'build', 'icon-pause.ico');
  }
  
  // Load normal icon
  if (fs.existsSync(iconPath)) {
    normalTrayIcon = nativeImage.createFromPath(iconPath);
    normalTrayIcon = normalTrayIcon.resize({ width: 16, height: 16 });
  } else {
    log(`Icon not found at ${iconPath}, using fallback`);
    const size = 16;
    const canvas = Buffer.alloc(size * size * 4);
    for (let i = 0; i < size * size; i++) {
      canvas[i * 4] = 74;      // R
      canvas[i * 4 + 1] = 158; // G  
      canvas[i * 4 + 2] = 255; // B
      canvas[i * 4 + 3] = 255; // A
    }
    normalTrayIcon = nativeImage.createFromBuffer(canvas, { width: size, height: size });
  }
  
  // Load pause icon
  if (fs.existsSync(pauseIconPath)) {
    pauseTrayIcon = nativeImage.createFromPath(pauseIconPath);
    pauseTrayIcon = pauseTrayIcon.resize({ width: 16, height: 16 });
  } else {
    log(`Pause icon not found at ${pauseIconPath}, using fallback`);
    // Fallback: create a red icon for recording state
    const size = 16;
    const canvas = Buffer.alloc(size * size * 4);
    for (let i = 0; i < size * size; i++) {
      canvas[i * 4] = 255;     // R
      canvas[i * 4 + 1] = 68;  // G  
      canvas[i * 4 + 2] = 68;  // B
      canvas[i * 4 + 3] = 255; // A
    }
    pauseTrayIcon = nativeImage.createFromBuffer(canvas, { width: size, height: size });
  }
}

function updateTrayIcon(): void {
  if (!tray) return;
  
  // ISSUE FIX: Use single source of truth for recording state (Issue 14)
  if (isRecordingState && pauseTrayIcon) {
    tray.setImage(pauseTrayIcon);
  } else if (normalTrayIcon) {
    tray.setImage(normalTrayIcon);
  }
  
  // Also update desktop shortcut icon
  updateDesktopShortcutIcon(isRecordingState);
}

/**
 * Update the desktop RECORD shortcut icon based on recording state
 * Uses Windows shell notification to force immediate icon refresh
 */
function updateDesktopShortcutIcon(isRecording: boolean): void {
  // Only on Windows
  if (process.platform !== 'win32') return;

  // ISSUE FIX: Use async operations to not block main thread (Issue 15)
  (async () => {
    try {
      const desktopPath = app.getPath('desktop');
      const shortcutPath = path.join(desktopPath, 'RECORD.lnk');
      
      // Check if shortcut exists
      if (!fs.existsSync(shortcutPath)) {
        return;
      }
      
      // Determine which icon to use
      let iconPath: string;
      if (app.isPackaged) {
        iconPath = isRecording 
          ? path.join(process.resourcesPath, 'icon-pause.ico')
          : path.join(process.resourcesPath, 'icon.ico');
      } else {
        iconPath = isRecording
          ? path.join(__dirname, '..', '..', 'build', 'icon-pause.ico')
          : path.join(__dirname, '..', '..', 'build', 'icon.ico');
      }
      
      // Use Electron's shell.writeShortcutLink to update the shortcut
      const { shell } = require('electron');
      const shortcutDetails = shell.readShortcutLink(shortcutPath);
      
      shell.writeShortcutLink(shortcutPath, 'update', {
        ...shortcutDetails,
        icon: iconPath,
        iconIndex: 0
      });
      
      // Force Windows to refresh the desktop icon cache immediately
      // Use ie4uinit which is the fastest method for icon refresh
      const { execFile } = require('child_process');
      try {
        await new Promise<void>((resolve, reject) => {
          execFile('ie4uinit.exe', ['-show'], { windowsHide: true }, (error: Error | null) => {
            if (error) {
              reject(error);
            } else {
              resolve();
            }
          });
        });
      } catch (execError) {
        // Fallback: touch the shortcut file to trigger refresh
        try {
          const now = new Date();
          await fs.promises.utimes(shortcutPath, now, now);
          console.log(`[Icon] Fallback: touched shortcut to trigger refresh`);
        } catch (touchErr) {
          console.error(`[Icon] Failed to refresh icon:`, touchErr);
        }
      }
      
      log(`Desktop shortcut icon updated: ${isRecording ? 'pause' : 'normal'}`);
    } catch (error) {
      // Silently fail - shortcut icon update is not critical
      log(`Failed to update desktop shortcut icon: ${error}`);
    }
  })().catch(err => {
    log(`Icon update background task error: ${err}`);
  });
}

function createTray(): void {
  // Load both icons
  loadTrayIcons();
  
  if (!normalTrayIcon) {
    log('Failed to load tray icon');
    return;
  }
  
  tray = new Tray(normalTrayIcon);
  
  updateTrayMenu();
  
  tray.setToolTip('Workflow Capture');
  
  // Click on tray icon - show/restore the window (standard Windows behavior)
  tray.on('click', () => {
    showAndFocusWindow();
  });
  
  // Double-click on tray icon - toggle recording
  tray.on('double-click', async () => {
    await toggleRecording();
  });
  
  log('Tray created');
}

async function initialize(): Promise<void> {
  sendStatus({ state: 'starting', message: 'Initializing...' });

  try {
    // Initialize file manager
    log('Initializing file manager...');
    fileManager = new FileManager();
    await fileManager.ensureSessionsDirectory();
    log('File manager initialized');

    // ISSUE FIX: Clean up stale .tmp files on startup (Issue 13) - Use async to not block startup
    log('Cleaning up stale temporary files...');
    (async () => {
      try {
        const sessionsPath = fileManager!.getSessionsPath();
        const files = await fs.promises.readdir(sessionsPath);
        const staleCutoff = Date.now() - (30 * 60 * 1000); // 30 minutes
        
        for (const file of files) {
          if (file.endsWith('.webm.tmp')) {
            const filePath = path.join(sessionsPath, file);
            try {
              const stats = await fs.promises.stat(filePath);
              if (stats.mtimeMs < staleCutoff) {
                await fs.promises.unlink(filePath);
                log(`Cleaned up stale temp file: ${file}`);
              }
            } catch (err) {
              log(`Warning: Could not clean up ${file}: ${err}`);
            }
          }
        }
      } catch (err) {
        log(`Non-critical: Stale file cleanup skipped: ${err}`);
      }
    })().catch(err => {
      log(`Stale file cleanup error: ${err}`);
    });
    // Don't await this - let it run in background

    // Initialize session manager
    log('Initializing session manager...');
    sessionManager = new SessionManager(fileManager);
    log('Session manager initialized');

    // Initialize native recorder
    log('Initializing native recorder...');
    nativeRecorder = new NativeRecorder();
    log('Native recorder initialized');

    sendStatus({ state: 'idle', message: 'Ready' });
    log('System ready');
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    log(`Initialization error: ${errorMessage}`);
    sendStatus({ state: 'error', message: 'Initialization failed', error: errorMessage });
  }
}

function startRecordingTimer(): void {
  recordingStartTime = Date.now();
  recordingTimer = setInterval(() => {
    if (recordingStartTime) {
      const duration = Math.floor((Date.now() - recordingStartTime) / 1000);
      sendStatus({ state: 'recording', message: 'Recording', recordingDuration: duration });
    }
  }, APP_CONSTANTS.TIMER_INTERVAL_MS);
  
  // ISSUE FIX: Use recording config stored at start time (Issue 8)
  log(`Setting up max duration timer: ${recordingMaxDurationMs}ms (${recordingMaxDurationMs / 60 / 1000} minutes)`);
  maxDurationTimer = setTimeout(async () => {
    log(`Max recording duration reached, auto-stopping...`);
    await autoStopRecording();
  }, recordingMaxDurationMs);
}

function stopRecordingTimer(): void {
  if (recordingTimer) {
    clearInterval(recordingTimer);
    recordingTimer = null;
  }
  if (maxDurationTimer) {
    clearTimeout(maxDurationTimer);
    maxDurationTimer = null;
  }
  recordingStartTime = null;
}

/**
 * Auto-stop recording when max duration is reached
 * This is called by the max duration timer
 */
async function autoStopRecording(): Promise<void> {
  if (!nativeRecorder || !mainWindow || !sessionManager) {
    log('Cannot auto-stop: system not initialized');
    return;
  }
  
  // ISSUE FIX: Use recording state flag (Issue 14)
  if (!isRecordingState) {
    log('Auto-stop called but not recording');
    return;
  }
  
  try {
    stopRecordingTimer();
    isRecordingState = false;
    currentSystemState = 'processing';
    updateTrayMenu();
    updateTrayIcon();
    
    // Show window immediately with processing state
    mainWindow.show();
    mainWindow.focus();
    sendStatus({ state: 'processing', message: 'Max time reached. Saving...' });
    
    const outputPath = await nativeRecorder.stopRecording(mainWindow);
    await sessionManager.endCurrentSession();
    
    log(`Auto-stopped recording saved to: ${outputPath}`);
    
    currentSystemState = 'idle';
    updateTrayMenu();
    updateTrayIcon();
    sendStatus({ state: 'idle', message: 'Ready' });
    
    // Show toast notification with saved filename
    sendRecordingSavedNotification(outputPath);
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    log(`Failed to auto-stop recording: ${errorMessage}`);
    isRecordingState = false;
    currentSystemState = 'idle';
    updateTrayMenu();
    updateTrayIcon();
    sendStatus({ state: 'idle', message: 'Ready' });
  }
}

function setupIpcHandlers(): void {
  ipcMain.handle('start-recording', async (_event, note: string) => {
    try {
      if (!sessionManager || !nativeRecorder || !mainWindow) {
        throw new Error('System not initialized');
      }

      // ISSUE FIX: Verify disk space before recording (Issue 6)
      if (!fileManager) {
        throw new Error('File manager not initialized');
      }
      
      const hasDiskSpace = await fileManager.verifyMinimumDiskSpace(50); // 50MB minimum
      if (!hasDiskSpace) {
        throw new Error('Insufficient disk space to start recording (need 50MB)');
      }

      // ISSUE FIX: Store recording config at start time (Issue 8)
      recordingMaxDurationMs = runtimeConfig.maxRecordingMinutes * 60 * 1000;
      recordingVideoBitrate = runtimeConfig.videoBitrateMbps * 1_000_000;

      // Set recording state BEFORE starting capture to prevent window hiding
      // This ensures the close handler knows we're in recording mode during capture setup
      isRecordingState = true;
      currentSystemState = 'recording';
      updateTrayMenu();
      updateTrayIcon();

      // Start session and get the recording path (includes metadata in filename)
      const recordingPath = await sessionManager.startSession(note);
      
      // Set full recording path
      nativeRecorder.setOutputPath(recordingPath);
      
      // Start recording - pass video bitrate from stored config
      await nativeRecorder.startRecording(mainWindow, recordingVideoBitrate);
      
      startRecordingTimer();
      sendStatus({ state: 'recording', message: 'Recording', recordingDuration: 0 });
      
      // Keep window visible during recording (user started from UI)
      if (!mainWindow.isVisible()) {
        mainWindow.show();
      }
      
      log(`Recording started: ${recordingPath}`);
      return { success: true, sessionId: recordingPath };
    } catch (error) {
      // Reset state on failure
      isRecordingState = false;
      currentSystemState = 'idle';
      updateTrayMenu();
      updateTrayIcon();
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to start recording: ${errorMessage}`);
      return { success: false, error: errorMessage };
    }
  });

  ipcMain.handle('stop-recording', async () => {
    try {
      if (!sessionManager || !nativeRecorder || !mainWindow) {
        throw new Error('System not initialized');
      }

      // Stop the timer immediately so user sees feedback
      stopRecordingTimer();
      
      // Update UI to processing state
      isRecordingState = false;
      currentSystemState = 'processing';
      updateTrayMenu();
      updateTrayIcon();
      sendStatus({ state: 'processing', message: 'Processing video...' });

      // Process recording (conversion happens in background while UI is responsive)
      const outputPath = await nativeRecorder.stopRecording(mainWindow);
      
      currentSystemState = 'idle';
      updateTrayMenu();
      updateTrayIcon();
      
      sessionManager.endCurrentSession();
      sendStatus({ state: 'idle', message: 'Ready' });
      
      // Show toast notification with saved filename
      sendRecordingSavedNotification(outputPath);
      
      log(`Recording stopped, saved to: ${outputPath}`);
      return { success: true, path: outputPath };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to stop recording: ${errorMessage}`);
      // Reset to idle state on error so user can try again
      isRecordingState = false;
      currentSystemState = 'idle';
      sendStatus({ state: 'idle', message: 'Ready' });
      // Update tray to show idle state
      updateTrayMenu();
      updateTrayIcon();
      return { success: false, error: errorMessage };
    }
  });

  ipcMain.handle('get-status', async () => {
    const stateMessages: Record<SystemState, string> = {
      starting: 'Starting...',
      idle: 'Ready',
      recording: 'Recording',
      processing: 'Saving...',
      error: 'Error',
    };
    return { state: currentSystemState, message: stateMessages[currentSystemState] };
  });

  ipcMain.handle('open-sessions-folder', async () => {
    try {
      if (!fileManager) {
        throw new Error('File manager not initialized');
      }
      await fileManager.openSessionsFolder();
      return { success: true };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      return { success: false, error: errorMessage };
    }
  });

  // Handle renderer reporting that capture setup failed (e.g. getUserMedia denied)
  ipcMain.handle('capture-start-failed', async (_event, error: string) => {
    // Ensure error message is never empty
    const errorMsg = (typeof error === 'string' && error.trim()) ? error : 'Screen capture failed - unknown reason';
    log(`Renderer reported capture start failure: ${errorMsg}`);
    if (isRecordingState) {
      stopRecordingTimer();
      isRecordingState = false;
      currentSystemState = 'idle';
      nativeRecorder?.reset();
      sessionManager?.endCurrentSession();
      updateTrayMenu();
      updateTrayIcon();
      sendStatus({ state: 'error', message: 'Capture failed', error: errorMsg });
    }
  });

  // Async path validation helper
  // ISSUE FIX: Improved path traversal validation using path.relative()
  async function validatePathWithinDirectory(filePath: string, allowedDir: string, allowedExtensions: string[]): Promise<void> {
    const resolvedFile = path.resolve(filePath);
    const resolvedDir = path.resolve(allowedDir);

    // Resolve symlinks for the directory (must exist)
    let realDir: string;
    try {
      realDir = await fs.promises.realpath(resolvedDir);
    } catch (err) {
      throw new Error(`Directory does not exist: ${err}`);
    }

    // For file: try to resolve real path if it exists, otherwise validate using relative path
    let realFile: string;
    try {
      realFile = await fs.promises.realpath(resolvedFile);
    } catch (err) {
      // File doesn't exist yet, validate using path.relative()
      // If relative path starts with .., it's outside the allowed directory
      const relativePath = path.relative(realDir, resolvedFile);
      if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
        throw new Error(`Path is outside allowed directory: ${filePath}`);
      }
      realFile = resolvedFile;
    }

    // Verify the real file path is within the real directory
    const relativePath = path.relative(realDir, realFile);
    if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
      throw new Error(`Path is outside allowed directory: ${filePath}`);
    }

    // Validate file extension
    const hasValidExtension = allowedExtensions.some(ext => realFile.endsWith(ext));
    if (!hasValidExtension) {
      throw new Error(`Invalid file extension. Allowed: ${allowedExtensions.join(', ')}`);
    }
  }

  // Handle recording data from renderer
  // Note: For large recordings, this can receive hundreds of MB of data
  ipcMain.handle('save-recording-chunk', async (_event, chunk: ArrayBuffer, outputPath: string) => {
    try {
      // ISSUE FIX: Validate that outputPath is within the allowed sessions directory (Issue 2)
      if (!fileManager) {
        throw new Error('File manager not initialized');
      }
      
      const sessionsPath = fileManager.getSessionsPath();
      await validatePathWithinDirectory(outputPath, sessionsPath, ['.webm', '.webm.tmp']);

      log(`Saving recording to ${outputPath} (${(chunk.byteLength / 1024 / 1024).toFixed(2)} MB)`);
      await fs.promises.writeFile(outputPath, Buffer.from(chunk));
      log(`Recording saved successfully`);
      return { success: true };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to save recording: ${errorMessage}`);
      return { success: false, error: errorMessage };
    }
  });

  // Handle incremental chunk appends - writes each chunk to a .webm.tmp file
  ipcMain.handle('append-recording-chunk', async (_event, chunk: ArrayBuffer, outputPath: string) => {
    try {
      if (!fileManager) {
        throw new Error('File manager not initialized');
      }
      
      const sessionsPath = fileManager.getSessionsPath();
      const tmpPath = outputPath + '.tmp';
      await validatePathWithinDirectory(tmpPath, sessionsPath, ['.webm.tmp']);

      // Append chunk to temp file
      await fs.promises.appendFile(tmpPath, Buffer.from(chunk));
      return { success: true };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to append recording chunk: ${errorMessage}`);
      return { success: false, error: errorMessage };
    }
  });

  // Finalize recording - rename .webm.tmp to .webm
  ipcMain.handle('finalize-recording', async (_event, outputPath: string) => {
    try {
      if (!fileManager) {
        throw new Error('File manager not initialized');
      }
      
      const sessionsPath = fileManager.getSessionsPath();
      const tmpPath = outputPath + '.tmp';
      
      // ISSUE FIX: Validate both paths before finalization
      await validatePathWithinDirectory(tmpPath, sessionsPath, ['.webm.tmp']);
      await validatePathWithinDirectory(outputPath, sessionsPath, ['.webm']);

      let tmpSize: number;
      try {
        const stats = await fs.promises.stat(tmpPath);
        tmpSize = stats.size;
      } catch {
        throw new Error(`Temp recording file not found: ${tmpPath}`);
      }

      // ISSUE FIX: Check for empty recording files (Issue 7)
      if (tmpSize === 0) {
        await fs.promises.unlink(tmpPath);
        throw new Error('Temp recording file is empty - no video data was captured');
      }

      // Rename .webm.tmp -> .webm atomically
      await fs.promises.rename(tmpPath, outputPath);
      log(`Recording finalized: ${outputPath} (${(tmpSize / 1024 / 1024).toFixed(2)} MB)`);
      return { success: true };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to finalize recording: ${errorMessage}`);
      return { success: false, error: errorMessage };
    }
  });

}

// Single instance lock
const gotTheLock = app.requestSingleInstanceLock();

if (!gotTheLock) {
  log('Another instance is running, signaling toggle and quitting');
  app.quit();
} else {
  app.on('second-instance', async () => {
    log('Second instance detected (desktop shortcut clicked)');

    if (isRecordingState) {
      // If recording, stop it
      await toggleRecording();
    }

    // Always show and focus the window
    showAndFocusWindow();

    // Check CURRENT state after toggle (not a stale captured value)
    if (!isRecordingState && mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('focus-task-input');
    }
  });

  app.whenReady().then(async () => {
    // Initialize log file first so all subsequent logs are captured
    initLogFile();
    
    log('App ready');
    
    // Load external configuration first (allows remote config changes without reinstall)
    loadExternalConfig();
    
    setupIpcHandlers();
    createWindow();
    createTray();

    try {
      await initialize();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Initialization failed: ${errorMessage}`);
      sendStatus({ state: 'error', message: 'Failed to initialize', error: errorMessage });
    }
  });
  
  app.on('before-quit', async (event) => {
    if (isQuitting) {
      return;
    }
    
    event.preventDefault();
    isQuitting = true;
    
    log('App quitting - cleaning up...');
    
    stopRecordingTimer();

    // Set a maximum timeout for cleanup to prevent hanging
    const cleanupTimeout = setTimeout(() => {
      log('Cleanup timeout reached, forcing quit');
      app.exit(1);
    }, 10000); // 10 second timeout

    if (nativeRecorder) {
      try {
        if (isRecordingState && mainWindow && !mainWindow.isDestroyed()) {
          log('Stopping active recording...');
          isRecordingState = false;
          // Use shorter timeout (8s) to leave 2s buffer before 10s force-quit
          await nativeRecorder.stopRecording(mainWindow, 8000);
          sessionManager?.endCurrentSession();
        }
      } catch (error) {
        log(`Error during recording cleanup: ${error}`);
      }
      
      // Dispose recorder resources
      nativeRecorder.dispose();
    }
    
    clearTimeout(cleanupTimeout);
    // Destroy tray icon
    if (tray) {
      tray.destroy();
      tray = null;
    }
    
    log('Cleanup complete, quitting app');
    app.exit(0);
  });

  app.on('window-all-closed', () => {
    // On macOS, apps typically stay running in the tray
    // On Windows/Linux, quit when all windows are closed (unless we have tray)
    if (process.platform !== 'darwin' && !tray) {
      app.quit();
    }
  });

  app.on('activate', () => {
    // On macOS, re-create window when dock icon is clicked
    if (!isQuitting && BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    } else if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.show();
      mainWindow.focus();
    }
  });
}
