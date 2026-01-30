import { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import { NativeRecorder } from './native-recorder';
import { SessionManager } from './session-manager';
import { FileManager } from './file-manager';
import { SystemState, SystemStatus, APP_CONSTANTS } from '../shared/types';

// Global error handlers
process.on('uncaughtException', (error) => {
  console.error('[Main] Uncaught Exception:', error.message);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('[Main] Unhandled Rejection at:', promise, 'reason:', reason);
});

// Re-export types from shared for backwards compatibility
export type { SystemState, SystemStatus } from '../shared/types';

// Globals
let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let nativeRecorder: NativeRecorder | null = null;
let sessionManager: SessionManager | null = null;
let fileManager: FileManager | null = null;
let recordingStartTime: number | null = null;
let recordingTimer: NodeJS.Timeout | null = null;
let maxDurationTimer: NodeJS.Timeout | null = null;
let isQuitting = false;

function log(message: string): void {
  console.log(`[Main] ${message}`);
}

function sendStatus(status: SystemStatus): void {
  // Track current state for tray menu
  currentSystemState = status.state;
  
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
    skipTaskbar: true,
    alwaysOnTop: true,
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
      if (nativeRecorder?.getRecordingStatus()) {
        stopRecordingTimer();
        nativeRecorder.reset();
        sessionManager?.endCurrentSession().catch(() => {});
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

  // Hide to tray instead of closing
  mainWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      mainWindow?.hide();
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
  
  const isRecording = nativeRecorder?.getRecordingStatus() ?? false;
  const isProcessing = currentSystemState === 'processing';
  
  const contextMenu = Menu.buildFromTemplate([
    { 
      label: isProcessing ? 'Saving...' : (isRecording ? 'Stop Recording' : 'Show Window'),
      enabled: !isProcessing, // Disable menu item while processing
      click: async () => {
        if (isRecording && !isProcessing && nativeRecorder && mainWindow) {
          // Stop recording - do all work while window is still hidden
          let outputPath: string | null = null;
          try {
            stopRecordingTimer();
            currentSystemState = 'processing';
            updateTrayMenu();
            
            outputPath = await nativeRecorder.stopRecording(mainWindow);
            await sessionManager?.endCurrentSession();
            
            log(`Recording stopped via tray menu, saved to: ${outputPath}`);
          } catch (error) {
            const errorMessage = error instanceof Error ? error.message : 'Unknown error';
            log(`Failed to stop recording via tray menu: ${errorMessage}`);
          }
          
          // Now show window in idle state
          currentSystemState = 'idle';
          updateTrayMenu();
          mainWindow.show();
          mainWindow.focus();
          sendStatus({ state: 'idle', message: 'Ready' });
          
          // Show toast notification with saved filename
          if (outputPath) {
            sendRecordingSavedNotification(outputPath);
          }
        } else if (mainWindow) {
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
      enabled: !isRecording && !isProcessing, // Disable quit while recording or processing
      click: () => {
        app.quit();
      }
    }
  ]);
  
  const tooltip = isProcessing 
    ? 'Workflow Capture - Saving...'
    : isRecording 
      ? 'Workflow Capture - Recording (Click to stop)' 
      : 'Workflow Capture';
  tray.setToolTip(tooltip);
  tray.setContextMenu(contextMenu);
}

function createTray(): void {
  // Use the app icon for the tray
  let iconPath: string;
  
  if (app.isPackaged) {
    // In packaged app, use resources directory
    iconPath = path.join(process.resourcesPath, 'icon.ico');
  } else {
    // In development, use build directory
    iconPath = path.join(__dirname, '..', '..', 'build', 'icon.ico');
  }
  
  let trayIcon: Electron.NativeImage;
  
  // Check if icon file exists
  if (fs.existsSync(iconPath)) {
    trayIcon = nativeImage.createFromPath(iconPath);
    // Resize for tray (16x16 on Windows, varies on other platforms)
    trayIcon = trayIcon.resize({ width: 16, height: 16 });
  } else {
    // Fallback: create a simple icon programmatically
    log(`Icon not found at ${iconPath}, using fallback`);
    const size = 16;
    const canvas = Buffer.alloc(size * size * 4);
    for (let i = 0; i < size * size; i++) {
      canvas[i * 4] = 74;      // R
      canvas[i * 4 + 1] = 158; // G  
      canvas[i * 4 + 2] = 255; // B
      canvas[i * 4 + 3] = 255; // A
    }
    trayIcon = nativeImage.createFromBuffer(canvas, { width: size, height: size });
  }
  
  tray = new Tray(trayIcon);
  
  updateTrayMenu();
  
  tray.setToolTip('Workflow Capture');
  
  // Click on tray icon - if recording, stop recording; otherwise toggle window
  tray.on('click', async () => {
    const isRecording = nativeRecorder?.getRecordingStatus() ?? false;
    const isProcessing = currentSystemState === 'processing';
    
    if (isRecording && !isProcessing && nativeRecorder && mainWindow) {
      // Stop recording - do all work while window is still hidden
      let outputPath: string | null = null;
      try {
        stopRecordingTimer();
        currentSystemState = 'processing';
        updateTrayMenu();
        
        outputPath = await nativeRecorder.stopRecording(mainWindow);
        await sessionManager?.endCurrentSession();
        
        log(`Recording stopped via tray, saved to: ${outputPath}`);
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'Unknown error';
        log(`Failed to stop recording via tray: ${errorMessage}`);
      }
      
      // Now show window in idle state
      currentSystemState = 'idle';
      updateTrayMenu();
      mainWindow.show();
      mainWindow.focus();
      sendStatus({ state: 'idle', message: 'Ready' });
      
      // Show toast notification with saved filename
      if (outputPath) {
        sendRecordingSavedNotification(outputPath);
      }
    } else if (mainWindow) {
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

  try {
    // Initialize file manager
    log('Initializing file manager...');
    fileManager = new FileManager();
    await fileManager.ensureSessionsDirectory();
    log('File manager initialized');

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
  
  // Set up max duration timer - auto-stop after 5 minutes
  maxDurationTimer = setTimeout(async () => {
    log('Max recording duration (5 minutes) reached, auto-stopping...');
    await autoStopRecording();
  }, APP_CONSTANTS.MAX_RECORDING_DURATION_MS);
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
  
  const isRecording = nativeRecorder.getRecordingStatus();
  if (!isRecording) {
    log('Auto-stop called but not recording');
    return;
  }
  
  try {
    stopRecordingTimer();
    currentSystemState = 'processing';
    updateTrayMenu();
    
    // Show window immediately with processing state
    mainWindow.show();
    mainWindow.focus();
    sendStatus({ state: 'processing', message: 'Max time reached. Saving...' });
    
    const outputPath = await nativeRecorder.stopRecording(mainWindow);
    await sessionManager.endCurrentSession();
    
    log(`Auto-stopped recording saved to: ${outputPath}`);
    
    currentSystemState = 'idle';
    updateTrayMenu();
    sendStatus({ state: 'idle', message: 'Ready' });
    
    // Show toast notification with saved filename
    sendRecordingSavedNotification(outputPath);
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    log(`Failed to auto-stop recording: ${errorMessage}`);
    currentSystemState = 'idle';
    updateTrayMenu();
    sendStatus({ state: 'idle', message: 'Ready' });
  }
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
      
      // Hide window during recording
      mainWindow.hide();
      
      // Update tray to show recording state
      updateTrayMenu();
      
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
      
      // Show window immediately with processing state
      mainWindow.show();
      mainWindow.focus();
      sendStatus({ state: 'processing', message: 'Processing video...' });
      
      // Update tray to show we're no longer recording
      updateTrayMenu();

      // Process recording (conversion happens in background while UI is responsive)
      const outputPath = await nativeRecorder.stopRecording(mainWindow);
      
      await sessionManager.endCurrentSession();
      sendStatus({ state: 'idle', message: 'Ready' });
      
      // Show toast notification with saved filename
      sendRecordingSavedNotification(outputPath);
      
      log(`Recording stopped, saved to: ${outputPath}`);
      return { success: true, path: outputPath };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to stop recording: ${errorMessage}`);
      // Reset to idle state on error so user can try again
      sendStatus({ state: 'idle', message: 'Ready' });
      // Update tray to show idle state
      updateTrayMenu();
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
        const isRecording = nativeRecorder.getRecordingStatus();
        if (isRecording && mainWindow && !mainWindow.isDestroyed()) {
          log('Stopping active recording...');
          await nativeRecorder.stopRecording(mainWindow);
          await sessionManager?.endCurrentSession();
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
