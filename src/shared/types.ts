/**
 * Shared type definitions for the Workflow Capture application
 * Used by both main and renderer processes
 */

/** Application state machine states */
export type SystemState = 'starting' | 'idle' | 'recording' | 'processing' | 'error';

/** System status payload sent to renderer */
export interface SystemStatus {
  state: SystemState;
  message: string;
  recordingDuration?: number;
  error?: string;
}

/** IPC operation result */
export interface IpcResult {
  success: boolean;
  error?: string;
  sessionId?: string;
  path?: string;
}

/** Screen capture configuration */
export interface CaptureConfig {
  sourceId: string;
  outputPath: string;
}

/** Result from capture stop operation */
export interface CaptureStoppedResult {
  success: boolean;
  error?: string;
}

/** Session metadata stored in session.json */
export interface SessionMetadata {
  session_id: string;
  started_at: string;
  ended_at: string | null;
  note: string;
  machine_name: string;
}

/** Active session information */
export interface Session {
  id: string;
  path: string;
  metadata: SessionMetadata;
}

/** Recorder status information */
export interface RecorderStatus {
  isRecording: boolean;
  outputPath?: string;
}

/** Application constants */
export const APP_CONSTANTS = {
  /** Maximum recording duration in milliseconds (5 minutes) */
  MAX_RECORDING_DURATION_MS: 5 * 60 * 1000,
  
  /** Application name used for file paths */
  APP_NAME: 'L7SWorkflowCapture',
  
  /** Sessions folder name */
  SESSIONS_FOLDER: 'Sessions',
  
  /** Recording timeout for stop operation (30 seconds) */
  RECORDING_STOP_TIMEOUT_MS: 30000,
  
  /** Timer update interval (1 second) */
  TIMER_INTERVAL_MS: 1000,
  
  /** Video bitrate in bits per second (5 Mbps) */
  VIDEO_BITRATE: 5_000_000,
} as const;
