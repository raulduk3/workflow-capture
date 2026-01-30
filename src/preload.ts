import { contextBridge, ipcRenderer, IpcRendererEvent } from 'electron';
import type { 
  SystemStatus, 
  IpcResult, 
  CaptureConfig, 
  CaptureStoppedResult 
} from './shared/types';

// Re-export types for external use
export type { SystemStatus, IpcResult, CaptureConfig, CaptureStoppedResult };

export interface ElectronAPI {
  startRecording: (note: string) => Promise<IpcResult>;
  stopRecording: () => Promise<IpcResult>;
  getStatus: () => Promise<SystemStatus>;
  openSessionsFolder: () => Promise<IpcResult>;
  exportSessions: () => Promise<IpcResult>;
  saveRecordingData: (data: ArrayBuffer, outputPath: string) => Promise<IpcResult>;
  notifyCaptureStopped: (result: CaptureStoppedResult) => Promise<void>;
  onStatusUpdate: (callback: (status: SystemStatus) => void) => () => void;
  onStartCapture: (callback: (config: CaptureConfig) => void) => () => void;
  onStopCapture: (callback: () => void) => () => void;
  onRecordingSaved: (callback: (filename: string) => void) => () => void;
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
  
  // Return cleanup functions to prevent memory leaks
  onStatusUpdate: (callback: (status: SystemStatus) => void) => {
    const handler = (_event: IpcRendererEvent, status: SystemStatus) => callback(status);
    ipcRenderer.on('system-status', handler);
    return () => {
      ipcRenderer.removeListener('system-status', handler);
    };
  },
  
  onStartCapture: (callback: (config: CaptureConfig) => void) => {
    const handler = (_event: IpcRendererEvent, config: CaptureConfig) => callback(config);
    ipcRenderer.on('start-capture', handler);
    return () => {
      ipcRenderer.removeListener('start-capture', handler);
    };
  },
  
  onStopCapture: (callback: () => void) => {
    const handler = () => callback();
    ipcRenderer.on('stop-capture', handler);
    return () => {
      ipcRenderer.removeListener('stop-capture', handler);
    };
  },
  
  onRecordingSaved: (callback: (filename: string) => void) => {
    const handler = (_event: IpcRendererEvent, filename: string) => callback(filename);
    ipcRenderer.on('recording-saved', handler);
    return () => {
      ipcRenderer.removeListener('recording-saved', handler);
    };
  },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}
