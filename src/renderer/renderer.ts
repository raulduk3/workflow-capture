interface SystemStatus {
  state: 'starting' | 'idle' | 'recording' | 'reconnecting' | 'error';
  message: string;
  recordingDuration?: number;
  error?: string;
}

// DOM Elements
const statusIndicator = document.getElementById('status-indicator') as HTMLDivElement;
const statusDot = document.getElementById('status-dot') as HTMLSpanElement;
const statusText = document.getElementById('status-text') as HTMLSpanElement;
const timerDisplay = document.getElementById('timer-display') as HTMLDivElement;
const timer = document.getElementById('timer') as HTMLSpanElement;
const taskNote = document.getElementById('task-note') as HTMLInputElement;
const recordBtn = document.getElementById('record-btn') as HTMLButtonElement;
const recordBtnText = document.getElementById('record-btn-text') as HTMLSpanElement;
const errorContainer = document.getElementById('error-container') as HTMLDivElement;
const errorMessage = document.getElementById('error-message') as HTMLParagraphElement;
const retryBtn = document.getElementById('retry-btn') as HTMLButtonElement;
const openFolderBtn = document.getElementById('open-folder-btn') as HTMLButtonElement;
const exportBtn = document.getElementById('export-btn') as HTMLButtonElement;

// State
let isRecording = false;
let currentState: SystemStatus['state'] = 'starting';

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
  currentState = status.state;

  // Update status indicator
  statusIndicator.className = `status-indicator ${status.state}`;
  statusText.textContent = status.message;

  // Handle different states
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
      recordBtn.classList.remove('recording');
      recordBtnText.textContent = 'Start Recording';
      taskNote.disabled = false;
      timerDisplay.classList.add('hidden');
      errorContainer.classList.add('hidden');
      break;

    case 'recording':
      isRecording = true;
      recordBtn.disabled = false;
      recordBtn.classList.add('recording');
      recordBtnText.textContent = 'Stop Recording';
      taskNote.disabled = true;
      timerDisplay.classList.remove('hidden');
      errorContainer.classList.add('hidden');
      
      if (status.recordingDuration !== undefined) {
        timer.textContent = formatDuration(status.recordingDuration);
      }
      break;

    case 'reconnecting':
      recordBtn.disabled = true;
      taskNote.disabled = true;
      errorContainer.classList.add('hidden');
      break;

    case 'error':
      recordBtn.disabled = true;
      taskNote.disabled = true;
      timerDisplay.classList.add('hidden');
      errorContainer.classList.remove('hidden');
      errorMessage.textContent = status.error || 'An error occurred';
      break;
  }
}

// Event Handlers
async function handleRecordClick(): Promise<void> {
  recordBtn.disabled = true;

  try {
    if (isRecording) {
      const result = await window.electronAPI.stopRecording();
      if (!result.success) {
        console.error('Failed to stop recording:', result.error);
      }
    } else {
      const note = taskNote.value.trim();
      const result = await window.electronAPI.startRecording(note);
      if (!result.success) {
        console.error('Failed to start recording:', result.error);
      }
    }
  } catch (error) {
    console.error('Recording action failed:', error);
  }
}

async function handleRetryClick(): Promise<void> {
  retryBtn.disabled = true;
  updateUI({ state: 'reconnecting', message: 'Reconnecting...' });

  try {
    const result = await window.electronAPI.retryConnection();
    if (!result.success) {
      updateUI({ 
        state: 'error', 
        message: 'Connection failed', 
        error: result.error 
      });
    }
  } catch (error) {
    updateUI({ 
      state: 'error', 
      message: 'Connection failed', 
      error: 'Unable to connect to OBS' 
    });
  } finally {
    retryBtn.disabled = false;
  }
}

async function handleOpenFolder(): Promise<void> {
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

// Initialize
function init(): void {
  // Set up event listeners
  recordBtn.addEventListener('click', handleRecordClick);
  retryBtn.addEventListener('click', handleRetryClick);
  openFolderBtn.addEventListener('click', handleOpenFolder);
  exportBtn.addEventListener('click', handleExport);

  // Listen for status updates from main process
  window.electronAPI.onStatusUpdate((status: SystemStatus) => {
    updateUI(status);
  });

  // Set initial state
  updateUI({ state: 'starting', message: 'Starting...' });
}

// Start the app
init();
