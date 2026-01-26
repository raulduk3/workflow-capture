import OBSWebSocket from 'obs-websocket-js';
import { EventEmitter } from 'events';

export interface ObsControllerEvents {
  'connected': () => void;
  'disconnected': () => void;
  'error': (error: Error) => void;
}

export class ObsController extends EventEmitter {
  private obs: OBSWebSocket;
  private connected: boolean = false;
  private readonly port: number = 4455;
  private readonly maxRetries: number = 10;
  private readonly retryInterval: number = 2000;

  constructor() {
    super();
    this.obs = new OBSWebSocket();
    this.setupEventHandlers();
  }

  private log(message: string): void {
    console.log(`[OBS-Controller] ${message}`);
  }

  private setupEventHandlers(): void {
    this.obs.on('ConnectionClosed', () => {
      this.log('WebSocket connection closed');
      this.connected = false;
      this.emit('disconnected');
    });

    this.obs.on('ConnectionError', (error) => {
      this.log(`WebSocket connection error: ${error.message}`);
      this.connected = false;
      this.emit('error', error);
    });
  }

  public async connect(): Promise<boolean> {
    for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
      this.log(`Connection attempt ${attempt}/${this.maxRetries}`);

      try {
        await this.obs.connect(`ws://127.0.0.1:${this.port}`);
        this.connected = true;
        this.log('Connected to OBS WebSocket');
        this.emit('connected');
        return true;
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'Unknown error';
        this.log(`Connection attempt ${attempt} failed: ${errorMessage}`);

        if (attempt < this.maxRetries) {
          await this.delay(this.retryInterval);
        }
      }
    }

    this.log('All connection attempts failed');
    return false;
  }

  public disconnect(): void {
    if (this.connected) {
      this.obs.disconnect();
      this.connected = false;
      this.log('Disconnected from OBS');
    }
  }

  public isConnected(): boolean {
    return this.connected;
  }

  public async setRecordDirectory(outputPath: string): Promise<void> {
    if (!this.connected) {
      throw new Error('Not connected to OBS');
    }

    this.log(`Setting record directory to: ${outputPath}`);

    try {
      await this.obs.call('SetRecordDirectory', {
        recordDirectory: outputPath,
      });
      this.log('Record directory set successfully');
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      this.log(`Failed to set record directory: ${errorMessage}`);
      throw error;
    }
  }

  public async startRecording(): Promise<void> {
    if (!this.connected) {
      throw new Error('Not connected to OBS');
    }

    this.log('Starting recording...');

    try {
      await this.obs.call('StartRecord');
      this.log('Recording started');
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      this.log(`Failed to start recording: ${errorMessage}`);
      throw error;
    }
  }

  public async stopRecording(): Promise<string | null> {
    if (!this.connected) {
      throw new Error('Not connected to OBS');
    }

    this.log('Stopping recording...');

    try {
      const response = await this.obs.call('StopRecord');
      this.log(`Recording stopped, output: ${response.outputPath}`);
      return response.outputPath;
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      this.log(`Failed to stop recording: ${errorMessage}`);
      throw error;
    }
  }

  public async getRecordingStatus(): Promise<boolean> {
    if (!this.connected) {
      throw new Error('Not connected to OBS');
    }

    try {
      const response = await this.obs.call('GetRecordStatus');
      return response.outputActive;
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      this.log(`Failed to get recording status: ${errorMessage}`);
      throw error;
    }
  }

  public async getRecordingTimecode(): Promise<string | null> {
    if (!this.connected) {
      throw new Error('Not connected to OBS');
    }

    try {
      const response = await this.obs.call('GetRecordStatus');
      return response.outputTimecode || null;
    } catch (error) {
      return null;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
