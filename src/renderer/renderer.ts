/**
 * Renderer process for Workflow Capture application
 * Handles UI updates and media recording via MediaRecorder API
 */

// Types (duplicated from shared since renderer can't import directly)
interface SystemStatus {
  state: 'starting' | 'idle' | 'recording' | 'processing' | 'error';
  message: string;
  recordingDuration?: number;
  error?: string;
}

interface CaptureConfig {
  sourceId: string;
  outputPath: string;
}

// Constants
const VIDEO_BITRATE = 5_000_000; // 5 Mbps
const CHUNK_INTERVAL_MS = 1000;

// DOM Elements - use assertion after null check
const statusIndicator = document.getElementById('status-indicator');
const statusDot = document.getElementById('status-dot');
const statusText = document.getElementById('status-text');
const timerDisplay = document.getElementById('timer-display');
const timer = document.getElementById('timer');
const taskNote = document.getElementById('task-note') as HTMLInputElement | null;
const recordBtn = document.getElementById('record-btn') as HTMLButtonElement | null;
const recordBtnText = document.getElementById('record-btn-text');
const errorContainer = document.getElementById('error-container');
const errorMessage = document.getElementById('error-message');
const openFolderBtn = document.getElementById('open-folder-btn') as HTMLButtonElement | null;
const exportBtn = document.getElementById('export-btn') as HTMLButtonElement | null;

// Validate required DOM elements
function validateDOMElements(): boolean {
  const requiredElements = [
    statusIndicator, statusText, timerDisplay, timer, 
    taskNote, recordBtn, recordBtnText, errorContainer, 
    errorMessage, openFolderBtn, exportBtn
  ];
  
  const allPresent = requiredElements.every(el => el !== null);
  if (!allPresent) {
    console.error('[Renderer] Required DOM elements not found');
  }
  return allPresent;
}

// Recording state
let isRecording = false;
let currentState: SystemStatus['state'] = 'starting';
let mediaRecorder: MediaRecorder | null = null;
let recordedChunks: Blob[] = [];
let currentOutputPath: string | null = null;
let mediaStream: MediaStream | null = null;

// Cleanup functions for event listeners
let cleanupStatusListener: (() => void) | null = null;
let cleanupStartCapture: (() => void) | null = null;
let cleanupStopCapture: (() => void) | null = null;

// Format duration as HH:MM:SS
function formatDuration(seconds: number): string {
  const hrs = Math.floor(seconds / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;
  return [hrs, mins, secs]
    .map(v => v.toString().padStart(2, '0'))
    .join(':');
}

// Update UI based on system status
function updateUI(status: SystemStatus): void {
  if (!statusIndicator || !statusText || !recordBtn || !taskNote || 
      !timerDisplay || !errorContainer || !recordBtnText || !timer) {
    console.error('[Renderer] DOM elements not available for UI update');
    return;
  }
  
  currentState = status.state;

  // Update status indicator
  statusIndicator.className = `status-indicator ${status.state}`;
  statusText.textContent = status.message;

  switch (status.state) {
    case 'starting':
      recordBtn.disabled = true;
      taskNote.disabled = true;
      timerDisplay.classList.add('hidden');
      errorContainer.classList.add('hidden');
      break;

    case 'idle':
      isRecording = false;
      recordBtn.disabled = false;
      recordBtn.classList.remove('recording', 'processing');
      recordBtnText.textContent = 'Start Recording';
      taskNote.disabled = false;
      taskNote.value = ''; // Reset task description for next session
      timerDisplay.classList.add('hidden');
      timerDisplay.classList.remove('processing');
      errorContainer.classList.add('hidden');
      break;

    case 'recording':
      isRecording = true;
      recordBtn.disabled = false;
      recordBtn.classList.remove('processing');
      recordBtn.classList.add('recording');
      recordBtnText.textContent = 'Stop Recording';
      taskNote.disabled = true;
      timerDisplay.classList.remove('hidden', 'processing');
      errorContainer.classList.add('hidden');
      
      if (status.recordingDuration !== undefined) {
        timer.textContent = formatDuration(status.recordingDuration);
      }
      break;

    case 'processing':
      isRecording = false;
      recordBtn.disabled = true;
      recordBtn.classList.remove('recording');
      recordBtn.classList.add('processing');
      recordBtnText.textContent = 'Saving...';
      taskNote.disabled = true;
      // Keep timer visible during processing to show final duration
      timerDisplay.classList.remove('hidden');
      timerDisplay.classList.add('processing');
      errorContainer.classList.add('hidden');
      break;

    case 'error':
      recordBtn.disabled = true;
      taskNote.disabled = true;
      timerDisplay.classList.add('hidden');
      errorContainer.classList.remove('hidden');
      if (errorMessage) {
        errorMessage.textContent = status.error || 'An error occurred';
      }
      break;
  }
}

/**
 * Start capturing screen using desktopCapturer stream
 */
async function startCapture(config: CaptureConfig): Promise<void> {
  console.log('[Renderer] Starting capture with source:', config.sourceId);
  
  try {
    // Get media stream from the selected source
    mediaStream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        // @ts-ignore - Electron-specific constraint
        mandatory: {
          chromeMediaSource: 'desktop',
          chromeMediaSourceId: config.sourceId,
          minWidth: 1920,
          maxWidth: 3840,
          minHeight: 1080,
          maxHeight: 2160,
          minFrameRate: 30,
          maxFrameRate: 30,
        },
      },
    });

    currentOutputPath = config.outputPath;
    recordedChunks = [];

    // Create MediaRecorder with WebM format (will be converted to MP4 by main process)
    const options: MediaRecorderOptions = {
      mimeType: 'video/webm;codecs=vp9',
      videoBitsPerSecond: VIDEO_BITRATE,
    };

    // Fallback if VP9 not supported
    if (!MediaRecorder.isTypeSupported(options.mimeType!)) {
      options.mimeType = 'video/webm;codecs=vp8';
    }
    if (!MediaRecorder.isTypeSupported(options.mimeType!)) {
      options.mimeType = 'video/webm';
    }

    console.log('[Renderer] Using codec:', options.mimeType);
    
    mediaRecorder = new MediaRecorder(mediaStream, options);

    mediaRecorder.ondataavailable = (event: BlobEvent) => {
      if (event.data.size > 0) {
        recordedChunks.push(event.data);
      }
    };

    mediaRecorder.onstop = async () => {
      console.log('[Renderer] MediaRecorder stopped, saving file...');
      
      try {
        // Combine all chunks into a single blob
        const blob = new Blob(recordedChunks, { type: 'video/webm' });
        const arrayBuffer = await blob.arrayBuffer();
        
        // Save the file via IPC
        await window.electronAPI.saveRecordingData(arrayBuffer, currentOutputPath!);
        
        console.log('[Renderer] Recording saved successfully');
        
        // Notify main process that capture is complete
        await window.electronAPI.notifyCaptureStopped({ success: true });
      } catch (error) {
        console.error('[Renderer] Failed to save recording:', error);
        await window.electronAPI.notifyCaptureStopped({ 
          success: false, 
          error: error instanceof Error ? error.message : 'Unknown error' 
        });
      }
      
      // Clean up
      if (mediaStream) {
        mediaStream.getTracks().forEach(track => track.stop());
        mediaStream = null;
      }
      recordedChunks = [];
      currentOutputPath = null;
    };

    mediaRecorder.onerror = (event: Event) => {
      console.error('[Renderer] MediaRecorder error:', event);
    };

    // Start recording with 1 second chunks
    mediaRecorder.start(CHUNK_INTERVAL_MS);
    console.log('[Renderer] Recording started');
    
  } catch (error) {
    console.error('[Renderer] Failed to start capture:', error);
    throw error;
  }
}

/**
 * Stop the current capture and clean up resources
 */
function stopCapture(): void {
  console.log('[Renderer] Stopping capture...');
  
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.stop();
  }
}

/**
 * Clean up all media resources
 */
function cleanupMedia(): void {
  if (mediaStream) {
    mediaStream.getTracks().forEach(track => track.stop());
    mediaStream = null;
  }
  mediaRecorder = null;
  recordedChunks = [];
  currentOutputPath = null;
}

// Event Handlers
async function handleRecordClick(): Promise<void> {
  if (!recordBtn || !recordBtnText || !taskNote) return;
  
  // Prevent double-clicks and clicks during invalid states
  if (recordBtn.disabled) return;
  if (currentState !== 'recording' && currentState !== 'idle') return;
  
  recordBtn.disabled = true;

  try {
    if (currentState === 'recording') {
      // Immediately show processing state for instant feedback
      recordBtn.classList.remove('recording');
      recordBtn.classList.add('processing');
      recordBtnText.textContent = 'Saving...';
      
      const result = await window.electronAPI.stopRecording();
      if (!result.success) {
        console.error('Failed to stop recording:', result.error);
        // Reset to recording state so user can retry
        recordBtn.classList.remove('processing');
        recordBtn.classList.add('recording');
        recordBtnText.textContent = 'Stop Recording';
        recordBtn.disabled = false;
      }
      // On success, button will be re-enabled by status update from main process
    } else if (currentState === 'idle') {
      // Show brief feedback during start
      recordBtnText.textContent = 'Starting...';
      
      const note = taskNote.value.trim();
      const result = await window.electronAPI.startRecording(note);
      if (!result.success) {
        console.error('Failed to start recording:', result.error);
        // Reset button text on failure
        recordBtnText.textContent = 'Start Recording';
        recordBtn.disabled = false;
      }
      // On success, button will be re-enabled by status update from main process
    }
  } catch (error) {
    console.error('Recording action failed:', error);
    // Reset button on exception so user can retry
    recordBtn.classList.remove('processing');
    if (currentState === 'recording') {
      recordBtn.classList.add('recording');
      recordBtnText.textContent = 'Stop Recording';
    } else {
      recordBtnText.textContent = 'Start Recording';
    }
    recordBtn.disabled = false;
  }
}

async function handleOpenFolder(): Promise<void> {
  if (!openFolderBtn) return;
  
  openFolderBtn.disabled = true;

  try {
    await window.electronAPI.openSessionsFolder();
  } catch (error) {
    console.error('Failed to open folder:', error);
  } finally {
    openFolderBtn.disabled = false;
  }
}

async function handleExport(): Promise<void> {
  if (!exportBtn) return;
  
  exportBtn.disabled = true;
  const originalText = exportBtn.textContent;
  exportBtn.textContent = 'Exporting...';

  try {
    const result = await window.electronAPI.exportSessions();
    if (result.success) {
      exportBtn.textContent = 'Exported!';
      setTimeout(() => {
        exportBtn.textContent = originalText;
      }, 2000);
    } else {
      console.error('Failed to export:', result.error);
      exportBtn.textContent = 'Failed';
      setTimeout(() => {
        exportBtn.textContent = originalText;
      }, 2000);
    }
  } catch (error) {
    console.error('Export failed:', error);
    exportBtn.textContent = originalText;
  } finally {
    exportBtn.disabled = false;
  }
}

/**
 * Clean up all event listeners
 */
function cleanup(): void {
  cleanupStatusListener?.();
  cleanupStartCapture?.();
  cleanupStopCapture?.();
  cleanupMedia();
}

// Initialize
function init(): void {
  // Validate DOM elements are present
  if (!validateDOMElements()) {
    console.error('[Renderer] Cannot initialize - missing DOM elements');
    return;
  }

  // Set up button event listeners
  recordBtn?.addEventListener('click', handleRecordClick);
  openFolderBtn?.addEventListener('click', handleOpenFolder);
  exportBtn?.addEventListener('click', handleExport);

  // Listen for status updates from main process (store cleanup functions)
  cleanupStatusListener = window.electronAPI.onStatusUpdate((status: SystemStatus) => {
    updateUI(status);
  });

  // Listen for capture commands from main process
  cleanupStartCapture = window.electronAPI.onStartCapture((config: CaptureConfig) => {
    startCapture(config).catch(error => {
      console.error('[Renderer] Capture failed:', error);
    });
  });

  cleanupStopCapture = window.electronAPI.onStopCapture(() => {
    stopCapture();
  });

  // Clean up on page unload
  window.addEventListener('beforeunload', cleanup);

  // Set initial state
  updateUI({ state: 'starting', message: 'Starting...' });
  
  console.log('[Renderer] Initialized successfully');
}

// Start the app
init();
