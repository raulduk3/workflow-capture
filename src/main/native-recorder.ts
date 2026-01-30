import { desktopCapturer, screen, BrowserWindow, ipcMain } from 'electron';
import * as path from 'path';
import { RecorderStatus, CaptureStoppedResult, APP_CONSTANTS } from '../shared/types';

// Note: ffmpeg-static kept as dependency for future batch MP4 conversion utility

// Re-export types for backwards compatibility
export type { RecorderStatus } from '../shared/types';

/**
 * Native screen recorder using Electron's desktopCapturer API
 * Records all screens as a single video, saves as WebM (VP9)
 * WebM is kept as primary format for best quality - convert to MP4 later if needed
 */
export class NativeRecorder {
  private isRecording = false;
  private outputDir: string | null = null;
  private outputWebmPath: string | null = null;
  private captureStoppedResolver: ((result: CaptureStoppedResult) => void) | null = null;

  constructor() {
    // Set up a persistent handler for capture-stopped
    ipcMain.handle('capture-stopped', async (_event, result: CaptureStoppedResult) => {
      if (this.captureStoppedResolver) {
        this.captureStoppedResolver(result);
        this.captureStoppedResolver = null;
      }
      return { success: true };
    });
  }

  private log(message: string): void {
    console.log(`[NativeRecorder] ${message}`);
  }

  /**
   * Get all available screen sources for capture
   */
  public async getScreenSources(): Promise<Electron.DesktopCapturerSource[]> {
    const sources = await desktopCapturer.getSources({
      types: ['screen'],
      thumbnailSize: { width: 150, height: 150 },
    });
    
    this.log(`Found ${sources.length} screen source(s)`);
    return sources;
  }

  /**
   * Calculate canvas dimensions for all displays combined
   */
  public getCanvasDimensions(): { width: number; height: number; displays: Electron.Display[] } {
    const displays = screen.getAllDisplays();
    
    let minX = Infinity, minY = Infinity;
    let maxX = -Infinity, maxY = -Infinity;
    
    for (const display of displays) {
      const { x, y, width, height } = display.bounds;
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x + width);
      maxY = Math.max(maxY, y + height);
    }
    
    return {
      width: maxX - minX,
      height: maxY - minY,
      displays,
    };
  }

  /**
   * Set the output directory for recording
   */
  public setOutputDirectory(dir: string): void {
    this.outputDir = dir;
    this.log(`Output directory set to: ${dir}`);
  }

  /**
   * Start recording - signals renderer to begin capture
   */
  public async startRecording(mainWindow: BrowserWindow): Promise<boolean> {
    if (this.isRecording) {
      this.log('Already recording');
      return false;
    }

    if (!this.outputDir) {
      throw new Error('Output directory not set');
    }

    // Get available sources
    const sources = await this.getScreenSources();
    if (sources.length === 0) {
      throw new Error('No screen sources available');
    }

    // Log all available sources for debugging
    this.log(`Available screen sources:`);
    sources.forEach((s, i) => {
      this.log(`  [${i}] id: ${s.id}, name: "${s.name}"`);
    });

    // Find the best source for multi-screen capture:
    // - On macOS: "Entire Screen" captures all displays
    // - On Windows: Look for "Entire screen" (case may vary) or screen:0:0 which is often all screens
    // - Fallback: Use the first screen source
    let selectedSource = sources.find(s => 
      s.name.toLowerCase() === 'entire screen' || 
      s.name.toLowerCase().includes('entire')
    );
    
    // On Windows, if no "Entire Screen", try to find screen 0 which often represents all displays
    if (!selectedSource) {
      selectedSource = sources.find(s => s.id.includes('screen:0:0'));
    }
    
    // Final fallback: first source
    if (!selectedSource) {
      selectedSource = sources[0];
    }
    
    this.log(`Selected source for recording: "${selectedSource.name}" (${selectedSource.id})`);
    
    // Set up output path - keep as WebM for best quality
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    this.outputWebmPath = path.join(this.outputDir, `recording_${timestamp}.webm`);

    this.log(`Output WebM: ${this.outputWebmPath}`);

    // Send start command to renderer with source ID
    mainWindow.webContents.send('start-capture', {
      sourceId: selectedSource.id,
      outputPath: this.outputWebmPath,
    });

    this.isRecording = true;
    return true;
  }

  /**
   * Stop recording - signals renderer to stop capture, then converts to MP4
   */
  public async stopRecording(mainWindow: BrowserWindow): Promise<string> {
    if (!this.isRecording) {
      throw new Error('Not currently recording');
    }

    this.log('Stopping recording...');

    // Signal renderer to stop and wait for file to be saved
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.captureStoppedResolver = null;
        reject(new Error('Timeout waiting for recording to stop'));
      }, APP_CONSTANTS.RECORDING_STOP_TIMEOUT_MS);

      // Set up resolver for capture-stopped event
      this.captureStoppedResolver = async (result: CaptureStoppedResult) => {
        clearTimeout(timeout);
        
        if (!result.success) {
          this.isRecording = false;
          reject(new Error(result.error || 'Failed to stop capture'));
          return;
        }

        // Keep WebM as primary format - no conversion needed
        const outputPath = this.outputWebmPath!;
        this.log(`Recording saved as WebM: ${outputPath}`);

        this.isRecording = false;
        this.outputWebmPath = null;
        
        resolve(outputPath);
      };

      mainWindow.webContents.send('stop-capture');
    });
  }

  /**
   * Check if currently recording
   */
  public getStatus(): RecorderStatus {
    return {
      isRecording: this.isRecording,
      outputPath: this.outputWebmPath || undefined,
    };
  }

  /**
   * Get the recording status
   */
  public getRecordingStatus(): boolean {
    return this.isRecording;
  }

  /**
   * Reset recorder state (for error recovery)
   */
  public reset(): void {
    this.isRecording = false;
    this.outputDir = null;
    this.outputWebmPath = null;
    this.captureStoppedResolver = null;
    this.log('Recorder state reset');
  }

  /**
   * Clean up resources when the app is closing
   */
  public dispose(): void {
    // Reject any pending capture-stopped resolver to prevent memory leaks
    if (this.captureStoppedResolver) {
      this.captureStoppedResolver({ success: false, error: 'Recorder disposed' });
      this.captureStoppedResolver = null;
    }
    
    try {
      ipcMain.removeHandler('capture-stopped');
    } catch {
      // Handler may already be removed, ignore error
    }
    
    this.isRecording = false;
    this.outputDir = null;
    this.outputWebmPath = null;
    this.log('Recorder disposed');
  }
}
