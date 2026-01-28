import { contextBridge, ipcRenderer } from 'electron';

export interface SystemStatus {
  state: 'starting' | 'idle' | 'recording' | 'processing' | 'error';
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

export interface CaptureConfig {
  sourceId: string;
  outputPath: string;
}

export interface CaptureStoppedResult {
  success: boolean;
  error?: string;
}

export interface ElectronAPI {
  startRecording: (note: string) => Promise<IpcResult>;
  stopRecording: () => Promise<IpcResult>;
  getStatus: () => Promise<SystemStatus>;
  openSessionsFolder: () => Promise<IpcResult>;
  exportSessions: () => Promise<IpcResult>;
  saveRecordingData: (data: ArrayBuffer, outputPath: string) => Promise<IpcResult>;
  notifyCaptureStopped: (result: CaptureStoppedResult) => Promise<void>;
  onStatusUpdate: (callback: (status: SystemStatus) => void) => void;
  onStartCapture: (callback: (config: CaptureConfig) => void) => void;
  onStopCapture: (callback: () => void) => void;
}

const electronAPI: ElectronAPI = {
  startRecording: (note: string) => ipcRenderer.invoke('start-recording', note),
  stopRecording: () => ipcRenderer.invoke('stop-recording'),
  getStatus: () => ipcRenderer.invoke('get-status'),
  openSessionsFolder: () => ipcRenderer.invoke('open-sessions-folder'),
  exportSessions: () => ipcRenderer.invoke('export-sessions'),
  saveRecordingData: (data: ArrayBuffer, outputPath: string) => 
    ipcRenderer.invoke('save-recording-chunk', data, outputPath),
  notifyCaptureStopped: (result: CaptureStoppedResult) => 
    ipcRenderer.invoke('capture-stopped', result),
  onStatusUpdate: (callback: (status: SystemStatus) => void) => {
    ipcRenderer.on('system-status', (_event, status: SystemStatus) => {
      callback(status);
    });
  },
  onStartCapture: (callback: (config: CaptureConfig) => void) => {
    ipcRenderer.on('start-capture', (_event, config: CaptureConfig) => {
      callback(config);
    });
  },
  onStopCapture: (callback: () => void) => {
    ipcRenderer.on('stop-capture', () => {
      callback();
    });
  },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}
