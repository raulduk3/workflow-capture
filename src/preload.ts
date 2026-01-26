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
}

export interface ElectronAPI {
  startRecording: (note: string) => Promise<IpcResult>;
  stopRecording: () => Promise<IpcResult>;
  getStatus: () => Promise<SystemStatus>;
  openSessionsFolder: () => Promise<IpcResult>;
  exportSessions: () => Promise<IpcResult>;
  retryConnection: () => Promise<IpcResult>;
  onStatusUpdate: (callback: (status: SystemStatus) => void) => void;
}

const electronAPI: ElectronAPI = {
  startRecording: (note: string) => ipcRenderer.invoke('start-recording', note),
  stopRecording: () => ipcRenderer.invoke('stop-recording'),
  getStatus: () => ipcRenderer.invoke('get-status'),
  openSessionsFolder: () => ipcRenderer.invoke('open-sessions-folder'),
  exportSessions: () => ipcRenderer.invoke('export-sessions'),
  retryConnection: () => ipcRenderer.invoke('retry-connection'),
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
