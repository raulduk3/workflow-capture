import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { shell } from 'electron';
import { APP_CONSTANTS } from '../shared/types';

export class FileManager {
  private readonly sessionsPath: string;

  constructor() {
    const platform = os.platform();
    
    if (platform === 'win32') {
      // Use C:\temp for Windows - user-agnostic location for easy extraction
      // This path is accessible by all users and simplifies RMM data collection
      // Flat structure: all .webm files directly in Sessions folder
      this.sessionsPath = path.join('C:', 'temp', APP_CONSTANTS.APP_NAME, APP_CONSTANTS.SESSIONS_FOLDER);
    } else {
      // macOS and Linux use home directory
      this.sessionsPath = path.join(os.homedir(), APP_CONSTANTS.APP_NAME, APP_CONSTANTS.SESSIONS_FOLDER);
    }
  }

  private log(message: string): void {
    console.log(`[FileManager] ${message}`);
  }

  public getSessionsPath(): string {
    return this.sessionsPath;
  }

  public async ensureSessionsDirectory(): Promise<void> {
    this.log(`Ensuring sessions directory at: ${this.sessionsPath}`);
    try {
      await fs.access(this.sessionsPath);
      this.log(`Sessions directory exists: ${this.sessionsPath}`);
    } catch {
      try {
        await fs.mkdir(this.sessionsPath, { recursive: true });
        this.log(`Sessions directory created: ${this.sessionsPath}`);
      } catch (mkdirError) {
        const errorMessage = mkdirError instanceof Error ? mkdirError.message : String(mkdirError);
        this.log(`Failed to create sessions directory: ${errorMessage}`);
        throw new Error(`Cannot create sessions directory at ${this.sessionsPath}: ${errorMessage}`);
      }
    }
  }

  /**
   * Sanitize a string for use in filenames
   * Replaces invalid characters with underscores and limits length
   */
  public sanitizeFilename(input: string, maxLength: number = 50): string {
    // Replace invalid filename characters with underscores
    let sanitized = input
      .replace(/[<>:"/\\|?*\x00-\x1f]/g, '_')  // Invalid filename chars
      .replace(/\s+/g, '_')                      // Spaces to underscores
      .replace(/_+/g, '_')                       // Collapse multiple underscores
      .replace(/^_|_$/g, '');                    // Trim leading/trailing underscores
    
    // Limit length
    if (sanitized.length > maxLength) {
      sanitized = sanitized.substring(0, maxLength);
    }
    
    return sanitized || 'no-description';
  }

  /**
   * Generate a recording filename with metadata encoded
   * Format: YYYY-MM-DD_HHMMSS_machineName_taskDescription.webm
   */
  public generateRecordingFilename(note: string): string {
    const now = new Date();
    const date = now.toISOString().split('T')[0]; // YYYY-MM-DD
    const time = now.toTimeString().split(' ')[0].replace(/:/g, ''); // HHMMSS
    const machine = this.sanitizeFilename(os.hostname(), 20);
    const task = this.sanitizeFilename(note || 'no-description', 50);
    
    return `${date}_${time}_${machine}_${task}.webm`;
  }

  /**
   * Get the full path for a new recording file
   */
  public async getRecordingPath(note: string): Promise<string> {
    await this.ensureSessionsDirectory();
    const filename = this.generateRecordingFilename(note);
    return path.join(this.sessionsPath, filename);
  }

  public async openSessionsFolder(): Promise<void> {
    await this.ensureSessionsDirectory();
    const result = await shell.openPath(this.sessionsPath);
    
    if (result) {
      this.log(`Failed to open folder: ${result}`);
      throw new Error(`Failed to open folder: ${result}`);
    }
    
    this.log(`Opened sessions folder: ${this.sessionsPath}`);
  }

  /**
   * Get all recording files in the sessions directory
   */
  public async getRecordingFiles(): Promise<string[]> {
    try {
      const files = await fs.readdir(this.sessionsPath);
      return files
        .filter(f => f.endsWith('.webm'))
        .map(f => path.join(this.sessionsPath, f));
    } catch (error) {
      this.log(`Error reading recording files: ${error}`);
      return [];
    }
  }

  /**
   * Delete a recording file
   */
  public async deleteRecording(filename: string): Promise<void> {
    const filePath = path.join(this.sessionsPath, filename);
    
    try {
      await fs.unlink(filePath);
      this.log(`Recording deleted: ${filename}`);
    } catch (error) {
      this.log(`Error deleting recording: ${error}`);
      throw error;
    }
  }
}
