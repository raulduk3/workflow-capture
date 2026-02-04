import { desktopCapturer, screen, BrowserWindow, ipcMain } from 'electron';
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
   * Set the full output path for the recording file
   * @param filePath Full path including filename (e.g., /path/to/recording.webm)
   */
  public setOutputPath(filePath: string): void {
    this.outputWebmPath = filePath;
    this.log(`Output path set to: ${filePath}`);
  }

  /**
   * Start recording - signals renderer to begin capture
   */
  public async startRecording(mainWindow: BrowserWindow): Promise<boolean> {
    if (this.isRecording) {
      this.log('Already recording');
      return false;
    }

    if (!this.outputWebmPath) {
      throw new Error('Output path not set');
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

    // Calculate total canvas dimensions for all monitors
    const canvasDimensions = this.getCanvasDimensions();
    this.log(`Multi-monitor canvas: ${canvasDimensions.width}x${canvasDimensions.height} (${canvasDimensions.displays.length} display(s))`);
    
    // Calculate display offsets (normalized so minimum x,y is 0,0)
    const displays = screen.getAllDisplays();
    let minX = Infinity, minY = Infinity;
    for (const d of displays) {
      minX = Math.min(minX, d.bounds.x);
      minY = Math.min(minY, d.bounds.y);
    }
    
    const displayInfo = displays.map((d, i) => ({
      index: i,
      x: d.bounds.x - minX,
      y: d.bounds.y - minY,
      width: d.bounds.width,
      height: d.bounds.height,
      scaleFactor: d.scaleFactor,
    }));
    
    displayInfo.forEach((d) => {
      this.log(`  Display ${d.index}: ${d.width}x${d.height} at (${d.x}, ${d.y}), scaleFactor: ${d.scaleFactor}`);
    });

    // Find the best source for multi-screen capture:
    // Platform-specific behavior:
    // - macOS: "Entire Screen" captures all displays as one video
    // - Windows: Individual screens are listed; we capture all and composite them
    
    let selectedSource: Electron.DesktopCapturerSource | undefined;
    const platform = process.platform;
    const needsCompositing = platform === 'win32' && displays.length > 1;
    
    if (platform === 'darwin') {
      // macOS: Look for "Entire Screen" which captures all displays
      selectedSource = sources.find(s => 
        s.name.toLowerCase() === 'entire screen' || 
        s.name.toLowerCase().includes('entire')
      );
    } else if (platform === 'win32') {
      // Windows 10/11: desktopCapturer returns individual screens
      // We'll capture all screens and composite them in the renderer
      // First screen is used as primary; all screens sent for compositing
      selectedSource = sources.find(s => s.id.includes('screen:0:0'));
      
      if (!selectedSource) {
        selectedSource = sources.find(s => s.name === 'Screen 1');
      }
    } else {
      // Linux: Look for entire screen or first screen
      selectedSource = sources.find(s => 
        s.name.toLowerCase().includes('entire') ||
        s.id.includes('screen:0:0')
      );
    }
    
    // Final fallback: first screen source
    if (!selectedSource) {
      selectedSource = sources[0];
      this.log(`Warning: Using fallback source. Multi-monitor capture may only show primary display.`);
    }
    
    this.log(`Selected source for recording: "${selectedSource.name}" (${selectedSource.id}) [platform: ${platform}]`);
    this.log(`Multi-monitor compositing: ${needsCompositing ? 'enabled' : 'disabled'}`);
    
    // Output path already set via setOutputPath()
    this.log(`Output WebM: ${this.outputWebmPath}`);

    // Build list of all screen sources for Windows multi-monitor compositing
    const allScreenSources = needsCompositing 
      ? sources
          .filter(s => s.id.startsWith('screen:'))
          .map(s => ({ id: s.id, name: s.name }))
      : [];

    // Send start command to renderer with source ID and canvas dimensions for multi-monitor support
    mainWindow.webContents.send('start-capture', {
      sourceId: selectedSource.id,
      outputPath: this.outputWebmPath,
      canvasWidth: canvasDimensions.width,
      canvasHeight: canvasDimensions.height,
      // Windows multi-monitor compositing data
      needsCompositing,
      allScreenSources,
      displayInfo,
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
    this.outputWebmPath = null;
    this.log('Recorder disposed');
  }
}
