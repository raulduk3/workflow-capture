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

interface DisplayInfo {
  index: number;
  x: number;
  y: number;
  width: number;
  height: number;
  scaleFactor: number;
}

interface ScreenSource {
  id: string;
  name: string;
}

interface CaptureConfig {
  sourceId: string;
  outputPath: string;
  canvasWidth?: number;  // Total width for multi-monitor capture
  canvasHeight?: number; // Total height for multi-monitor capture
  // Windows multi-monitor compositing
  needsCompositing?: boolean;
  allScreenSources?: ScreenSource[];
  displayInfo?: DisplayInfo[];
}

// Constants
const VIDEO_BITRATE = 8_000_000; // 8 Mbps - Higher bitrate for readable text
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
const toastNotification = document.getElementById('toast-notification');
const toastMessage = document.getElementById('toast-message');

// Toast notification timeout handle
let toastTimeout: ReturnType<typeof setTimeout> | null = null;

/**
 * Show a toast notification that fades away after a delay
 */
function showToast(message: string, durationMs: number = 3000): void {
  if (!toastNotification || !toastMessage) return;
  
  // Clear any existing timeout
  if (toastTimeout) {
    clearTimeout(toastTimeout);
    toastTimeout = null;
  }
  
  // Reset state and show
  toastNotification.classList.remove('hidden', 'fade-out');
  toastMessage.textContent = message;
  
  // Start fade out after delay
  toastTimeout = setTimeout(() => {
    toastNotification.classList.add('fade-out');
    
    // Hide completely after fade animation
    setTimeout(() => {
      toastNotification.classList.add('hidden');
      toastNotification.classList.remove('fade-out');
    }, 500); // Match the CSS transition duration
  }, durationMs);
}

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

// Multi-monitor compositing state (Windows)
let compositeCanvas: HTMLCanvasElement | null = null;
let compositeCtx: CanvasRenderingContext2D | null = null;
let videoElements: HTMLVideoElement[] = [];
let additionalStreams: MediaStream[] = [];
let animationFrameId: number | null = null;

// Cleanup functions for event listeners
let cleanupStatusListener: (() => void) | null = null;
let cleanupStartCapture: (() => void) | null = null;
let cleanupStopCapture: (() => void) | null = null;
let cleanupRecordingSaved: (() => void) | null = null;
let cleanupFocusTaskInput: (() => void) | null = null;

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
 * On Windows with multiple monitors, composites all screens into one canvas
 */
async function startCapture(config: CaptureConfig): Promise<void> {
  console.log('[Renderer] Starting capture with source:', config.sourceId);
  console.log('[Renderer] Needs compositing:', config.needsCompositing);
  
  // Use provided canvas dimensions or fallback to reasonable defaults
  const captureWidth = config.canvasWidth || 7680;
  const captureHeight = config.canvasHeight || 4320;
  
  console.log(`[Renderer] Target canvas dimensions: ${captureWidth}x${captureHeight}`);
  
  try {
    currentOutputPath = config.outputPath;
    recordedChunks = [];

    let streamToRecord: MediaStream;

    if (config.needsCompositing && config.allScreenSources && config.displayInfo && config.allScreenSources.length > 1) {
      // Windows multi-monitor: capture all screens and composite them
      console.log(`[Renderer] Setting up multi-monitor compositing for ${config.allScreenSources.length} screens`);
      
      streamToRecord = await setupMultiMonitorCapture(
        config.allScreenSources,
        config.displayInfo,
        captureWidth,
        captureHeight
      );
    } else {
      // Single screen or macOS "Entire Screen" capture
      mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: {
          // @ts-ignore - Electron-specific constraint
          mandatory: {
            chromeMediaSource: 'desktop',
            chromeMediaSourceId: config.sourceId,
            minWidth: 1280,
            maxWidth: captureWidth,
            minHeight: 720,
            maxHeight: captureHeight,
            minFrameRate: 30,
            maxFrameRate: 30,
          },
        },
      });

      // Log actual captured video dimensions for verification
      const videoTrack = mediaStream.getVideoTracks()[0];
      if (videoTrack) {
        const settings = videoTrack.getSettings();
        console.log(`[Renderer] Actual capture resolution: ${settings.width}x${settings.height}`);
      }

      streamToRecord = mediaStream;
    }

    // Create MediaRecorder with WebM format
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
    
    mediaRecorder = new MediaRecorder(streamToRecord, options);

    mediaRecorder.ondataavailable = (event: BlobEvent) => {
      if (event.data.size > 0) {
        recordedChunks.push(event.data);
      }
    };

    mediaRecorder.onstop = async () => {
      console.log('[Renderer] MediaRecorder stopped, saving file...');
      
      // Stop compositing animation loop if active
      if (animationFrameId !== null) {
        cancelAnimationFrame(animationFrameId);
        animationFrameId = null;
      }
      
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
      
      // Clean up all resources
      cleanupCompositing();
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
    cleanupCompositing();
    throw error;
  }
}

/**
 * Set up multi-monitor capture by compositing all screens onto a canvas
 * Used on Windows where each monitor is a separate source
 */
async function setupMultiMonitorCapture(
  sources: ScreenSource[],
  displays: DisplayInfo[],
  canvasWidth: number,
  canvasHeight: number
): Promise<MediaStream> {
  console.log('[Renderer] Setting up canvas for multi-monitor compositing');
  
  // Create offscreen canvas for compositing
  compositeCanvas = document.createElement('canvas');
  compositeCanvas.width = canvasWidth;
  compositeCanvas.height = canvasHeight;
  compositeCtx = compositeCanvas.getContext('2d');
  
  if (!compositeCtx) {
    throw new Error('Failed to create canvas context for compositing');
  }

  // Sort displays by their index to match source order
  const sortedDisplays = [...displays].sort((a, b) => a.index - b.index);
  
  // Capture each screen
  for (let i = 0; i < sources.length && i < sortedDisplays.length; i++) {
    const source = sources[i];
    const display = sortedDisplays[i];
    
    console.log(`[Renderer] Capturing screen ${i}: ${source.name} -> position (${display.x}, ${display.y})`);
    
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: {
          // @ts-ignore - Electron-specific constraint
          mandatory: {
            chromeMediaSource: 'desktop',
            chromeMediaSourceId: source.id,
            minWidth: 640,
            maxWidth: display.width,
            minHeight: 480,
            maxHeight: display.height,
            minFrameRate: 30,
            maxFrameRate: 30,
          },
        },
      });
      
      additionalStreams.push(stream);
      
      // Create video element to render stream
      const video = document.createElement('video');
      video.srcObject = stream;
      video.muted = true;
      video.autoplay = true;
      // Store display info on video element for positioning
      (video as any)._displayInfo = display;
      videoElements.push(video);
      
      await video.play();
      
      const settings = stream.getVideoTracks()[0]?.getSettings();
      console.log(`[Renderer] Screen ${i} capture resolution: ${settings?.width}x${settings?.height}`);
    } catch (err) {
      console.error(`[Renderer] Failed to capture screen ${i}:`, err);
    }
  }

  if (videoElements.length === 0) {
    throw new Error('Failed to capture any screens for compositing');
  }

  // Calculate the maximum height across all displays for vertical centering
  const maxDisplayHeight = Math.max(...sortedDisplays.map(d => d.height));
  
  // Start rendering loop to composite all screens
  const renderFrame = () => {
    if (!compositeCtx || !compositeCanvas) return;
    
    // Clear canvas with black background
    compositeCtx.fillStyle = '#000';
    compositeCtx.fillRect(0, 0, compositeCanvas.width, compositeCanvas.height);
    
    // Draw each video at its display position, centered vertically
    for (const video of videoElements) {
      const display = (video as any)._displayInfo as DisplayInfo;
      if (display && video.readyState >= 2) {
        // Center vertically: offset by half the difference between max height and this display's height
        const verticalOffset = Math.floor((maxDisplayHeight - display.height) / 2);
        compositeCtx.drawImage(video, display.x, display.y + verticalOffset, display.width, display.height);
      }
    }
    
    animationFrameId = requestAnimationFrame(renderFrame);
  };
  
  renderFrame();
  
  // Capture stream from canvas at 30fps
  const canvasStream = compositeCanvas.captureStream(30);
  console.log(`[Renderer] Composited stream created: ${canvasWidth}x${canvasHeight}`);
  
  return canvasStream;
}

/**
 * Clean up compositing resources
 */
function cleanupCompositing(): void {
  if (animationFrameId !== null) {
    cancelAnimationFrame(animationFrameId);
    animationFrameId = null;
  }
  
  for (const video of videoElements) {
    video.pause();
    video.srcObject = null;
  }
  videoElements = [];
  
  for (const stream of additionalStreams) {
    stream.getTracks().forEach(track => track.stop());
  }
  additionalStreams = [];
  
  compositeCanvas = null;
  compositeCtx = null;
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
  cleanupCompositing();
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
  cleanupRecordingSaved?.();
  cleanupFocusTaskInput?.();
  cleanupMedia();
  if (toastTimeout) {
    clearTimeout(toastTimeout);
    toastTimeout = null;
  }
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

  // Listen for recording saved notification
  cleanupRecordingSaved = window.electronAPI.onRecordingSaved((filename: string) => {
    showToast(`Recording saved as ${filename}`, 3000);
  });

  // Listen for focus task input signal (when app opened via desktop shortcut)
  cleanupFocusTaskInput = window.electronAPI.onFocusTaskInput(() => {
    if (taskNote && !taskNote.disabled) {
      taskNote.focus();
      taskNote.select();
    }
  });

  // Clean up on page unload
  window.addEventListener('beforeunload', cleanup);

  // Set initial state
  updateUI({ state: 'starting', message: 'Starting...' });
  
  console.log('[Renderer] Initialized successfully');
}

// Start the app
init();
