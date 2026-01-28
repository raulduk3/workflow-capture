import { app, BrowserWindow, ipcMain, shell, screen, Tray, Menu, nativeImage } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import { NativeRecorder } from './native-recorder';
import { SessionManager } from './session-manager';
import { FileManager } from './file-manager';

// Global error handlers
process.on('uncaughtException', (error) => {
  console.error('[Main] Uncaught Exception:', error.message);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('[Main] Unhandled Rejection at:', promise, 'reason:', reason);
});

// Types
export type SystemState = 'starting' | 'idle' | 'recording' | 'error';

export interface SystemStatus {
  state: SystemState;
  message: string;
  recordingDuration?: number;
  error?: string;
}

// Globals
let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let nativeRecorder: NativeRecorder | null = null;
let sessionManager: SessionManager | null = null;
let fileManager: FileManager | null = null;
let recordingStartTime: number | null = null;
let recordingTimer: NodeJS.Timeout | null = null;

function log(message: string): void {
  console.log(`[Main] ${message}`);
}

function sendStatus(status: SystemStatus): void {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send('system-status', status);
  }
}

/**
 * Get the sessions directory path
 */
function getSessionsPath(): string {
  const platform = os.platform();
  let sessionsPath: string;
  
  if (platform === 'win32') {
    const appDataPath = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    sessionsPath = path.join(appDataPath, 'L7SWorkflowCapture', 'Sessions');
  } else {
    sessionsPath = path.join(os.homedir(), 'L7SWorkflowCapture', 'Sessions');
  }
  
  // Create if needed
  if (!fs.existsSync(sessionsPath)) {
    fs.mkdirSync(sessionsPath, { recursive: true });
    log(`Created sessions directory: ${sessionsPath}`);
  }
  
  return sessionsPath;
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 400,
    height: 320,
    resizable: false,
    maximizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'Workflow Capture',
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  mainWindow.setMenu(null);

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  log('Window created');
}

function createTray(): void {
  // Create a simple 16x16 icon (red circle for recording indicator style)
  const iconSize = 16;
  const icon = nativeImage.createEmpty();
  
  // For Windows, we need a proper icon. Create a simple colored square.
  const canvas = Buffer.alloc(iconSize * iconSize * 4);
  for (let i = 0; i < iconSize * iconSize; i++) {
    const x = i % iconSize;
    const y = Math.floor(i / iconSize);
    const centerX = iconSize / 2;
    const centerY = iconSize / 2;
    const radius = iconSize / 2 - 1;
    const distance = Math.sqrt((x - centerX) ** 2 + (y - centerY) ** 2);
    
    if (distance <= radius) {
      // Blue color for L7S branding
      canvas[i * 4] = 74;      // R
      canvas[i * 4 + 1] = 158; // G
      canvas[i * 4 + 2] = 255; // B
      canvas[i * 4 + 3] = 255; // A
    } else {
      canvas[i * 4 + 3] = 0;   // Transparent
    }
  }
  
  const trayIcon = nativeImage.createFromBuffer(canvas, { width: iconSize, height: iconSize });
  tray = new Tray(trayIcon);
  
  const contextMenu = Menu.buildFromTemplate([
    { 
      label: 'Show Window', 
      click: () => {
        if (mainWindow) {
          mainWindow.show();
          mainWindow.focus();
        }
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
      click: () => {
        app.quit();
      }
    }
  ]);
  
  tray.setToolTip('Workflow Capture');
  tray.setContextMenu(contextMenu);
  
  // Click on tray icon to show/hide window
  tray.on('click', () => {
    if (mainWindow) {
      if (mainWindow.isVisible()) {
        mainWindow.hide();
      } else {
        mainWindow.show();
        mainWindow.focus();
      }
    }
  });
  
  log('Tray created');
}

async function initialize(): Promise<void> {
  sendStatus({ state: 'starting', message: 'Initializing...' });

  // Initialize file manager
  fileManager = new FileManager();
  await fileManager.ensureSessionsDirectory();
  log('File manager initialized');

  // Initialize session manager
  sessionManager = new SessionManager(fileManager);
  log('Session manager initialized');

  // Initialize native recorder
  nativeRecorder = new NativeRecorder();
  log('Native recorder initialized');

  sendStatus({ state: 'idle', message: 'Ready' });
  log('System ready');
}

function startRecordingTimer(): void {
  recordingStartTime = Date.now();
  recordingTimer = setInterval(() => {
    if (recordingStartTime) {
      const duration = Math.floor((Date.now() - recordingStartTime) / 1000);
      sendStatus({ state: 'recording', message: 'Recording', recordingDuration: duration });
    }
  }, 1000);
}

function stopRecordingTimer(): void {
  if (recordingTimer) {
    clearInterval(recordingTimer);
    recordingTimer = null;
  }
  recordingStartTime = null;
}

function setupIpcHandlers(): void {
  ipcMain.handle('start-recording', async (_event, note: string) => {
    try {
      if (!sessionManager || !nativeRecorder || !mainWindow) {
        throw new Error('System not initialized');
      }

      const session = await sessionManager.createSession(note);
      
      // Set recording directory
      nativeRecorder.setOutputDirectory(session.path);
      
      // Start recording
      await nativeRecorder.startRecording(mainWindow);
      
      startRecordingTimer();
      sendStatus({ state: 'recording', message: 'Recording', recordingDuration: 0 });
      
      log(`Recording started: ${session.id}`);
      return { success: true, sessionId: session.id };
    } catch (error) {
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
      sendStatus({ state: 'starting', message: 'Processing...' });

      const outputPath = await nativeRecorder.stopRecording(mainWindow);
      
      await sessionManager.endCurrentSession();
      sendStatus({ state: 'idle', message: 'Ready' });
      
      log(`Recording stopped, saved to: ${outputPath}`);
      return { success: true, path: outputPath };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to stop recording: ${errorMessage}`);
      // Reset to idle state on error so user can try again
      sendStatus({ state: 'idle', message: 'Ready' });
      return { success: false, error: errorMessage };
    }
  });

  ipcMain.handle('get-status', async () => {
    try {
      if (!nativeRecorder) {
        return { state: 'error', message: 'Not initialized' };
      }

      const recording = nativeRecorder.getRecordingStatus();
      if (recording) {
        return { state: 'recording', message: 'Recording' };
      }
      return { state: 'idle', message: 'Ready' };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      return { state: 'error', message: 'Error', error: errorMessage };
    }
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

  ipcMain.handle('export-sessions', async () => {
    try {
      if (!fileManager) {
        throw new Error('File manager not initialized');
      }
      const exportPath = await fileManager.exportAllSessions();
      log(`Sessions exported to: ${exportPath}`);
      return { success: true, path: exportPath };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to export sessions: ${errorMessage}`);
      return { success: false, error: errorMessage };
    }
  });

  // Handle recording data from renderer
  ipcMain.handle('save-recording-chunk', async (_event, chunk: ArrayBuffer, outputPath: string) => {
    try {
      fs.appendFileSync(outputPath, Buffer.from(chunk));
      return { success: true };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      return { success: false, error: errorMessage };
    }
  });

  ipcMain.handle('get-screen-sources', async () => {
    try {
      if (!nativeRecorder) {
        throw new Error('Recorder not initialized');
      }
      const sources = await nativeRecorder.getScreenSources();
      return { 
        success: true, 
        sources: sources.map(s => ({ id: s.id, name: s.name })) 
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      return { success: false, error: errorMessage };
    }
  });
}

// Single instance lock
const gotTheLock = app.requestSingleInstanceLock();

if (!gotTheLock) {
  log('Another instance is running, quitting');
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) {
        mainWindow.restore();
      }
      mainWindow.focus();
    }
  });

  app.whenReady().then(async () => {
    log('App ready');
    
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

  let isQuitting = false;
  
  app.on('before-quit', async (event) => {
    if (isQuitting) {
      return;
    }
    
    event.preventDefault();
    isQuitting = true;
    
    log('App quitting - cleaning up...');
    
    stopRecordingTimer();

    if (nativeRecorder && mainWindow) {
      try {
        const isRecording = nativeRecorder.getRecordingStatus();
        if (isRecording) {
          log('Stopping active recording...');
          await nativeRecorder.stopRecording(mainWindow);
          await sessionManager?.endCurrentSession();
        }
      } catch (error) {
        log(`Error during recording cleanup: ${error}`);
      }
    }
    
    log('Cleanup complete, quitting app');
    app.exit(0);
  });

  app.on('window-all-closed', () => {
    app.quit();
  });

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
}
