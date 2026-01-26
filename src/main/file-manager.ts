import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { shell } from 'electron';
import archiver from 'archiver';
import { createWriteStream } from 'fs';

export class FileManager {
  private readonly sessionsPath: string;

  constructor() {
    const platform = os.platform();
    
    if (platform === 'win32') {
      this.sessionsPath = 'C:\\BandaStudy\\Sessions';
    } else if (platform === 'darwin') {
      this.sessionsPath = path.join(os.homedir(), 'BandaStudy', 'Sessions');
    } else {
      this.sessionsPath = path.join(os.homedir(), 'BandaStudy', 'Sessions');
    }
  }

  private log(message: string): void {
    console.log(`[FileManager] ${message}`);
  }

  public getSessionsPath(): string {
    return this.sessionsPath;
  }

  public async ensureSessionsDirectory(): Promise<void> {
    try {
      await fs.access(this.sessionsPath);
      this.log(`Sessions directory exists: ${this.sessionsPath}`);
    } catch {
      await fs.mkdir(this.sessionsPath, { recursive: true });
      this.log(`Sessions directory created: ${this.sessionsPath}`);
    }
  }

  public async createSessionDirectory(sessionId: string): Promise<string> {
    const sessionPath = path.join(this.sessionsPath, sessionId);
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
    const zipFilename = `BandaStudy_${hostname}_${date}.zip`;
    
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
