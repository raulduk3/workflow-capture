import { ChildProcess, spawn, exec, execSync } from 'child_process';
import { EventEmitter } from 'events';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';

export interface ObsSupervisorEvents {
  'obs-started': () => void;
  'obs-stopped': () => void;
  'obs-crashed': () => void;
}

export class ObsSupervisor extends EventEmitter {
  private obsProcess: ChildProcess | null = null;
  private obsPid: number | null = null;
  private isShuttingDown: boolean = false;
  private restartAttempts: number = 0;
  private readonly maxRestartAttempts: number = 3;
  private readonly obsPath: string;
  private readonly profileName: string = 'L7S-ScreenCapture';
  private readonly sceneCollectionName: string = 'L7S-ScreenCapture';
  private monitorInterval: NodeJS.Timeout | null = null;
  private startupMode: 'normal' | 'safe' = 'normal';
  private bypassSafeModePrompt: boolean = true;

  constructor() {
    super();
    this.obsPath = this.getObsPath();
  }

  private log(message: string): void {
    console.log(`[OBS-Supervisor] ${message}`);
  }

  private getObsPath(): string {
    const platform = os.platform();
    
    if (platform === 'win32') {
      return 'C:\\Program Files\\obs-studio\\bin\\64bit\\obs64.exe';
    } else if (platform === 'darwin') {
      return '/Applications/OBS.app';
    } else {
      return '/usr/bin/obs';
    }
  }

  /**
   * Remove the OBS crash sentinel to prevent safe mode dialog
   * OBS creates .sentinel directory when starting and removes it on clean shutdown
   * If it exists on startup, OBS thinks it crashed and shows safe mode prompt
   */
  private removeCrashSentinel(): void {
    const platform = os.platform();
    let sentinelPath: string;
    
    if (platform === 'darwin') {
      sentinelPath = path.join(os.homedir(), 'Library', 'Application Support', 'obs-studio', '.sentinel');
    } else if (platform === 'win32') {
      sentinelPath = path.join(process.env.APPDATA || '', 'obs-studio', '.sentinel');
    } else {
      sentinelPath = path.join(os.homedir(), '.config', 'obs-studio', '.sentinel');
    }
    
    try {
      if (fs.existsSync(sentinelPath)) {
        fs.rmSync(sentinelPath, { recursive: true, force: true });
        this.log(`Removed crash sentinel: ${sentinelPath}`);
      }
    } catch (error) {
      this.log(`Failed to remove crash sentinel: ${error}`);
    }
  }

  public static async killOrphanedProcesses(): Promise<void> {
    const platform = os.platform();
    
    return new Promise((resolve) => {
      if (platform === 'win32') {
        exec('taskkill /F /IM obs64.exe /T', (error) => {
          if (error) {
            console.log('[OBS-Supervisor] No orphaned OBS processes found');
          } else {
            console.log('[OBS-Supervisor] Killed orphaned OBS processes');
          }
          resolve();
        });
      } else if (platform === 'darwin') {
        exec('pkill -f "OBS"', (error) => {
          if (error) {
            console.log('[OBS-Supervisor] No orphaned OBS processes found');
          } else {
            console.log('[OBS-Supervisor] Killed orphaned OBS processes');
          }
          resolve();
        });
      } else {
        exec('pkill -f obs', (error) => {
          if (error) {
            console.log('[OBS-Supervisor] No orphaned OBS processes found');
          } else {
            console.log('[OBS-Supervisor] Killed orphaned OBS processes');
          }
          resolve();
        });
      }
    });
  }

  private isObsRunning(): boolean {
    const platform = os.platform();
    
    try {
      if (platform === 'win32') {
        // Windows: Use tasklist to check for obs64.exe
        const result = execSync('tasklist /FI "IMAGENAME eq obs64.exe" /FO CSV /NH', { encoding: 'utf-8' });
        if (result.includes('obs64.exe')) {
          // Extract PID from CSV output: "obs64.exe","12345",...
          const match = result.match(/"obs64\.exe","(\d+)"/);
          if (match) {
            this.obsPid = parseInt(match[1], 10);
          }
          return true;
        }
        return false;
      } else if (platform === 'darwin') {
        // macOS: Use pgrep
        const result = execSync('pgrep -f "OBS.app/Contents/MacOS/OBS"', { encoding: 'utf-8' });
        const pids = result.trim().split('\n').filter(p => p);
        if (pids.length > 0) {
          this.obsPid = parseInt(pids[0], 10);
          return true;
        }
        return false;
      } else {
        // Linux: Use pgrep
        const result = execSync('pgrep -f obs', { encoding: 'utf-8' });
        const pids = result.trim().split('\n').filter(p => p);
        if (pids.length > 0) {
          this.obsPid = parseInt(pids[0], 10);
          return true;
        }
        return false;
      }
    } catch {
      return false;
    }
  }

  private startMonitoring(): void {
    const platform = os.platform();
    
    // Monitor OBS process to detect crashes
    this.monitorInterval = setInterval(() => {
      // On Windows/Linux with spawn, we rely on the 'exit' event
      // Only actively monitor on macOS where we use 'open' command
      if (platform === 'darwin' && !this.isShuttingDown && !this.isObsRunning()) {
        this.log('OBS process no longer running');
        this.stopMonitoring();
        this.obsPid = null;
        this.emit('obs-crashed');
        this.handleCrash();
      } else if (platform !== 'darwin' && !this.isShuttingDown && !this.obsProcess && this.obsPid) {
        // For Windows/Linux, check if we lost the process reference
        if (!this.isObsRunning()) {
          this.log('OBS process no longer running');
          this.stopMonitoring();
          this.obsPid = null;
          this.emit('obs-crashed');
          this.handleCrash();
        }
      }
    }, 2000);
  }

  private stopMonitoring(): void {
    if (this.monitorInterval) {
      clearInterval(this.monitorInterval);
      this.monitorInterval = null;
    }
  }

  public async start(): Promise<void> {
    // Remove crash sentinel to prevent safe mode dialog
    this.removeCrashSentinel();
    
    // Check if OBS is already running
    if (this.isObsRunning()) {
      this.log(`OBS already running with PID: ${this.obsPid}`);
      this.startMonitoring();
      this.emit('obs-started');
      return;
    }

    this.isShuttingDown = false;
    this.log(`Starting OBS from: ${this.obsPath}`);

    const platform = os.platform();

    if (platform === 'darwin') {
      // macOS: Use 'open' command to properly launch the app with profile
      return new Promise((resolve, reject) => {
        this.log('Using open command to launch OBS on macOS');
        
        // Use --args to pass arguments to OBS
        // Note: Do NOT use --safe-mode as it disables WebSockets entirely
        const argList: string[] = [
          `--profile "${this.profileName}"`,
          `--collection "${this.sceneCollectionName}"`,
          '--minimize-to-tray',
          '--disable-updater',
          '--disable-missing-files-check',
        ];

        const obsArgs = `--args ${argList.join(' ')}`;
        exec(`open -a "${this.obsPath}" ${obsArgs}`, (error) => {
          if (error) {
            this.log(`Failed to open OBS: ${error.message}`);
            reject(error);
            return;
          }

          this.log('OBS open command executed');
          this.restartAttempts = 0;
          
          // Wait for OBS to start and get its PID
          let attempts = 0;
          const maxAttempts = 30; // 15 seconds max
          
          const checkStarted = setInterval(() => {
            attempts++;
            if (this.isObsRunning()) {
              clearInterval(checkStarted);
              this.log(`OBS started with PID: ${this.obsPid}`);
              this.emit('obs-started');
              this.startMonitoring();
              
              // Give OBS more time to initialize WebSocket server
              this.log('Waiting for OBS WebSocket server to initialize...');
              setTimeout(() => {
                this.log('OBS initialization wait complete');
                resolve();
              }, 3000);
            } else if (attempts >= maxAttempts) {
              clearInterval(checkStarted);
              this.log('OBS failed to start within timeout');
              reject(new Error('OBS failed to start within timeout'));
            }
          }, 500);
        });
      });
    } else {
      // Windows/Linux: Use spawn directly with profile selection
      return new Promise((resolve, reject) => {
        try {
          const baseArgs: string[] = [
            '--minimize-to-tray',
            '--disable-updater',
            '--disable-missing-files-check',
            '--profile', this.profileName,
            '--collection', this.sceneCollectionName,
          ];

          // Windows-specific: allow multi-instance to avoid warnings
          if (platform === 'win32') {
            baseArgs.push('--multi');
          }

          // Note: Do NOT use --safe-mode as it disables WebSockets entirely

          const args = baseArgs;

          this.log(`Spawning OBS with args: ${JSON.stringify(args)}`);
          
          this.obsProcess = spawn(this.obsPath, args, {
            detached: false,
            stdio: 'ignore',
            windowsHide: true,
          });

          this.obsProcess.on('spawn', () => {
            this.log(`OBS spawned with PID: ${this.obsProcess?.pid}`);
            this.obsPid = this.obsProcess?.pid || null;
            this.restartAttempts = 0;
            this.emit('obs-started');
            this.startMonitoring();
            
            // Give OBS more time to initialize WebSocket server
            // Windows typically needs 6-10 seconds for full WebSocket initialization
            this.log('Waiting for OBS to initialize WebSocket server...');
            setTimeout(() => {
              this.log('OBS initialization wait complete');
              resolve();
            }, 8000);
          });

          this.obsProcess.on('error', (error) => {
            this.log(`OBS spawn error: ${error.message}`);
            this.obsProcess = null;
            this.obsPid = null;
            reject(error);
          });

          this.obsProcess.on('exit', (code, signal) => {
            this.log(`OBS exited with code: ${code}, signal: ${signal}`);
            this.obsProcess = null;
            this.obsPid = null;
            
            if (!this.isShuttingDown) {
              this.emit('obs-crashed');
              this.handleCrash();
            } else {
              this.emit('obs-stopped');
            }
          });

        } catch (error) {
          this.log(`Failed to start OBS: ${error}`);
          reject(error);
        }
      });
    }
  }

  private async handleCrash(): Promise<void> {
    if (this.restartAttempts >= this.maxRestartAttempts) {
      this.log(`Max restart attempts (${this.maxRestartAttempts}) reached`);
      return;
    }

    this.restartAttempts++;
    this.log(`Attempting restart ${this.restartAttempts}/${this.maxRestartAttempts}`);

    await new Promise(resolve => setTimeout(resolve, 1000));

    try {
      await this.start();
    } catch (error) {
      this.log(`Restart failed: ${error}`);
    }
  }

  public async stop(): Promise<void> {
    this.stopMonitoring();
    
    const platform = os.platform();
    
    // Check if OBS is running
    if (platform === 'darwin') {
      if (!this.isObsRunning()) {
        this.log('OBS not running');
        return;
      }
    } else if (!this.obsProcess) {
      this.log('OBS not running');
      return;
    }

    this.isShuttingDown = true;
    this.log('Stopping OBS...');

    return new Promise((resolve) => {
      if (platform === 'darwin') {
        // macOS: Use SIGTERM via pkill for reliable shutdown (AppleScript can fail with dialogs)
        this.log('Sending SIGTERM to OBS...');
        exec('pkill -TERM -f "OBS.app/Contents/MacOS/OBS"', (termError) => {
          if (termError) {
            this.log(`SIGTERM failed (OBS may already be stopped): ${termError.message}`);
            this.removeCrashSentinel();
            this.obsPid = null;
            this.emit('obs-stopped');
            resolve();
            return;
          }
          
          this.log('SIGTERM sent, waiting for graceful shutdown...');
          // Wait for OBS to shut down gracefully
          let attempts = 0;
          const maxAttempts = 10;
          const checkInterval = setInterval(() => {
            attempts++;
            if (!this.isObsRunning()) {
              clearInterval(checkInterval);
              this.log('OBS shut down gracefully');
              this.removeCrashSentinel();
              this.obsPid = null;
              this.emit('obs-stopped');
              resolve();
            } else if (attempts >= maxAttempts) {
              clearInterval(checkInterval);
              this.log('OBS still running after SIGTERM, force killing...');
              exec('pkill -KILL -f "OBS.app/Contents/MacOS/OBS"', () => {
                this.removeCrashSentinel();
                this.obsPid = null;
                this.emit('obs-stopped');
                resolve();
              });
            }
          }, 500);
        });
      } else {
        const forceKillTimeout = setTimeout(() => {
          if (this.obsProcess) {
            this.log('Force killing OBS');
            this.obsProcess.kill('SIGKILL');
          }
          resolve();
        }, 5000);

        if (this.obsProcess) {
          this.obsProcess.once('exit', () => {
            clearTimeout(forceKillTimeout);
            this.log('OBS stopped gracefully');
            resolve();
          });

          // Try graceful shutdown first
          if (platform === 'win32') {
            exec(`taskkill /PID ${this.obsProcess.pid}`, () => {
              // If taskkill fails, the timeout will handle it
            });
          } else {
            this.obsProcess.kill('SIGTERM');
          }
        } else {
          clearTimeout(forceKillTimeout);
          resolve();
        }
      }
    });
  }

  public isRunning(): boolean {
    const platform = os.platform();
    if (platform === 'darwin') {
      return this.isObsRunning();
    }
    return this.obsProcess !== null && !this.obsProcess.killed;
  }

  public getPid(): number | undefined {
    return this.obsPid || this.obsProcess?.pid;
  }

  // Optional configuration to control startup behavior
  public setStartupMode(mode: 'normal' | 'safe'): void {
    this.startupMode = mode;
  }

  public setBypassSafeModePrompt(bypass: boolean): void {
    this.bypassSafeModePrompt = bypass;
  }

  /**
   * Run comprehensive diagnostics to check OBS installation and configuration
   * Returns a diagnostic report with all issues found
   */
  public async runDiagnostics(): Promise<ObsDiagnosticReport> {
    const report: ObsDiagnosticReport = {
      timestamp: new Date().toISOString(),
      platform: os.platform(),
      obsInstalled: false,
      obsPath: this.obsPath,
      obsPathExists: false,
      profileExists: false,
      profilePath: '',
      sceneCollectionExists: false,
      sceneCollectionPath: '',
      globalConfigExists: false,
      globalConfigPath: '',
      webSocketEnabled: false,
      webSocketPort: 4455,
      sessionsDirectoryExists: false,
      sessionsPath: '',
      issues: [],
      warnings: []
    };

    const platform = os.platform();

    // Check OBS executable
    report.obsPathExists = fs.existsSync(this.obsPath);
    report.obsInstalled = report.obsPathExists;
    if (!report.obsPathExists) {
      report.issues.push(`OBS not found at: ${this.obsPath}`);
    } else {
      this.log(`[Diagnostics] OBS found at: ${this.obsPath}`);
    }

    // Determine config paths based on platform
    let configBasePath: string;
    if (platform === 'darwin') {
      configBasePath = path.join(os.homedir(), 'Library', 'Application Support', 'obs-studio');
    } else if (platform === 'win32') {
      configBasePath = path.join(process.env.APPDATA || '', 'obs-studio');
    } else {
      configBasePath = path.join(os.homedir(), '.config', 'obs-studio');
    }

    // Check global.ini (WebSocket settings)
    report.globalConfigPath = path.join(configBasePath, 'global.ini');
    report.globalConfigExists = fs.existsSync(report.globalConfigPath);
    if (!report.globalConfigExists) {
      report.issues.push(`OBS global config not found at: ${report.globalConfigPath}`);
    } else {
      this.log(`[Diagnostics] global.ini found at: ${report.globalConfigPath}`);
      // Parse global.ini to check WebSocket settings
      try {
        const globalConfig = fs.readFileSync(report.globalConfigPath, 'utf-8');
        const wsEnabledMatch = globalConfig.match(/ServerEnabled\s*=\s*(true|false)/i);
        const wsPortMatch = globalConfig.match(/ServerPort\s*=\s*(\d+)/);
        
        report.webSocketEnabled = wsEnabledMatch ? wsEnabledMatch[1].toLowerCase() === 'true' : false;
        report.webSocketPort = wsPortMatch ? parseInt(wsPortMatch[1], 10) : 4455;
        
        if (!report.webSocketEnabled) {
          report.issues.push('WebSocket server is NOT enabled in global.ini');
        } else {
          this.log(`[Diagnostics] WebSocket enabled on port ${report.webSocketPort}`);
        }

        // Check for SafeMode
        const safeModeMatch = globalConfig.match(/SafeMode\s*=\s*(true|false)/i);
        if (safeModeMatch && safeModeMatch[1].toLowerCase() === 'true') {
          report.warnings.push('SafeMode is enabled - this may cause issues');
        }
      } catch (err) {
        report.warnings.push(`Failed to parse global.ini: ${err}`);
      }
    }

    // Check profile
    report.profilePath = path.join(configBasePath, 'basic', 'profiles', this.profileName);
    report.profileExists = fs.existsSync(report.profilePath);
    if (!report.profileExists) {
      report.issues.push(`L7S profile not found at: ${report.profilePath}`);
    } else {
      this.log(`[Diagnostics] Profile found at: ${report.profilePath}`);
      // Check basic.ini exists within profile
      const basicIniPath = path.join(report.profilePath, 'basic.ini');
      if (!fs.existsSync(basicIniPath)) {
        report.issues.push(`Profile basic.ini not found at: ${basicIniPath}`);
      }
    }

    // Check scene collection
    report.sceneCollectionPath = path.join(configBasePath, 'basic', 'scenes', `${this.sceneCollectionName}.json`);
    report.sceneCollectionExists = fs.existsSync(report.sceneCollectionPath);
    if (!report.sceneCollectionExists) {
      report.issues.push(`L7S scene collection not found at: ${report.sceneCollectionPath}`);
    } else {
      this.log(`[Diagnostics] Scene collection found at: ${report.sceneCollectionPath}`);
    }

    // Check sessions directory
    if (platform === 'win32') {
      report.sessionsPath = 'C:\\BandaStudy\\Sessions';
    } else {
      report.sessionsPath = path.join(os.homedir(), 'BandaStudy', 'Sessions');
    }
    report.sessionsDirectoryExists = fs.existsSync(report.sessionsPath);
    if (!report.sessionsDirectoryExists) {
      report.warnings.push(`Sessions directory not found at: ${report.sessionsPath}`);
    } else {
      this.log(`[Diagnostics] Sessions directory found at: ${report.sessionsPath}`);
    }

    // Log summary
    this.log(`[Diagnostics] === Summary ===`);
    this.log(`[Diagnostics] OBS Installed: ${report.obsInstalled}`);
    this.log(`[Diagnostics] Profile Exists: ${report.profileExists}`);
    this.log(`[Diagnostics] Scene Collection Exists: ${report.sceneCollectionExists}`);
    this.log(`[Diagnostics] WebSocket Enabled: ${report.webSocketEnabled}`);
    this.log(`[Diagnostics] Issues: ${report.issues.length}`);
    this.log(`[Diagnostics] Warnings: ${report.warnings.length}`);
    
    for (const issue of report.issues) {
      this.log(`[Diagnostics] ISSUE: ${issue}`);
    }
    for (const warning of report.warnings) {
      this.log(`[Diagnostics] WARNING: ${warning}`);
    }

    return report;
  }
}

// Diagnostic report interface
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
