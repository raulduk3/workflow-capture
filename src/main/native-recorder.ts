import { desktopCapturer, screen, BrowserWindow, ipcMain } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import ffmpegPath from 'ffmpeg-static';
import { spawn } from 'child_process';

export interface RecorderStatus {
  isRecording: boolean;
  outputPath?: string;
}

interface CaptureStoppedResult {
  success: boolean;
  error?: string;
}

/**
 * Native screen recorder using Electron's desktopCapturer API
 * Records all screens as a single video, saves as MP4
 */
export class NativeRecorder {
  private isRecording = false;
  private outputDir: string | null = null;
  private tempWebmPath: string | null = null;
  private finalMp4Path: string | null = null;
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

    // Use the "Entire Screen" source if available, otherwise first screen
    const entireScreen = sources.find(s => s.name === 'Entire Screen') || sources[0];
    
    // Set up output paths
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    this.tempWebmPath = path.join(this.outputDir, `recording_${timestamp}.webm`);
    this.finalMp4Path = path.join(this.outputDir, `recording_${timestamp}.mp4`);

    this.log(`Starting recording, source: ${entireScreen.name}`);
    this.log(`Temp WebM: ${this.tempWebmPath}`);
    this.log(`Final MP4: ${this.finalMp4Path}`);

    // Send start command to renderer with source ID
    mainWindow.webContents.send('start-capture', {
      sourceId: entireScreen.id,
      outputPath: this.tempWebmPath,
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
      }, 30000);

      // Set up resolver for capture-stopped event
      this.captureStoppedResolver = async (result: CaptureStoppedResult) => {
        clearTimeout(timeout);
        
        if (!result.success) {
          this.isRecording = false;
          reject(new Error(result.error || 'Failed to stop capture'));
          return;
        }

        try {
          // Convert WebM to MP4
          await this.convertToMp4();
          
          // Clean up temp WebM file
          if (this.tempWebmPath && fs.existsSync(this.tempWebmPath)) {
            fs.unlinkSync(this.tempWebmPath);
            this.log('Cleaned up temp WebM file');
          }

          this.isRecording = false;
          const outputPath = this.finalMp4Path!;
          this.tempWebmPath = null;
          this.finalMp4Path = null;
          
          resolve(outputPath);
        } catch (error) {
          this.isRecording = false;
          reject(error);
        }
      };

      mainWindow.webContents.send('stop-capture');
    });
  }

  /**
   * Convert WebM to MP4 using ffmpeg
   */
  private async convertToMp4(): Promise<void> {
    if (!this.tempWebmPath || !this.finalMp4Path) {
      throw new Error('Output paths not set');
    }

    if (!fs.existsSync(this.tempWebmPath)) {
      throw new Error(`WebM file not found: ${this.tempWebmPath}`);
    }

    this.log(`Converting to MP4: ${this.tempWebmPath} -> ${this.finalMp4Path}`);

    return new Promise((resolve, reject) => {
      const ffmpeg = spawn(ffmpegPath!, [
        '-i', this.tempWebmPath!,
        '-c:v', 'libx264',
        '-preset', 'fast',
        '-crf', '23',
        '-y', // Overwrite output file
        this.finalMp4Path!,
      ]);

      let stderr = '';

      ffmpeg.stderr.on('data', (data) => {
        stderr += data.toString();
      });

      ffmpeg.on('close', (code) => {
        if (code === 0) {
          this.log('MP4 conversion complete');
          resolve();
        } else {
          this.log(`FFmpeg error: ${stderr}`);
          reject(new Error(`FFmpeg exited with code ${code}`));
        }
      });

      ffmpeg.on('error', (err) => {
        reject(new Error(`Failed to run FFmpeg: ${err.message}`));
      });
    });
  }

  /**
   * Check if currently recording
   */
  public getStatus(): RecorderStatus {
    return {
      isRecording: this.isRecording,
      outputPath: this.finalMp4Path || undefined,
    };
  }

  /**
   * Get the recording status
   */
  public getRecordingStatus(): boolean {
    return this.isRecording;
  }
}
