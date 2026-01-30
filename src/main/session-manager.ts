import { v4 as uuidv4 } from 'uuid';
import * as os from 'os';
import * as fs from 'fs/promises';
import * as path from 'path';
import { FileManager } from './file-manager';
import { SessionMetadata, Session } from '../shared/types';

// Re-export types for backwards compatibility
export type { SessionMetadata, Session } from '../shared/types';

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
      const dateEntries = await fs.readdir(sessionsDir, { withFileTypes: true });

      for (const dateEntry of dateEntries) {
        if (dateEntry.isDirectory()) {
          const datePath = path.join(sessionsDir, dateEntry.name);
          
          // Check if this is a date folder (YYYY-MM-DD) or a legacy session folder
          const isDateFolder = /^\d{4}-\d{2}-\d{2}$/.test(dateEntry.name);
          
          if (isDateFolder) {
            // New date-organized structure: Sessions/YYYY-MM-DD/session-uuid/
            const sessionEntries = await fs.readdir(datePath, { withFileTypes: true });
            
            for (const sessionEntry of sessionEntries) {
              if (sessionEntry.isDirectory()) {
                const metadataPath = path.join(datePath, sessionEntry.name, 'session.json');
                
                try {
                  const content = await fs.readFile(metadataPath, 'utf-8');
                  const metadata = JSON.parse(content) as SessionMetadata;
                  sessions.push(metadata);
                } catch {
                  this.log(`Skipping invalid session directory: ${dateEntry.name}/${sessionEntry.name}`);
                }
              }
            }
          } else {
            // Legacy structure: Sessions/session-uuid/ (for backwards compatibility)
            const metadataPath = path.join(datePath, 'session.json');
            
            try {
              const content = await fs.readFile(metadataPath, 'utf-8');
              const metadata = JSON.parse(content) as SessionMetadata;
              sessions.push(metadata);
            } catch {
              this.log(`Skipping invalid session directory: ${dateEntry.name}`);
            }
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
