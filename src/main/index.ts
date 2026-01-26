import { app, BrowserWindow, ipcMain, shell } from 'electron';
import * as path from 'path';
import { ObsSupervisor } from './obs-supervisor';
import { ObsController } from './obs-controller';
import { SessionManager } from './session-manager';
import { FileManager } from './file-manager';

// Global error handlers to prevent uncaught exceptions from crashing the app
process.on('uncaughtException', (error) => {
  console.error('[Main] Uncaught Exception:', error.message);
  // Don't crash the app for connection errors - they're handled by retry logic
  if (error.message.includes('ECONNREFUSED')) {
    console.log('[Main] OBS connection refused - OBS may not be running yet');
  }
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('[Main] Unhandled Rejection at:', promise, 'reason:', reason);
});

// Types
export type SystemState = 'starting' | 'idle' | 'recording' | 'reconnecting' | 'error';

export interface SystemStatus {
  state: SystemState;
  message: string;
  recordingDuration?: number;
  error?: string;
}

// Globals
let mainWindow: BrowserWindow | null = null;
let obsSupervisor: ObsSupervisor | null = null;
let obsController: ObsController | null = null;
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

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 400,
    height: 300,
    resizable: false,
    maximizable: false,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'L7S Workflow Capture',
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  mainWindow.setMenu(null);

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  log('Window created');
}

async function initializeObs(): Promise<void> {
  sendStatus({ state: 'starting', message: 'Initializing...' });

  // Initialize file manager
  fileManager = new FileManager();
  await fileManager.ensureSessionsDirectory();
  log('File manager initialized');

  // Initialize session manager
  sessionManager = new SessionManager(fileManager);
  log('Session manager initialized');

  // Kill any orphaned OBS processes
  sendStatus({ state: 'starting', message: 'Cleaning up...' });
  await ObsSupervisor.killOrphanedProcesses();

  // Initialize OBS supervisor
  obsSupervisor = new ObsSupervisor();
  // Note: Do NOT use safe mode as it disables WebSockets
  // The global.ini SafeMode=false setting should prevent the safe mode prompt
  
  obsSupervisor.on('obs-started', () => {
    log('OBS process started');
  });

  obsSupervisor.on('obs-stopped', () => {
    log('OBS process stopped');
  });

  obsSupervisor.on('obs-crashed', async () => {
    log('OBS crashed, attempting recovery...');
    sendStatus({ state: 'reconnecting', message: 'OBS crashed, restarting...' });
    
    if (obsController) {
      obsController.disconnect();
    }

    try {
      await obsSupervisor?.start();
      await connectToObs();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      sendStatus({ state: 'error', message: 'Failed to recover', error: errorMessage });
    }
  });

  // Start OBS
  sendStatus({ state: 'starting', message: 'Starting OBS...' });
  await obsSupervisor.start();

  // Connect via WebSocket
  await connectToObs();
}

async function connectToObs(): Promise<void> {
  sendStatus({ state: 'starting', message: 'Connecting to OBS...' });

  obsController = new ObsController();

  obsController.on('disconnected', () => {
    log('WebSocket disconnected from OBS');
    if (obsSupervisor?.isRunning()) {
      sendStatus({ state: 'reconnecting', message: 'Connection lost, reconnecting...' });
      // Attempt reconnection
      setTimeout(async () => {
        try {
          await obsController?.connect();
          sendStatus({ state: 'idle', message: 'Ready' });
        } catch {
          sendStatus({ state: 'error', message: 'Failed to reconnect', error: 'WebSocket connection failed' });
        }
      }, 2000);
    }
  });

  const connected = await obsController.connect();
  
  if (connected) {
    sendStatus({ state: 'idle', message: 'Ready' });
    log('OBS ready');
  } else {
    throw new Error('Failed to connect to OBS WebSocket');
  }
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
      if (!sessionManager || !obsController) {
        throw new Error('System not initialized');
      }

      const session = await sessionManager.createSession(note);
      await obsController.setRecordDirectory(session.path);
      await obsController.startRecording();
      
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
      if (!sessionManager || !obsController) {
        throw new Error('System not initialized');
      }

      await obsController.stopRecording();
      stopRecordingTimer();
      
      await sessionManager.endCurrentSession();
      sendStatus({ state: 'idle', message: 'Ready' });
      
      log('Recording stopped');
      return { success: true };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Failed to stop recording: ${errorMessage}`);
      return { success: false, error: errorMessage };
    }
  });

  ipcMain.handle('get-status', async () => {
    try {
      if (!obsController) {
        return { state: 'error', message: 'Not initialized' };
      }

      const recording = await obsController.getRecordingStatus();
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

  ipcMain.handle('retry-connection', async () => {
    try {
      await connectToObs();
      return { success: true };
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

    try {
      await initializeObs();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      log(`Initialization failed: ${errorMessage}`);
      sendStatus({ state: 'error', message: 'Failed to initialize', error: errorMessage });
    }
  });

  let isQuitting = false;
  
  app.on('before-quit', async (event) => {
    if (isQuitting) {
      return; // Already handling quit
    }
    
    // Prevent the app from quitting until we're done cleaning up
    event.preventDefault();
    isQuitting = true;
    
    log('App quitting - cleaning up...');
    
    stopRecordingTimer();

    if (obsController) {
      try {
        const isRecording = await obsController.getRecordingStatus();
        if (isRecording) {
          log('Stopping active recording...');
          await obsController.stopRecording();
          await sessionManager?.endCurrentSession();
        }
      } catch (error) {
        log(`Error during recording cleanup: ${error}`);
      }
      
      log('Disconnecting from OBS WebSocket...');
      obsController.disconnect();
    }

    if (obsSupervisor) {
      log('Stopping OBS process...');
      await obsSupervisor.stop();
      // Give OBS time to fully shut down and save its config
      await new Promise(resolve => setTimeout(resolve, 2000));
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
