import { contextBridge, ipcRenderer } from 'electron';

export interface SystemStatus {
  state: 'starting' | 'idle' | 'recording' | 'reconnecting' | 'error';
  message: string;
  recordingDuration?: number;
  error?: string;
}

export interface IpcResult {
  success: boolean;
  error?: string;
  sessionId?: string;
  path?: string;
  report?: ObsDiagnosticReport;
}

export interface ObsDiagnosticReport {
  timestamp: string;
  platform: string;
  obsInstalled: boolean;
  obsPath: string;
  obsPathExists: boolean;
  profileExists: boolean;
  profilePath: string;
  sceneCollectionExists: boolean;
  sceneCollectionPath: string;
  globalConfigExists: boolean;
  globalConfigPath: string;
  webSocketEnabled: boolean;
  webSocketPort: number;
  sessionsDirectoryExists: boolean;
  sessionsPath: string;
  issues: string[];
  warnings: string[];
}

export interface ElectronAPI {
  startRecording: (note: string) => Promise<IpcResult>;
  stopRecording: () => Promise<IpcResult>;
  getStatus: () => Promise<SystemStatus>;
  openSessionsFolder: () => Promise<IpcResult>;
  exportSessions: () => Promise<IpcResult>;
  retryConnection: () => Promise<IpcResult>;
  runDiagnostics: () => Promise<IpcResult>;
  onStatusUpdate: (callback: (status: SystemStatus) => void) => void;
}

const electronAPI: ElectronAPI = {
  startRecording: (note: string) => ipcRenderer.invoke('start-recording', note),
  stopRecording: () => ipcRenderer.invoke('stop-recording'),
  getStatus: () => ipcRenderer.invoke('get-status'),
  openSessionsFolder: () => ipcRenderer.invoke('open-sessions-folder'),
  exportSessions: () => ipcRenderer.invoke('export-sessions'),
  retryConnection: () => ipcRenderer.invoke('retry-connection'),
  runDiagnostics: () => ipcRenderer.invoke('run-diagnostics'),
  onStatusUpdate: (callback: (status: SystemStatus) => void) => {
    ipcRenderer.on('system-status', (_event, status: SystemStatus) => {
      callback(status);
    });
  },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}
