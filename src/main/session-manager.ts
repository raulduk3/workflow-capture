import { v4 as uuidv4 } from 'uuid';
import * as os from 'os';
import * as fs from 'fs/promises';
import * as path from 'path';
import { FileManager } from './file-manager';

export interface SessionMetadata {
  session_id: string;
  started_at: string;
  ended_at: string | null;
  note: string;
  machine_name: string;
}

export interface Session {
  id: string;
  path: string;
  metadata: SessionMetadata;
}

export class SessionManager {
  private fileManager: FileManager;
  private currentSession: Session | null = null;

  constructor(fileManager: FileManager) {
    this.fileManager = fileManager;
  }

  private log(message: string): void {
    console.log(`[Session] ${message}`);
  }

  public async createSession(note: string): Promise<Session> {
    if (this.currentSession) {
      this.log('Warning: Previous session not ended, ending now');
      await this.endCurrentSession();
    }

    const sessionId = uuidv4();
    const sessionPath = await this.fileManager.createSessionDirectory(sessionId);

    const metadata: SessionMetadata = {
      session_id: sessionId,
      started_at: new Date().toISOString(),
      ended_at: null,
      note: note.trim() || 'No description',
      machine_name: os.hostname(),
    };

    this.currentSession = {
      id: sessionId,
      path: sessionPath,
      metadata,
    };

    // Write initial metadata
    await this.saveMetadata();

    this.log(`Session created: ${sessionId}`);
    return this.currentSession;
  }

  public async endCurrentSession(): Promise<void> {
    if (!this.currentSession) {
      this.log('No active session to end');
      return;
    }

    this.currentSession.metadata.ended_at = new Date().toISOString();
    await this.saveMetadata();

    this.log(`Session ended: ${this.currentSession.id}`);
    this.currentSession = null;
  }

  public getCurrentSession(): Session | null {
    return this.currentSession;
  }

  public isRecording(): boolean {
    return this.currentSession !== null;
  }

  private async saveMetadata(): Promise<void> {
    if (!this.currentSession) {
      return;
    }

    const metadataPath = path.join(this.currentSession.path, 'session.json');
    const metadataJson = JSON.stringify(this.currentSession.metadata, null, 2);

    await fs.writeFile(metadataPath, metadataJson, 'utf-8');
    this.log(`Metadata saved to: ${metadataPath}`);
  }

  public async getAllSessions(): Promise<SessionMetadata[]> {
    const sessions: SessionMetadata[] = [];
    const sessionsDir = this.fileManager.getSessionsPath();

    try {
      const entries = await fs.readdir(sessionsDir, { withFileTypes: true });

      for (const entry of entries) {
        if (entry.isDirectory()) {
          const metadataPath = path.join(sessionsDir, entry.name, 'session.json');
          
          try {
            const content = await fs.readFile(metadataPath, 'utf-8');
            const metadata = JSON.parse(content) as SessionMetadata;
            sessions.push(metadata);
          } catch {
            // Skip directories without valid metadata
            this.log(`Skipping invalid session directory: ${entry.name}`);
          }
        }
      }
    } catch (error) {
      this.log(`Error reading sessions: ${error}`);
    }

    // Sort by started_at descending
    sessions.sort((a, b) => {
      return new Date(b.started_at).getTime() - new Date(a.started_at).getTime();
    });

    return sessions;
  }
}
