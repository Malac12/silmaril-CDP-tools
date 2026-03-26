const { app, BrowserWindow, ipcMain, shell, screen } = require('electron');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { spawn, execFile } = require('child_process');

const SIDEBAR_WIDTH = 430;
const MIN_WINDOW_HEIGHT = 320;
const BROWSER_POLL_MS = 2500;
const DOCK_POLL_MS = 1500;
const REPO_ROOT = path.resolve(__dirname, '..');
const SILMARIL_COMMAND = path.join(REPO_ROOT, 'silmaril.cmd');
const DEFAULT_CHROME_PORT = 9222;
const DEFAULT_USER_DATA_DIR = 'C:\\Temp\\cdp-profile-isolated';
const DEFAULT_ICON_PATH = 'C:\\Users\\hangx\\Desktop\\icon.png';
const CODEX_CMD_PATH = path.join(process.env.APPDATA || '', 'npm', 'codex.cmd');

const DEFAULT_SETTINGS = {
  approvalMode: 'confirm_mutations',
  docked: true,
  autoLaunch: true,
  theme: 'peach-beige'
};

let mainWindow = null;
let browserPollTimer = null;
let dockPollTimer = null;
let settings = null;
let bridge = null;
let chromeState = {
  connected: false,
  port: DEFAULT_CHROME_PORT,
  userDataDir: DEFAULT_USER_DATA_DIR,
  browser: '',
  webSocketDebuggerUrl: '',
  lastError: '',
  lastCheckedAt: 0
};
let transcriptEntries = [];
let activityEntries = [];
let pendingApproval = null;
let nextEventId = 1;

function hasArg(flag) {
  return process.argv.includes(flag);
}

function getArgValue(flag, fallbackValue) {
  const match = process.argv.find((arg) => arg.startsWith(flag + '='));
  if (!match) {
    return fallbackValue;
  }

  return match.slice(flag.length + 1);
}

function getChromeConfig() {
  const rawPort = getArgValue('--chrome-port', String(DEFAULT_CHROME_PORT));
  const parsedPort = Number.parseInt(rawPort, 10);
  return {
    port: Number.isFinite(parsedPort) ? parsedPort : DEFAULT_CHROME_PORT,
    userDataDir: getArgValue('--chrome-user-data-dir', DEFAULT_USER_DATA_DIR)
  };
}

function resolveAppIcon() {
  const explicitPath = getArgValue('--icon-path', '');
  const candidates = [explicitPath, DEFAULT_ICON_PATH].filter(Boolean);
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return undefined;
}

function getSettingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function loadSettings() {
  const settingsPath = getSettingsPath();
  try {
    if (!fs.existsSync(settingsPath)) {
      return { ...DEFAULT_SETTINGS };
    }

    const raw = fs.readFileSync(settingsPath, 'utf8');
    const parsed = JSON.parse(raw);
    return { ...DEFAULT_SETTINGS, ...parsed };
  }
  catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function saveSettings(nextSettings) {
  const settingsPath = getSettingsPath();
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify(nextSettings, null, 2), 'utf8');
}

function createEventId(prefix) {
  const id = `${prefix}-${nextEventId}`;
  nextEventId += 1;
  return id;
}

function emitRenderer(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

function pushTranscript(entry) {
  const completeEntry = {
    id: createEventId('message'),
    timestamp: Date.now(),
    ...entry
  };
  transcriptEntries.push(completeEntry);
  emitRenderer('bridge:transcript', completeEntry);
  return completeEntry;
}

function pushActivity(entry) {
  const completeEntry = {
    id: createEventId('activity'),
    timestamp: Date.now(),
    ...entry
  };
  activityEntries.push(completeEntry);
  emitRenderer('bridge:activity', completeEntry);
  return completeEntry;
}

function setPendingApproval(approval) {
  pendingApproval = approval;
  emitRenderer('bridge:pending-approval', pendingApproval);
}

function getSnapshot() {
  return {
    chromeState,
    sessionState: bridge ? bridge.getState() : null,
    settings,
    transcriptEntries,
    activityEntries,
    pendingApproval
  };
}

function runPowerShell(script, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const encodedScript = Buffer.from(script, 'utf16le').toString('base64');
    execFile(
      'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encodedScript],
      { windowsHide: true, timeout: timeoutMs },
      (error, stdout, stderr) => {
        if (error) {
          reject(new Error(stderr || stdout || error.message));
          return;
        }
        resolve((stdout || '').trim());
      }
    );
  });
}

async function getChromeWindowBounds(chromeConfig) {
  const script = `
$ErrorActionPreference = 'Stop'
$userDataDir = ${JSON.stringify(chromeConfig.userDataDir)}
$userDataPattern = [regex]::Escape($userDataDir)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NativeBridgeWindow {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
"@

$processes = Get-CimInstance Win32_Process | Where-Object {
  $name = [string]$_.Name
  (
    $name -ieq 'chrome.exe' -or
    $name -ieq 'chromium.exe' -or
    $name -ieq 'msedge.exe'
  ) -and
  -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
  ([string]$_.CommandLine) -match $userDataPattern
}

$candidates = @()
foreach ($proc in $processes) {
  $windowProc = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
  if ($null -eq $windowProc -or $windowProc.MainWindowHandle -eq 0) {
    continue
  }

  $rect = New-Object NativeBridgeWindow+RECT
  [void][NativeBridgeWindow]::GetWindowRect([IntPtr]$windowProc.MainWindowHandle, [ref]$rect)

  $width = [int]($rect.Right - $rect.Left)
  $height = [int]($rect.Bottom - $rect.Top)
  if ($width -le 0 -or $height -le 0) {
    continue
  }

  $candidates += [pscustomobject]@{
    processId = [int]$windowProc.Id
    processName = [string]$proc.Name
    windowHandle = [string]$windowProc.MainWindowHandle
    title = [string]$windowProc.MainWindowTitle
    x = [int]$rect.Left
    y = [int]$rect.Top
    width = $width
    height = $height
    area = [long]$width * [long]$height
  }
}

if ($candidates.Count -gt 0) {
  $candidates |
    Sort-Object -Property area -Descending |
    Select-Object -First 1 |
    ConvertTo-Json -Compress
  exit 0
}

exit 1
`;

  const raw = await runPowerShell(script, 7000);
  return JSON.parse(raw);
}

function convertPhysicalRectToDip(rect) {
  if (!rect || typeof screen.screenToDipPoint !== 'function') {
    return rect;
  }

  try {
    const topLeft = screen.screenToDipPoint({
      x: Math.round(rect.x),
      y: Math.round(rect.y)
    });
    const bottomRight = screen.screenToDipPoint({
      x: Math.round(rect.x + rect.width),
      y: Math.round(rect.y + rect.height)
    });

    return {
      ...rect,
      x: topLeft.x,
      y: topLeft.y,
      width: Math.max(1, bottomRight.x - topLeft.x),
      height: Math.max(1, bottomRight.y - topLeft.y)
    };
  }
  catch {
    return rect;
  }
}

function probeChromeConnection(chromeConfig) {
  return new Promise((resolve) => {
    const request = http.get(
      {
        hostname: '127.0.0.1',
        port: chromeConfig.port,
        path: '/json/version',
        timeout: 2500
      },
      (response) => {
        let body = '';
        response.setEncoding('utf8');
        response.on('data', (chunk) => {
          body += chunk;
        });
        response.on('end', () => {
          try {
            const payload = JSON.parse(body);
            resolve({
              connected: true,
              browser: payload.Browser || '',
              webSocketDebuggerUrl: payload.webSocketDebuggerUrl || '',
              lastError: ''
            });
          }
          catch (error) {
            resolve({
              connected: false,
              browser: '',
              webSocketDebuggerUrl: '',
              lastError: error.message
            });
          }
        });
      }
    );

    request.on('timeout', () => {
      request.destroy(new Error('Timed out connecting to Chrome CDP.'));
    });
    request.on('error', (error) => {
      resolve({
        connected: false,
        browser: '',
        webSocketDebuggerUrl: '',
        lastError: error.message
      });
    });
  });
}

async function refreshChromeState() {
  const nextState = await probeChromeConnection(chromeState);
  chromeState = {
    ...chromeState,
    ...nextState,
    lastCheckedAt: Date.now()
  };
  emitRenderer('bridge:chrome-state', chromeState);
}

async function syncWindowToChrome() {
  if (!mainWindow || mainWindow.isDestroyed() || !settings.docked) {
    return;
  }

  try {
    const rawBounds = await getChromeWindowBounds(chromeState);
    const bounds = convertPhysicalRectToDip(rawBounds);
    const targetWidth = SIDEBAR_WIDTH;
    const targetHeight = Math.max(1, Math.round(bounds.height));

    const display = screen.getDisplayMatching({
      x: Math.round(bounds.x),
      y: Math.round(bounds.y),
      width: Math.max(100, Math.round(bounds.width)),
      height: Math.max(100, Math.round(bounds.height))
    });
    const workArea = display.workArea;

    const rightEdgeX = Math.round(bounds.x + bounds.width);
    const maxX = Math.max(workArea.x, (workArea.x + workArea.width) - targetWidth);
    const x = Math.min(Math.max(workArea.x, rightEdgeX), maxX);

    const y = Math.min(
      Math.max(workArea.y, Math.round(bounds.y)),
      Math.max(workArea.y, (workArea.y + workArea.height) - targetHeight)
    );

    mainWindow.setMinimumSize(360, 240);
    mainWindow.setAlwaysOnTop(true, 'floating');
    mainWindow.setBounds({
      x,
      y,
      width: targetWidth,
      height: targetHeight
    }, false);
  }
  catch {
    // Ignore docking failures; the app remains usable as a normal window.
  }
}

function parseApprovalRequest(text) {
  if (!/^APPROVAL REQUIRED:/i.test(text)) {
    return null;
  }

  const commandMatch = text.match(/^COMMAND:\s*(.+)$/im);
  const reasonMatch = text.match(/^REASON:\s*(.+)$/im);
  return {
    id: createEventId('approval'),
    summary: text.split(/\r?\n/, 1)[0].replace(/^APPROVAL REQUIRED:\s*/i, '').trim(),
    command: commandMatch ? commandMatch[1].trim() : '',
    reason: reasonMatch ? reasonMatch[1].trim() : '',
    raw: text,
    createdAt: Date.now()
  };
}

class CodexBridge {
  constructor(chromeConfig) {
    this.chromeConfig = chromeConfig;
    this.codexCommand = fs.existsSync(CODEX_CMD_PATH) ? CODEX_CMD_PATH : 'codex.cmd';
    this.threadId = null;
    this.child = null;
    this.state = {
      runState: 'idle',
      lastError: '',
      threadId: null,
      activePrompt: ''
    };
  }

  getState() {
    return { ...this.state };
  }

  setState(patch) {
    this.state = {
      ...this.state,
      ...patch,
      threadId: this.threadId
    };
    emitRenderer('bridge:session-state', this.getState());
  }

  buildPrompt(userPrompt) {
    const lines = [
      'You are Codex running through a Windows desktop bridge UI.',
      `Chrome isolated CDP is already running on port ${this.chromeConfig.port}.`,
      `Use Silmaril through this exact command path when you need browser automation: ${SILMARIL_COMMAND}`,
      'Use PowerShell syntax for browser actions.',
      'Prefer Silmaril JSON output so the UI can stay synchronized.',
      'When reporting results, be concise and mention the commands or browser states that mattered.',
      'Treat the desktop bridge as the user-facing chat UI.'
    ];

    if (settings.approvalMode === 'confirm_mutations') {
      lines.push(
        'Safety policy:',
        '- Read-only Silmaril commands such as get-currenturl, list-urls, get-dom, get-text, query, exists, wait-for, wait-for-any, wait-for-gone, wait-until-js, wait-for-mutation, and get-source may be executed directly.',
        '- Before any mutating or high-risk Silmaril command such as click, type, set-text, set-html, eval-js, proxy-override, proxy-switch, or openurl-proxy, do not execute it yet.',
        '- Instead, respond exactly in this format:',
        'APPROVAL REQUIRED: <one-line summary>',
        'COMMAND: <exact command>',
        'REASON: <short reason>',
        '- Wait for a follow-up approval message before executing the mutation.'
      );
    }
    else {
      lines.push('Safety policy: the user has enabled auto-approve mode for browser actions. You may execute Silmaril commands directly.');
    }

    lines.push('', 'User request:', userPrompt.trim());
    return lines.join('\n');
  }

  sendPrompt(userPrompt) {
    const trimmedPrompt = String(userPrompt || '').trim();
    if (!trimmedPrompt) {
      return { ok: false, error: 'Prompt is empty.' };
    }

    if (this.child) {
      return { ok: false, error: 'Codex is already running a prompt.' };
    }

    const prompt = this.buildPrompt(trimmedPrompt);
    pushTranscript({ role: 'user', text: trimmedPrompt });
    pushActivity({ level: 'info', label: 'Prompt queued', detail: trimmedPrompt });

    let args;
    if (this.threadId) {
      args = ['exec', 'resume', '--json', this.threadId];
    }
    else {
      args = ['exec', '--json', '-C', REPO_ROOT];
      if (fs.existsSync('C:\\Users\\hangx')) {
        args.push('--add-dir', 'C:\\Users\\hangx');
      }
    }

    try {
      this.runCodex(args, prompt, trimmedPrompt);
      return { ok: true };
    }
    catch (error) {
      this.setState({
        runState: 'error',
        lastError: error.message,
        activePrompt: ''
      });
      pushActivity({ level: 'error', label: 'Codex launch failed', detail: error.message });
      return { ok: false, error: error.message };
    }
  }

  runCodex(args, promptText, userPrompt) {
    const spawnArgs = args.map((arg) => {
      const value = String(arg);
      return /\s/.test(value) ? `"${value}"` : value;
    });

    const child = spawn(this.codexCommand, spawnArgs, {
      cwd: REPO_ROOT,
      env: process.env,
      windowsHide: true,
      shell: true
    });

    this.child = child;
    this.setState({
      runState: 'running',
      lastError: '',
      activePrompt: userPrompt
    });

    let stdoutBuffer = '';
    let stderrBuffer = '';

    const handleJsonLine = (line) => {
      if (!line) {
        return;
      }

      let event;
      try {
        event = JSON.parse(line);
      }
      catch {
        pushActivity({ level: 'warn', label: 'Unparsed stdout', detail: line });
        return;
      }

      if (event.type === 'thread.started' && event.thread_id) {
        this.threadId = event.thread_id;
        this.setState({ threadId: this.threadId });
        pushActivity({ level: 'info', label: 'Thread ready', detail: this.threadId });
        return;
      }

      if (event.type === 'turn.started') {
        pushActivity({ level: 'info', label: 'Turn started', detail: userPrompt });
        return;
      }

      if (event.type === 'item.started' && event.item && event.item.type === 'command_execution') {
        pushActivity({
          level: 'info',
          label: 'Command running',
          detail: event.item.command
        });
        return;
      }

      if (event.type === 'item.completed' && event.item && event.item.type === 'command_execution') {
        const output = (event.item.aggregated_output || '').trim();
        const detail = output
          ? `${event.item.command}\n\n${output}`
          : event.item.command;
        pushActivity({
          level: event.item.exit_code === 0 ? 'info' : 'error',
          label: event.item.exit_code === 0 ? 'Command completed' : 'Command failed',
          detail
        });
        return;
      }

      if (event.type === 'item.completed' && event.item && event.item.type === 'agent_message') {
        const text = String(event.item.text || '').trim();
        pushTranscript({ role: 'assistant', text });
        const approval = parseApprovalRequest(text);
        if (approval) {
          setPendingApproval(approval);
        }
        return;
      }

      if (event.type === 'turn.completed') {
        pushActivity({ level: 'info', label: 'Turn completed', detail: 'Codex finished this response.' });
      }
    };

    child.stdout.on('data', (chunk) => {
      stdoutBuffer += chunk.toString('utf8');
      const lines = stdoutBuffer.split(/\r?\n/);
      stdoutBuffer = lines.pop() || '';
      for (const line of lines) {
        handleJsonLine(line.trim());
      }
    });

    child.stderr.on('data', (chunk) => {
      stderrBuffer += chunk.toString('utf8');
    });

    child.stdin.write(promptText + '\n');
    child.stdin.end();

    child.on('error', (error) => {
      this.child = null;
      this.setState({
        runState: 'error',
        lastError: error.message,
        activePrompt: ''
      });
      pushActivity({ level: 'error', label: 'Codex launch failed', detail: error.message });
    });

    child.on('exit', (code) => {
      if (stdoutBuffer.trim()) {
        handleJsonLine(stdoutBuffer.trim());
      }

      const cleanedStderr = stderrBuffer
        .replace(/Reading prompt from stdin\.\.\.\s*/g, '')
        .trim();

      if (code !== 0 && cleanedStderr) {
        pushActivity({ level: 'error', label: 'Codex stderr', detail: cleanedStderr });
      }

      const isCancelled = this.state.runState === 'cancelling';
      this.child = null;
      this.setState({
        runState: isCancelled ? 'idle' : (code === 0 ? 'idle' : 'error'),
        lastError: code === 0 ? '' : (cleanedStderr || `Codex exited with code ${code}.`),
        activePrompt: ''
      });
      if (isCancelled) {
        pushActivity({ level: 'warn', label: 'Run cancelled', detail: 'The current Codex turn was cancelled.' });
      }
    });
  }

  cancel() {
    if (!this.child) {
      return { ok: false, error: 'No active Codex run.' };
    }

    this.setState({ runState: 'cancelling' });
    try {
      spawn('taskkill', ['/PID', String(this.child.pid), '/T', '/F'], { windowsHide: true });
    }
    catch {
      try {
        this.child.kill();
      }
      catch {
        // Ignore kill failures.
      }
    }

    return { ok: true };
  }

  restart() {
    if (this.child) {
      this.cancel();
    }
    this.threadId = null;
    setPendingApproval(null);
    this.setState({
      runState: 'idle',
      lastError: '',
      activePrompt: '',
      threadId: null
    });
    pushActivity({ level: 'info', label: 'Session restarted', detail: 'Codex conversation context was reset.' });
    return { ok: true };
  }
}

function createWindow() {
  const iconPath = resolveAppIcon();
  mainWindow = new BrowserWindow({
    width: SIDEBAR_WIDTH,
    height: 860,
    minWidth: 360,
    minHeight: MIN_WINDOW_HEIGHT,
    title: 'Codex Bridge',
    autoHideMenuBar: true,
    backgroundColor: '#f4dfcf',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    },
    icon: iconPath
  });

  mainWindow.loadFile(path.join(__dirname, 'index.html'));
  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

async function runSmokeTest() {
  const smokeChromeConfig = getChromeConfig();
  const codexExists = fs.existsSync(CODEX_CMD_PATH);
  const codexCommand = codexExists ? CODEX_CMD_PATH : '';
  const browserResult = await probeChromeConnection(smokeChromeConfig);
  const payload = {
    ok: codexExists,
    codexCommand,
    chromeConnected: browserResult.connected,
    chromePort: smokeChromeConfig.port
  };
  process.stdout.write(JSON.stringify(payload) + '\n');
  app.exit(codexExists ? 0 : 1);
}

function setupIpc() {
  ipcMain.handle('bridge:getSnapshot', async () => getSnapshot());
  ipcMain.handle('bridge:sendPrompt', async (_event, prompt) => bridge.sendPrompt(prompt));
  ipcMain.handle('bridge:cancel', async () => bridge.cancel());
  ipcMain.handle('bridge:restart', async () => bridge.restart());
  ipcMain.handle('bridge:updateSettings', async (_event, partial) => {
    settings = { ...settings, ...partial };
    saveSettings(settings);
    emitRenderer('bridge:settings', settings);
    return settings;
  });
  ipcMain.handle('bridge:approvePending', async () => {
    if (!pendingApproval) {
      return { ok: false, error: 'No pending approval.' };
    }
    const approved = pendingApproval;
    setPendingApproval(null);
    const prompt = [
      'Approval granted for the previously proposed browser mutation.',
      approved.command ? `Run this approved command now if still appropriate: ${approved.command}` : 'Run the previously proposed mutation now if still appropriate.',
      approved.summary ? `Approved action summary: ${approved.summary}` : '',
      'After executing the approved mutation, continue the original interrupted user task from the current browser state.',
      'Do not stop after reporting the command result.',
      'Continue working until the overall task is complete or until another mutating or high-risk browser command requires approval.',
      'If another approval is needed, respond again using the required APPROVAL REQUIRED / COMMAND / REASON format.'
    ].filter(Boolean).join('\n');
    return bridge.sendPrompt(prompt);
  });
  ipcMain.handle('bridge:rejectPending', async () => {
    if (!pendingApproval) {
      return { ok: false, error: 'No pending approval.' };
    }
    pushActivity({ level: 'warn', label: 'Approval denied', detail: pendingApproval.summary || pendingApproval.raw });
    setPendingApproval(null);
    return { ok: true };
  });
  ipcMain.handle('bridge:openExternal', async (_event, url) => {
    if (url) {
      await shell.openExternal(url);
    }
    return { ok: true };
  });
}

function setupBridge() {
  chromeState = {
    ...chromeState,
    ...getChromeConfig()
  };
  bridge = new CodexBridge(chromeState);
}

function startPolling() {
  refreshChromeState().catch(() => {});
  browserPollTimer = setInterval(() => {
    refreshChromeState().catch(() => {});
  }, BROWSER_POLL_MS);

  dockPollTimer = setInterval(() => {
    syncWindowToChrome().catch(() => {});
  }, DOCK_POLL_MS);
}

const hasLock = app.requestSingleInstanceLock();
if (!hasLock) {
  app.quit();
}

app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) {
      mainWindow.restore();
    }
    mainWindow.focus();
  }
});

app.whenReady().then(async () => {
  settings = loadSettings();
  setupBridge();
  setupIpc();

  if (hasArg('--smoke-test')) {
    await runSmokeTest();
    return;
  }

  createWindow();
  startPolling();
  syncWindowToChrome().catch(() => {});
});

app.on('window-all-closed', () => {
  if (bridge && bridge.child) {
    bridge.cancel();
  }
  if (browserPollTimer) {
    clearInterval(browserPollTimer);
  }
  if (dockPollTimer) {
    clearInterval(dockPollTimer);
  }
  app.quit();
});
