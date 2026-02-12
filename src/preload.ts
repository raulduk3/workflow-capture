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
  saveRecordingData: (data: ArrayBuffer, outputPath: string) => Promise<IpcResult>;
  appendRecordingChunk: (data: ArrayBuffer, outputPath: string) => Promise<IpcResult>;
  finalizeRecording: (outputPath: string) => Promise<IpcResult>;
  notifyCaptureStopped: (result: CaptureStoppedResult) => Promise<void>;
  notifyCaptureStartFailed: (error: string) => Promise<void>;
  onStatusUpdate: (callback: (status: SystemStatus) => void) => () => void;
  onStartCapture: (callback: (config: CaptureConfig) => void) => () => void;
  onStopCapture: (callback: () => void) => () => void;
  onAbortCapture: (callback: () => void) => () => void;
  onRecordingSaved: (callback: (filename: string) => void) => () => void;
  onFocusTaskInput: (callback: () => void) => () => void;
}

const electronAPI: ElectronAPI = {
  startRecording: (note: string) => ipcRenderer.invoke('start-recording', note),
  stopRecording: () => ipcRenderer.invoke('stop-recording'),
  getStatus: () => ipcRenderer.invoke('get-status'),
  openSessionsFolder: () => ipcRenderer.invoke('open-sessions-folder'),
  saveRecordingData: (data: ArrayBuffer, outputPath: string) => 
    ipcRenderer.invoke('save-recording-chunk', data, outputPath),
  appendRecordingChunk: (data: ArrayBuffer, outputPath: string) =>
    ipcRenderer.invoke('append-recording-chunk', data, outputPath),
  finalizeRecording: (outputPath: string) =>
    ipcRenderer.invoke('finalize-recording', outputPath),
  notifyCaptureStopped: (result: CaptureStoppedResult) =>
    ipcRenderer.invoke('capture-stopped', result),
  notifyCaptureStartFailed: (error: string) =>
    ipcRenderer.invoke('capture-start-failed', error),

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

  onAbortCapture: (callback: () => void) => {
    const handler = () => callback();
    ipcRenderer.on('abort-capture', handler);
    return () => {
      ipcRenderer.removeListener('abort-capture', handler);
    };
  },
  
  onRecordingSaved: (callback: (filename: string) => void) => {
    const handler = (_event: IpcRendererEvent, filename: string) => callback(filename);
    ipcRenderer.on('recording-saved', handler);
    return () => {
      ipcRenderer.removeListener('recording-saved', handler);
    };
  },
  
  onFocusTaskInput: (callback: () => void) => {
    const handler = () => callback();
    ipcRenderer.on('focus-task-input', handler);
    return () => {
      ipcRenderer.removeListener('focus-task-input', handler);
    };
  },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}
