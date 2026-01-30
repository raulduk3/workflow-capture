import * as os from 'os';
import { FileManager } from './file-manager';

/**
 * Simplified session manager - no JSON metadata files
 * Metadata is encoded in the recording filename instead
 */
export class SessionManager {
  private fileManager: FileManager;
  private currentNote: string | null = null;
  private currentRecordingPath: string | null = null;
  private isCurrentlyRecording = false;

  constructor(fileManager: FileManager) {
    this.fileManager = fileManager;
  }

  private log(message: string): void {
    console.log(`[Session] ${message}`);
  }

  /**
   * Start a new recording session
   * Returns the full path where the recording should be saved
   */
  public async startSession(note: string): Promise<string> {
    if (this.isCurrentlyRecording) {
      this.log('Warning: Previous session not ended, ending now');
      this.endCurrentSession();
    }

    this.currentNote = note.trim() || 'No description';
    this.currentRecordingPath = await this.fileManager.getRecordingPath(this.currentNote);
    this.isCurrentlyRecording = true;

    this.log(`Session started: ${this.currentRecordingPath}`);
    return this.currentRecordingPath;
  }

  public endCurrentSession(): void {
    if (!this.isCurrentlyRecording) {
      this.log('No active session to end');
      return;
    }

    this.log(`Session ended: ${this.currentRecordingPath}`);
    this.currentNote = null;
    this.currentRecordingPath = null;
    this.isCurrentlyRecording = false;
  }

  public getCurrentRecordingPath(): string | null {
    return this.currentRecordingPath;
  }

  public getCurrentNote(): string | null {
    return this.currentNote;
  }

  public isRecording(): boolean {
    return this.isCurrentlyRecording;
  }

  public getMachineName(): string {
    return os.hostname();
  }

  /**
   * Get all recording files from the sessions directory
   */
  public async getAllRecordings(): Promise<string[]> {
    return this.fileManager.getRecordingFiles();
  }
}
