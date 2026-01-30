import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { shell } from 'electron';
import archiver from 'archiver';
import { createWriteStream } from 'fs';
import { APP_CONSTANTS } from '../shared/types';

export class FileManager {
  private readonly sessionsPath: string;

  constructor() {
    const platform = os.platform();
    
    if (platform === 'win32') {
      // Use C:\temp for Windows - user-agnostic location for easy extraction
      // This path is accessible by all users and simplifies RMM data collection
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
   * Get date folder name in YYYY-MM-DD format
   */
  private getDateFolder(): string {
    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }

  public async createSessionDirectory(sessionId: string): Promise<string> {
    // Organize sessions by date for better archiving
    // Structure: Sessions/YYYY-MM-DD/session-uuid/
    const dateFolder = this.getDateFolder();
    const datePath = path.join(this.sessionsPath, dateFolder);
    const sessionPath = path.join(datePath, sessionId);
    
    await fs.mkdir(sessionPath, { recursive: true });
    this.log(`Session directory created: ${sessionPath}`);
    return sessionPath;
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

  public async exportAllSessions(): Promise<string> {
    await this.ensureSessionsDirectory();

    const hostname = os.hostname();
    const date = new Date().toISOString().split('T')[0];
    const zipFilename = `L7SWorkflowCapture_${hostname}_${date}.zip`;
    
    // Export to user's Downloads folder or home directory
    const platform = os.platform();
    let exportDir: string;
    
    if (platform === 'win32') {
      exportDir = path.join(os.homedir(), 'Downloads');
    } else if (platform === 'darwin') {
      exportDir = path.join(os.homedir(), 'Downloads');
    } else {
      exportDir = os.homedir();
    }

    const exportPath = path.join(exportDir, zipFilename);

    this.log(`Exporting sessions to: ${exportPath}`);

    return new Promise((resolve, reject) => {
      const output = createWriteStream(exportPath);
      const archive = archiver('zip', {
        zlib: { level: 9 },
      });

      output.on('close', () => {
        this.log(`Export complete: ${archive.pointer()} bytes`);
        resolve(exportPath);
      });

      archive.on('error', (err) => {
        this.log(`Export error: ${err.message}`);
        reject(err);
      });

      archive.pipe(output);
      archive.directory(this.sessionsPath, 'Sessions');
      archive.finalize();
    });
  }

  public async getSessionFiles(sessionId: string): Promise<string[]> {
    const sessionPath = path.join(this.sessionsPath, sessionId);
    
    try {
      const files = await fs.readdir(sessionPath);
      return files.map(f => path.join(sessionPath, f));
    } catch (error) {
      this.log(`Error reading session files: ${error}`);
      return [];
    }
  }

  public async sessionExists(sessionId: string): Promise<boolean> {
    const sessionPath = path.join(this.sessionsPath, sessionId);
    
    try {
      await fs.access(sessionPath);
      return true;
    } catch {
      return false;
    }
  }

  public async deleteSession(sessionId: string): Promise<void> {
    const sessionPath = path.join(this.sessionsPath, sessionId);
    
    try {
      await fs.rm(sessionPath, { recursive: true, force: true });
      this.log(`Session deleted: ${sessionId}`);
    } catch (error) {
      this.log(`Error deleting session: ${error}`);
      throw error;
    }
  }
}
