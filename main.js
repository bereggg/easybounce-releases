const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const http = require('http');
// Prevent macOS from throttling JS timers in hidden/background windows
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-background-timer-throttling');
const { validateKey, getMachineId, getTrialInfo, activateTrial, STORAGE_KEY } = require('./license');
const notifications = require('./notifications');
const path = require('path');
const fs = require('fs');
const { exec, execFile } = require('child_process');
const { promisify } = require('util');
const { EventEmitter } = require('events');
const execAsync = promisify(exec);
const _cancelEmitter = new EventEmitter();
_cancelEmitter.setMaxListeners(200); // up to 200 concurrent wait() calls during bounce

let mainWindow;
let _preMini = null;
let _overlayWindow = null;
let _inMiniMode = false;
let _inScanBadge = false;
// Returns correct alwaysOnTop level based on current window state.
// Mini mode and scan badge use 'screen-saver' (same as overlay) so they
// never get buried behind Logic or lost on other Spaces.
function _mainAotLevel() {
  return (_inMiniMode || _inScanBadge) ? 'screen-saver' : 'pop-up-menu';
}
// In packaged app LogicBridge is in app.asar.unpacked (not executable from inside asar)
const BRIDGE = app.isPackaged
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'LogicBridge')
  : path.join(__dirname, 'LogicBridge');
const MIXER_SCROLL = app.isPackaged
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'MixerScroll')
  : path.join(__dirname, 'MixerScroll');
const ESCAPE_LOGIC = app.isPackaged
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'EscapeLogic')
  : path.join(__dirname, 'EscapeLogic');
let cancelRequested = false;
let _scanTreeActive = false;

// ── Analytics ────────────────────────────────────────────────────────────────
const SUPABASE_URL  = 'gormgyzofsyhtamwiwao.supabase.co';
const SUPABASE_KEY  = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdvcm1neXpvZnN5aHRhbXdpd2FvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQyODE2NjIsImV4cCI6MjA4OTg1NzY2Mn0.S6Yv05FKEBSvvGu4EL24o143jcR-Nor-GgfeBsQRnHs';
const _analytics    = { counts: {}, start: Date.now() };

ipcMain.on('analytics-track', (_, key) => {
  if (key) _analytics.counts[key] = (_analytics.counts[key] || 0) + 1;
});

async function _postAnalytics() {
  const crypto   = require('crypto');
  const machineId = getMachineId();
  const payload  = {
    machine_id:   crypto.createHash('sha256').update(machineId).digest('hex').slice(0, 16),
    app_version:  app.getVersion(),
    duration_sec: Math.round((Date.now() - _analytics.start) / 1000),
    buttons:      _analytics.counts,
  };
  const body = JSON.stringify(payload);
  return new Promise(resolve => {
    const req = require('https').request({
      hostname: SUPABASE_URL,
      path:     '/rest/v1/analytics_sessions',
      method:   'POST',
      headers: {
        'Content-Type':   'application/json',
        'apikey':         SUPABASE_KEY,
        'Authorization':  `Bearer ${SUPABASE_KEY}`,
        'Prefer':         'return=minimal',
        'Content-Length': Buffer.byteLength(body),
      },
    }, res => { res.resume(); resolve({ status: res.statusCode }); });
    req.on('error', () => resolve({ ok: false }));
    req.setTimeout(3000, () => { req.destroy(); resolve({ timeout: true }); });
    req.write(body);
    req.end();
  });
}

let _analyticsPosted = false;
app.on('before-quit', async e => {
  if (_analyticsPosted) return;
  _analyticsPosted = true;
  e.preventDefault();
  try { await _postAnalytics(); } catch {}
  app.quit();
});

const _boundsFile = path.join(app.getPath('userData'), 'window-bounds.json');
function _loadBounds() {
  try { return JSON.parse(fs.readFileSync(_boundsFile, 'utf8')); } catch { return null; }
}
function _saveBounds() {
  try {
    if (mainWindow && !mainWindow.isDestroyed()) {
      fs.writeFileSync(_boundsFile, JSON.stringify(mainWindow.getBounds()));
    }
  } catch {}
}

function createWindow() {
  // Clamp initial window size to available work area (screen minus dock + menu bar)
  const { screen } = require('electron');
  const { width: sw, height: sh } = screen.getPrimaryDisplay().workAreaSize;
  const winW = Math.min(1150, Math.max(1070, sw - 20));
  const winH = Math.min(760,  Math.max(640,  sh - 20));

  const saved = _loadBounds();
  const initW = saved ? Math.max(1070, Math.min(saved.width,  sw))     : winW;
  const initH = saved ? Math.max(640,  Math.min(saved.height, sh))     : winH;
  const initX = saved ? saved.x : undefined;
  const initY = saved ? saved.y : undefined;

  // isDev must be determined BEFORE BrowserWindow so devTools flag can be set
  const devPath = '/Users/dbsound/Desktop/WORK-/EasyBounce/src/index.html';
  const isDev = fs.existsSync(devPath);

  mainWindow = new BrowserWindow({
    width: initW, height: initH,
    ...(initX !== undefined && initY !== undefined ? { x: initX, y: initY } : {}),
    minWidth: 1070, minHeight: 640,
    maximizable: false,
    fullscreenable: false,
    titleBarStyle: 'hiddenInset',
    transparent: true,
    backgroundColor: '#00000000',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      devTools: isDev, // fully blocked at engine level in production
      preload: path.join(__dirname, 'preload.js')
    }
  });
  const srcPath = path.join(__dirname, 'src', 'index.html');
  mainWindow.loadFile(isDev ? devPath : srcPath);

  // ── DEV-only: disk debug log ────────────────────────────────────────────────
  if (isDev) {
    const logFile = require('path').join(require('os').homedir(), 'eb_debug.log');
    const dbg = (msg) => {
      const line = `${new Date().toISOString().slice(11,23)} ${msg}\n`;
      require('fs').appendFileSync(logFile, line);
    };
    dbg('=== EasyBounce started ===');
    mainWindow.on('show',   () => dbg('window: show'));
    mainWindow.on('hide',   () => dbg('window: hide'));
    mainWindow.on('focus',  () => dbg('window: focus'));
    mainWindow.on('blur',   () => dbg('window: blur'));
    mainWindow.on('resize', () => { const b = mainWindow.getBounds(); dbg(`window: resize ${b.width}x${b.height}`); });
    mainWindow.on('move',   () => { const b = mainWindow.getBounds(); dbg(`window: move ${b.x},${b.y}`); });
    mainWindow.on('enter-full-screen', () => dbg('window: enter-full-screen'));
    mainWindow.on('leave-full-screen', () => dbg('window: leave-full-screen'));
    const _origSetBounds = mainWindow.setBounds.bind(mainWindow);
    mainWindow.setBounds = (b, anim) => { dbg(`setBounds(${b.width}x${b.height} @ ${b.x},${b.y}) anim=${anim}`); return _origSetBounds(b, anim); };
    const _origSetVOAW = mainWindow.setVisibleOnAllWorkspaces.bind(mainWindow);
    mainWindow.setVisibleOnAllWorkspaces = (v, opts) => { dbg(`setVisibleOnAllWorkspaces(${v})`); return _origSetVOAW(v, opts); };
    const _origSetAOT = mainWindow.setAlwaysOnTop.bind(mainWindow);
    mainWindow.setAlwaysOnTop = (v, level) => { dbg(`setAlwaysOnTop(${v}, ${level})`); return _origSetAOT(v, level); };
  }
  // ── PRODUCTION: silence renderer console (devTools already blocked via webPreferences) ──
  if (!isDev) {
    mainWindow.webContents.on('did-finish-load', () => {
      mainWindow.webContents.executeJavaScript(
        'console.log = console.warn = console.error = console.info = console.debug = () => {};'
      );
    });
  }
  // ───────────────────────────────────────────────────────────────────────────

  mainWindow.once('ready-to-show', () => {
    // Fix: ensure window is not positioned above screen top
    const pos = mainWindow.getPosition();
    if (pos[1] < 0) {
      mainWindow.setPosition(pos[0], 0);
    }
    mainWindow.show();
    mainWindow.focus();
    app.focus({ steal: true });
  });

  // Save window position on move/resize (debounced) and on close
  let _saveBoundsTimer = null;
  const _debounceSave = () => { clearTimeout(_saveBoundsTimer); _saveBoundsTimer = setTimeout(_saveBounds, 500); };
  mainWindow.on('move',   _debounceSave);
  mainWindow.on('resize', _debounceSave);
  mainWindow.on('close', (e) => {
    // In mini mode: pressing native close button expands back to full mode instead of closing
    if (_inMiniMode) {
      e.preventDefault();
      _inMiniMode = false;
      mainWindow.setBackgroundColor('#1C1C1A');
      mainWindow.setMinimumSize(1070, 640);
      mainWindow.setResizable(true);
      if (_preMini) { mainWindow.setBounds(_preMini, true); _preMini = null; }
      else { mainWindow.setSize(1150, 760, true); mainWindow.center(); }
      mainWindow.setWindowButtonVisibility(true);
      mainWindow.setAlwaysOnTop(false);
      mainWindow.setVisibleOnAllWorkspaces(false);
      if (!mainWindow.isDestroyed()) mainWindow.webContents.send('force-exit-mini-mode');
      return;
    }
    _saveBounds();
  });

  // Switch to English keyboard when EasyBounce gets focus (returning from another Space/app)
  let _lastEnglishSwitch = 0;
  mainWindow.on('focus', () => {
    const now = Date.now();
    if (now - _lastEnglishSwitch < 2000) return; // debounce — don't spam LogicBridge
    _lastEnglishSwitch = now;
    bridge('switchToEnglish').catch(() => {});
  });
}

function createLicenseWindow() {
  const licWin = new BrowserWindow({
    width: 480, height: 540,
    resizable: false,
    titleBarStyle: 'hiddenInset',
    vibrancy: 'under-window',
    visualEffectState: 'active',
    backgroundColor: '#00000000',
    transparent: true,
    closable: true,   // allow closing
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js')
    }
  });
  const licPath = path.join(__dirname, 'license.html');
  const devLicPath = '/Users/dbsound/Desktop/WORK-/EasyBounce/license.html';
  const fs2 = require('fs');
  licWin.loadFile(fs2.existsSync(devLicPath) ? devLicPath : licPath);
  return licWin;
}

let _activating = false; // guard: don't quit during window transitions

// ── Accessibility window: show and wait until trusted (or closed) ────────────
async function _checkPermsAsync() {
  const { systemPreferences } = require('electron');
  return systemPreferences.isTrustedAccessibilityClient(false);
}

function _showAxWindowAndWait() {
  return new Promise(async (resolve) => {
    // Skip window entirely if all essential permissions already granted
    const allOk = await _checkPermsAsync();
    if (allOk) { resolve(); return; }

    let _resolved = false;
    const done = () => { if (!_resolved) { _resolved = true; resolve(); } };

    global._permsGranted = false;

    _axWindow = new BrowserWindow({
      width: 360, height: 580,
      resizable: false, minimizable: false, maximizable: false,
      alwaysOnTop: false,
      titleBarStyle: 'hiddenInset',
      backgroundColor: '#161616',
      webPreferences: { nodeIntegration: false, contextIsolation: true, preload: path.join(__dirname, 'preload.js') }
    });
    _axWindow.loadFile(path.join(__dirname, 'src', 'accessibility.html'));

    // Allow close — if user closes without granting, quit the app cleanly
    _axWindow.on('close', () => {
      if (!global._permsGranted) {
        setTimeout(() => app.quit(), 300);
      }
    });
    _axWindow.on('closed', () => { _axWindow = null; done(); });

    // Called by permissions-complete IPC — mark as granted and open main window
    global._permsDoneResolve = () => {
      global._permsGranted = true;
      // Let success animation play (2.2s), then open main window + close permissions window
      setTimeout(() => {
        done();
        if (_axWindow && !_axWindow.isDestroyed()) _axWindow.close();
      }, 2200);
      global._permsDoneResolve = null;
    };
  });
}

app.whenReady().then(async () => {
  // Kill any caffeinate left from a previous crashed session
  try { execAsync('killall caffeinate 2>/dev/null').catch(() => {}); } catch(e) { console.warn('[EB]', e); }

  // ── Step 1: License / Trial check ─────────────────────────────────────────
  const licenseFile = path.join(app.getPath('userData'), 'license.json');
  const GRACE_DAYS = 7; // днів офлайн для subscription
  let licensed = false;

  try {
    const data = JSON.parse(fs.readFileSync(licenseFile, 'utf8'));
    const machineId = getMachineId();

    if (data.machineId === machineId && data.key) {

      if (data.type === 'lifetime') {
        // ── Lifetime: ніколи не перевіряємо Supabase повторно ──
        licensed = true;

      } else if (data.type === 'subscription') {
        // ── Subscription: grace period 7 днів ──
        const daysSinceCheck = (Date.now() - (data.lastChecked || 0)) / 86400000;

        if (daysSinceCheck < GRACE_DAYS) {
          // В межах grace period → пускаємо, перевіряємо Supabase у фоні
          licensed = true;
          validateKey(data.key).then(r => {
            if (r.valid) {
              data.lastChecked = Date.now();
              try { fs.writeFileSync(licenseFile, JSON.stringify(data)); } catch(e) { console.warn('[EB] license save failed:', e.message); }
            }
            // якщо !r.valid і не офлайн → підписка закінчилась, заблокує наступного разу
          }).catch(() => {});
        } else {
          // Grace period вичерпано → потрібна перевірка Supabase
          try {
            const result = await validateKey(data.key);
            if (result.valid) {
              data.lastChecked = Date.now();
              try { fs.writeFileSync(licenseFile, JSON.stringify(data)); } catch(e) { console.warn('[EB] license save failed:', e.message); }
              licensed = true;
            } else if (result.offline) {
              // Немає інтернету — блокуємо (7 днів вже минуло)
              licensed = false;
            }
          } catch(e) { console.warn('[EB]', e); }
        }
      } else if (!data.type) {
        // ── Legacy: old users without type field — treat as lifetime ──
        licensed = true;
      }
    }
  } catch(e) { console.warn('[EB]', e); }

  if (!licensed) {
    try {
      const trial = await getTrialInfo();
      if (trial.active) licensed = true;
    } catch(e) { console.warn('[EB]', e); }
  }

  if (!licensed) {
    const licWin = createLicenseWindow();
    await new Promise(resolve => {
      ipcMain.once('license-activated', () => {
        _activating = true;
        licWin.destroy();
        setTimeout(() => { _activating = false; }, 600);
        resolve();
      });
    });
  }

  // ── Step 2: Accessibility check (BEFORE main window) ──────────────────────
  await _showAxWindowAndWait();

  // ── Step 3: Open main window ───────────────────────────────────────────────
  createWindow();
});
app.on('window-all-closed', () => { if (!_activating) app.quit(); });
app.on('activate', () => {
  // Always show + focus main window on Dock click
  if (mainWindow) {
    mainWindow.show();
    mainWindow.focus();
  } else if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
  // Also restore ax window if open
  if (_axWindow && !_axWindow.isDestroyed()) {
    _axWindow.showInactive();
  }
});

// ── Bridge helper ─────────────────────────────────────────────────────────────
// #11: track the currently running bridge process so cancelScan can kill it mid-scan
let _currentBridgeProc = null;

async function bridge(...args) {
  if (!fs.existsSync(BRIDGE)) {
    return { error: 'LogicBridge not found — run: swiftc LogicBridge.swift -o LogicBridge -framework ApplicationServices -framework AppKit' };
  }
  return new Promise((resolve) => {
    const { execFile } = require('child_process');
    const proc = execFile(BRIDGE, args, { timeout: 30000 }, (err, stdout) => {
      if (_currentBridgeProc === proc) _currentBridgeProc = null;
      try { resolve(JSON.parse((stdout || '').trim())); }
      catch { resolve({ error: err?.message || 'parse error' }); }
    });
    _currentBridgeProc = proc;
  });
}

// Run LogicBridge as an independent process via launchctl asuser so CGEvent
// scroll events are not intercepted by EasyBounce's own window.
function bridgeIndependent(...args) {
  if (!fs.existsSync(BRIDGE)) {
    return Promise.resolve({ error: 'LogicBridge not found' });
  }
  return new Promise((resolve) => {
    const { spawn } = require('child_process');
    const uid = process.getuid ? process.getuid() : 501;
    const proc = spawn('launchctl', ['asuser', String(uid), BRIDGE, ...args], {
      timeout: 35000
    });
    let stdout = '';
    proc.stdout.on('data', d => { stdout += d; });
    proc.on('close', () => {
      try { resolve(JSON.parse(stdout.trim())); }
      catch { resolve({ error: 'parse error', raw: stdout.slice(0, 200) }); }
    });
    proc.on('error', err => resolve({ error: err.message }));
  });
}

// ── Opt #4: Bridge TTL cache (read-only commands only) ────────────────────────
// Prevents duplicate bridge spawns when IPC arrives repeatedly within a short window.
// Only for side-effect-free queries; write commands (solo/mute/bounce) bypass cache.
const _bridgeCache = new Map();
async function cachedBridge(cmd, ttlMs, ...extraArgs) {
  const key = cmd + (extraArgs.length ? JSON.stringify(extraArgs) : '');
  const cached = _bridgeCache.get(key);
  if (cached && (Date.now() - cached.ts) < ttlMs) return cached.val;
  const val = await bridge(cmd, ...extraArgs);
  if (!val?.error) {
    // #19: evict oldest entry when cache exceeds 100 entries to prevent unbounded growth
    if (_bridgeCache.size >= 100) _bridgeCache.delete(_bridgeCache.keys().next().value);
    _bridgeCache.set(key, { val, ts: Date.now() });
  }
  return val;
}
function invalidateBridgeCache(cmd) {
  if (cmd) { for (const k of _bridgeCache.keys()) { if (k.startsWith(cmd)) _bridgeCache.delete(k); } }
  else _bridgeCache.clear();
}

// ── IPC handlers ──────────────────────────────────────────────────────────────
ipcMain.handle('switch-to-english', () => bridge('switchToEnglish'));
ipcMain.handle('scan-channels', () => { invalidateBridgeCache('scan'); return bridge('scan'); }); // scan always fresh
// #11: kill the running bridge process immediately so AX actions in Logic stop within ~200ms
ipcMain.handle('cancel-scan', () => {
  if (_currentBridgeProc) {
    try { _currentBridgeProc.kill('SIGTERM'); } catch(e) { console.warn('[EB]', e); }
    _currentBridgeProc = null;
  }
  return { ok: true };
});
ipcMain.handle('scan-master-plugins', () => cachedBridge('scanMasterPlugins', 3000));
ipcMain.handle('master-plugins', () => cachedBridge('masterPlugins', 2500));
ipcMain.handle('set-master-plugin', (_, name, active) => { invalidateBridgeCache('masterPlugins'); return bridge('setMasterPlugin', name, String(active)); });
ipcMain.handle('set-all-master-plugins', (_, active) => { invalidateBridgeCache('masterPlugins'); return bridge('setAllMasterPlugins', String(active)); });
ipcMain.handle('master-plugins-quick', () => cachedBridge('masterPluginsQuick', 1000)); // 1s TTL — fast polling
ipcMain.handle('scan-tree', async () => {
  _scanTreeActive = true;
  // Scan badge is click-through (setIgnoreMouseEvents=true), so we do NOT need
  // to lower alwaysOnTop — HID clicks from LogicBridge pass straight to Logic.
  try { return await bridge('scan-tree'); }
  finally { _scanTreeActive = false; }
});
ipcMain.handle('maximize-logic',         () => bridge('maximizeLogic'));
ipcMain.handle('exit-fullscreen-only',   () => bridge('exitFullscreenOnly'));
ipcMain.handle('close-panels', async () => {
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow && !_inScanBadge && !_inMiniMode) mainWindow.setAlwaysOnTop(false);
  const result = await bridge('closePanels');
  if (mainWindow && !mainWindow.isDestroyed() && wasOnTop) {
    mainWindow.setAlwaysOnTop(true, _mainAotLevel());
    mainWindow.showInactive();
  }
  return result;
});
ipcMain.handle('scroll-to-bnc', async () => {
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow && !_inScanBadge && !_inMiniMode) mainWindow.setAlwaysOnTop(false);
  const result = await bridge('scrollToBnc');
  if (mainWindow && !mainWindow.isDestroyed() && wasOnTop) {
    mainWindow.setAlwaysOnTop(true, _mainAotLevel());
    mainWindow.showInactive();
  }
  return result;
});
ipcMain.handle('open-mixer', async (_, opts = {}) => {
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow && !_inScanBadge && !_inMiniMode) mainWindow.setAlwaysOnTop(false);
  const result = await bridge('openMixer', ...(opts.skipPanelClose ? ['skipPanelClose'] : []));
  if (mainWindow && !mainWindow.isDestroyed() && wasOnTop) {
    mainWindow.setAlwaysOnTop(true, _mainAotLevel());
    mainWindow.showInactive();
  }
  return result;
});
ipcMain.handle('close-mixer', () => bridge('closeMixer'));
ipcMain.handle('ensure-mixer', () => bridge('ensureMixer'));
ipcMain.handle('send-key', (_, keyCode, ...mods) => bridge('sendKey', String(keyCode), ...mods));
ipcMain.handle('stop-render', () => bridge('stop-render'));
ipcMain.handle('type-text', (_, text) => {
  if (typeof text !== 'string') return { error: 'invalid input' };
  return bridge('typeText', text);
});
ipcMain.handle('click-window-button', (_, name) => bridge('clickWindowButton', name));
ipcMain.handle('get-windows', () => bridge('getWindows'));
ipcMain.handle('set-filename-bounce', (_, name) => {
  if (typeof name !== 'string') return { error: 'invalid input' };
  // #25: strip path traversal characters — filename only, no slashes or dots sequences
  const safe = name.replace(/[/\\]/g, '_').replace(/\.\./g, '_');
  return bridge('setFilenameAndBounce', safe);
});
ipcMain.handle('set-filename-and-bounce', (_, name) => {
  if (typeof name !== 'string') return { error: 'invalid input' };
  const safe = name.replace(/[/\\]/g, '_').replace(/\.\./g, '_');
  return bridge('setFilenameAndBounce', safe);
});
ipcMain.handle('check-metronome', () => bridge('metronome'));
ipcMain.handle('set-format', async (_, fmt, bit, sr) => {
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow && !_inScanBadge && !_inMiniMode) mainWindow.setAlwaysOnTop(false);
  try { return await bridge('setFormat', fmt, bit, sr); }
  finally {
    if (mainWindow && !mainWindow.isDestroyed() && wasOnTop) {
      mainWindow.setAlwaysOnTop(true, _mainAotLevel());
      mainWindow.showInactive();
    }
  }
});
ipcMain.handle('metronome-toggle', () => bridge('metronomeToggle'));
ipcMain.handle('solo-index',    (_, i) => bridge('soloIndex', i));
ipcMain.handle('unsolo-index',  (_, i) => bridge('unsoloIndex', i));
ipcMain.handle('mute-index',    (_, i) => bridge('muteIndex', i));
ipcMain.handle('unmute-index',  (_, i) => bridge('unmuteIndex', i));
ipcMain.handle('unsolo-all',           () => bridge('unsoloAll'));
ipcMain.handle('unmute-all',           () => bridge('unmuteAll'));
ipcMain.handle('mute-many-by-index',   (_, ids) => bridge('muteManyByIndex', ids));
ipcMain.handle('unmute-many-by-index', (_, ids) => bridge('unmuteManyByIndex', ids));
ipcMain.handle('close-marker-list',    () => bridge('close-marker-list'));
ipcMain.handle('read-states',          () => bridge('readStates'));
ipcMain.handle('bounce',        () => bridge('bounce'));

// ── Cancel support ────────────────────────────────────────────────────────────
ipcMain.handle('cancel-bounce', () => { cancelRequested = true; _cancelEmitter.emit('cancel'); return { ok: true }; });
ipcMain.handle('reset-cancel',  () => { cancelRequested = false; return { ok: true }; });
ipcMain.handle('check-cancel',  () => ({ cancelled: cancelRequested }));

// ── Shell commands (for caffeinate etc.) ─────────────────────────────────────
ipcMain.handle('start-caffeinate', () => {
  const { spawn } = require('child_process');
  const proc = spawn('caffeinate', ['-dims'], { detached: true, stdio: 'ignore' });
  proc.unref(); // don't keep Node alive for this process
  return { ok: true, pid: proc.pid };
});

ipcMain.handle('run-shell', async (_, cmd) => {
  const { exec } = require('child_process');
  return new Promise(resolve => {
    const utf8Env = { ...process.env, LANG: 'en_US.UTF-8', LC_ALL: 'en_US.UTF-8' };
    exec(cmd, { timeout: 30000, env: utf8Env }, (err, stdout) => resolve({ ok: !err, stdout: (stdout || '').trim() }));
  });
});
ipcMain.handle('escape-logic', () => {
  const { execFile } = require('child_process');
  return new Promise(resolve => {
    execFile(ESCAPE_LOGIC, [], { timeout: 3000 }, (err) => resolve({ ok: !err }));
  });
});
ipcMain.handle('hide-window', () => {
  if (mainWindow && !_inScanBadge && !_inMiniMode) { mainWindow.setAlwaysOnTop(false); mainWindow.hide(); }
  return { ok: true };
});
ipcMain.handle('show-window', () => {
  if (mainWindow) { mainWindow.show(); mainWindow.focus(); }
  return { ok: true };
});

// ── Logic status ──────────────────────────────────────────────────────────────
ipcMain.handle('get-window-bounds', () => mainWindow ? mainWindow.getBounds() : null);
ipcMain.handle('set-window-bounds', (_, b) => {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.setBounds(b, true);
  return true;
});

let _logicPid = null; // PID captured when bounce starts — detects crash+restart

ipcMain.handle('check-logic', async () => {
  try {
    const { stdout } = await execAsync('pgrep -x "Logic Pro"');
    const pid = parseInt(stdout.trim(), 10);
    if (!pid) return { running: false };
    // If we have a reference PID from bounce start, detect crash+restart
    if (_logicPid && pid !== _logicPid) return { running: false, restarted: true };
    return { running: true, pid };
  } catch { return { running: false }; }
});

ipcMain.handle('capture-logic-pid', async () => {
  try {
    const { stdout } = await execAsync('pgrep -x "Logic Pro"');
    _logicPid = parseInt(stdout.trim(), 10) || null;
    return { pid: _logicPid };
  } catch { _logicPid = null; return { pid: null }; }
});

ipcMain.handle('release-logic-pid', () => { _logicPid = null; return { ok: true }; });

ipcMain.handle('get-project-name', async () => {
  try {
    const { stdout } = await execAsync(`osascript -e 'tell application "Logic Pro" to if (count of documents) > 0 then return name of document 1'`);
    return { name: stdout.trim().replace(/\.logicx$/, '') };
  } catch { return { name: null }; }
});

// ── File system ───────────────────────────────────────────────────────────────
ipcMain.handle('open-folder', async () => {
  const r = await dialog.showOpenDialog(mainWindow, {
    title: 'Select Output Folder',
    properties: ['openDirectory', 'createDirectory']
  });
  return r.canceled ? null : r.filePaths[0];
});

ipcMain.handle('reveal-folder', (_, p) => { shell.openPath(p); return { ok: true }; });
ipcMain.handle('open-logs-folder', () => {
  const logsPath = app.getPath('logs'); // ~/Library/Logs/EasyBounce
  shell.openPath(logsPath);
  return { ok: true, path: logsPath };
});

// ── Production log file: one file per session, keep last 10, delete if >20 ──
const _logDir = app.getPath('logs');
const _sessionTs = new Date().toISOString().replace('T','_').replace(/:/g,'-').slice(0,19);
const _logFilePath = path.join(_logDir, `easybounce_${_sessionTs}.log`);
try {
  const _allLogs = fs.readdirSync(_logDir)
    .filter(f => f.startsWith('easybounce_') && f.endsWith('.log'))
    .map(f => ({ name: f, time: fs.statSync(path.join(_logDir, f)).mtimeMs }))
    .sort((a, b) => a.time - b.time);
  if (_allLogs.length > 20)
    _allLogs.slice(0, 10).forEach(f => { try { fs.unlinkSync(path.join(_logDir, f.name)); } catch {} });
} catch {}
ipcMain.handle('write-log', (_, msg, level) => {
  try {
    const ts = new Date().toISOString().replace('T', ' ').slice(0, 23);
    fs.appendFileSync(_logFilePath, `${ts} [${(level||'info').toUpperCase().padEnd(4)}] ${msg}\n`);
  } catch {}
  return { ok: true };
});

ipcMain.handle('run-script', async (_, script) => {
  const tmp = path.join(app.getPath('temp'), 'sb_script.applescript');
  fs.writeFileSync(tmp, script);
  let _scriptProc = null;
  try {
    const stdout = await new Promise((resolve, reject) => {
      // #28: capture process handle so we can kill it on timeout (avoids race: file deleted while still running)
      _scriptProc = execFile('/usr/bin/osascript', [tmp], (err, out) => {
        _scriptProc = null;
        if (err) reject(err); else resolve(out);
      });
      setTimeout(() => {
        if (_scriptProc) { try { _scriptProc.kill('SIGTERM'); } catch(e) { console.warn('[EB]', e); } _scriptProc = null; }
        reject(new Error('osascript timeout'));
      }, 30000);
    });
    return { ok: true, output: stdout.trim() };
  } catch (e) { return { ok: false, error: e.message }; }
  finally { try { fs.unlinkSync(tmp); } catch {} }
});

ipcMain.handle('wait', (_, ms) => new Promise(r => {
  // Resolve immediately if already cancelled
  if (cancelRequested) { r(); return; }
  // Use timer + cancel event — zero polling, resolves instantly on cancel
  const timer = setTimeout(r, ms);
  const onCancel = () => { clearTimeout(timer); r(); };
  _cancelEmitter.once('cancel', onCancel);
  // Clean up emitter listener when timer fires naturally
  setTimeout(() => _cancelEmitter.removeListener('cancel', onCancel), ms + 10);
}));
ipcMain.handle('get-home', () => require('os').homedir());
ipcMain.handle('set-clipboard', (_, text) => { require('electron').clipboard.writeText(text); return {ok:true}; });

ipcMain.handle('mkdir', (_, p) => {
  require('fs').mkdirSync(p, { recursive: true });
  return { ok: true };
});

// Check if any file whose name starts with `prefix` exists in `folder`
// Normalize both to NFC — macOS HFS+/APFS returns NFD filenames, JS strings are NFC
ipcMain.handle('find-file', (_, folder, prefix) => {
  try {
    const files = require('fs').readdirSync(folder);
    const p = prefix.normalize('NFC');
    return files.some(f => f.normalize('NFC').startsWith(p));
  } catch(e) { return false; }
});
ipcMain.handle('mute-by-name',   (_, n) => bridge('muteByName',   n));
ipcMain.handle('unmute-by-name', (_, n) => bridge('unmuteByName', n));
ipcMain.handle('solo-by-name',   (_, n) => bridge('soloByName',   n));
ipcMain.handle('unsolo-by-name', (_, n) => bridge('unsoloByName', n));
// #10: escape any '|' in channel names so the pipe delimiter used by LogicBridge stays unambiguous
ipcMain.handle('mute-many',   (_, names) => bridge('muteMany',   names.map(n => n.replace(/\|/g, '\\|')).join('|')));
ipcMain.handle('unmute-many', (_, names) => bridge('unmuteMany', names.map(n => n.replace(/\|/g, '\\|')).join('|')));
ipcMain.handle('reset-mutes', () => bridge('resetMutes'));
ipcMain.handle('mixer-get-filters',    () => bridge('getMixerFilters'));
ipcMain.handle('mixer-filter-toggle', async (_, name) => {
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow && !_inScanBadge && !_inMiniMode) mainWindow.setAlwaysOnTop(false);
  const result = await bridge('mixerFilterToggle', name);
  if (mainWindow && !mainWindow.isDestroyed() && wasOnTop) { mainWindow.setAlwaysOnTop(true, _mainAotLevel()); mainWindow.showInactive(); }
  return result;
});
ipcMain.handle('mixer-enable-all', async () => {
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow && !_inScanBadge && !_inMiniMode) mainWindow.setAlwaysOnTop(false);
  const result = await bridge('enableAllMixerFilters');
  if (mainWindow && !mainWindow.isDestroyed() && wasOnTop) { mainWindow.setAlwaysOnTop(true, _mainAotLevel()); mainWindow.showInactive(); }
  return result;
});
ipcMain.handle('apply-bounce-preset', async (_, params) => {
  // Step aside so popup menus appear above Logic, not behind our alwaysOnTop overlay
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow && !_inScanBadge && !_inMiniMode) mainWindow.setAlwaysOnTop(false);
  try { return await bridge('applyBouncePreset', JSON.stringify(params)); }
  finally {
    if (mainWindow && !mainWindow.isDestroyed() && wasOnTop) {
      mainWindow.setAlwaysOnTop(true, _mainAotLevel());
      mainWindow.showInactive();
    }
  }
});
ipcMain.handle('get-bounce-params', () => bridge('getBounceParams'));
ipcMain.handle('scan-markers', () => bridge('scan-markers'));
ipcMain.handle('set-locators-by-marker', async (_, name, keepML) => bridge('set-locators-by-marker', name, ...(keepML ? ['keep-ml'] : [])));
ipcMain.handle('focus-app', () => {
  if (_scanTreeActive) return { ok: true };
  if (mainWindow) { mainWindow.show(); mainWindow.focus(); }
  return { ok: true };
});

ipcMain.handle('move-to-logic-space', async () => {
  if (!mainWindow) return { ok: false };
  try {
    const { stdout } = await execAsync('ps aux | grep -i "logic pro" | grep -v grep');
    if (!stdout.trim()) return { ok: false, reason: 'Logic not running' };
  } catch { return { ok: false, reason: 'Logic not running' }; }

  // Make EasyBounce visible on all spaces first, then activate Logic via
  // AppleScript 'activate' (unlike `open -a`, it does NOT trigger a Space switch
  // animation, so the transparent window never goes black mid-transition).
  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  try {
    await execAsync(`osascript -e 'tell application "Logic Pro" to activate'`);
  } catch(e) { console.warn('[EB]', e); }
  await new Promise(r => setTimeout(r, 600));
  // Re-activate Logic to be sure we're on its Space
  try {
    await execAsync(`osascript -e 'tell application "Logic Pro" to activate'`);
  } catch(e) { console.warn('[EB]', e); }
  await new Promise(r => setTimeout(r, 200));
  // In mini mode: keep visibleOnAllWorkspaces so the widget follows the user
  if (!_inMiniMode) {
    mainWindow.setVisibleOnAllWorkspaces(false);
    await new Promise(r => setTimeout(r, 80));
    mainWindow.show();
    mainWindow.focus();
  }
  return { ok: true };
});

// Snap all windows (main + overlay) to Logic's Space after a stem render completes
ipcMain.handle('snap-to-logic-space', async () => {
  try {
    await execAsync(`osascript -e 'tell application "Logic Pro" to activate'`);
  } catch(e) { console.warn('[EB]', e); }
  await new Promise(r => setTimeout(r, 300));
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.setVisibleOnAllWorkspaces(false);
    mainWindow.showInactive();
  }
  if (_overlayWindow && !_overlayWindow.isDestroyed()) {
    _overlayWindow.setVisibleOnAllWorkspaces(false);
    _overlayWindow.showInactive();
  }
  return { ok: true };
});

ipcMain.handle('set-always-on-top', (_, val) => {
  if (mainWindow) {
    if (val) {
      // 'pop-up-menu' is above Logic's menus — EasyBounce stays visible during AX interactions
      mainWindow.setAlwaysOnTop(true, _mainAotLevel());
    } else if (!_inScanBadge && !_inMiniMode) {
      mainWindow.setAlwaysOnTop(false);
    }
  }
  return { ok: true };
});

// ── Mini Mode — resize main window to compact widget ──────────────────────────
ipcMain.handle('enter-mini-mode', () => {
  if (!mainWindow) return { ok: false };
  _inMiniMode = true;
  _preMini = mainWindow.getBounds();
  const { screen } = require('electron');
  const display = screen.getDisplayNearestPoint({ x: _preMini.x, y: _preMini.y });
  const { x: dx, y: dy, width: dw, height: dh } = display.workArea;
  mainWindow.setMinimumSize(200, 80);
  mainWindow.setResizable(false);
  mainWindow.setWindowButtonVisibility(false);
  mainWindow.setBackgroundColor('#00000000');
  mainWindow.setBounds({ x: dx + dw - 320, y: dy + dh - 108, width: 300, height: 88 }, true);
  mainWindow.setAlwaysOnTop(true, 'screen-saver');
  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  return { ok: true };
});

ipcMain.handle('exit-mini-mode', () => {
  if (!mainWindow) return { ok: false };
  _inMiniMode = false;
  mainWindow.setBackgroundColor('#1C1C1A');
  mainWindow.setMinimumSize(1070, 640);
  mainWindow.setResizable(true);
  mainWindow.setWindowButtonVisibility(true);
  if (_preMini) {
    mainWindow.setBounds(_preMini, true);
    _preMini = null;
  } else {
    mainWindow.setSize(1200, 760, true);
    mainWindow.center();
  }
  // Keep alwaysOnTop as-is (bounce may still be running).
  // JS side calls setAlwaysOnTop(false) when bounce finishes.
  mainWindow.setVisibleOnAllWorkspaces(false);
  mainWindow.show();
  mainWindow.focus();
  return { ok: true };
});


// ── Bounce Overlay — floating always-on-top progress window ─────────────────
function _createOverlay() {
  if (_overlayWindow && !_overlayWindow.isDestroyed()) { _overlayWindow.showInactive(); return; }
  const { screen } = require('electron');
  // Use the display where the main EasyBounce window currently lives
  const mainBounds = mainWindow ? mainWindow.getBounds() : null;
  const targetDisplay = mainBounds
    ? screen.getDisplayNearestPoint({ x: mainBounds.x + mainBounds.width / 2, y: mainBounds.y + mainBounds.height / 2 })
    : screen.getPrimaryDisplay();
  const { x: dx, y: dy, width: dw } = targetDisplay.workArea;
  const W = 680, H = 110;
  // Top-center of the same display as EasyBounce
  _overlayWindow = new BrowserWindow({
    width: W, height: H,
    x: dx + Math.floor(dw / 2 - W / 2),
    y: dy,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    focusable: false,
    resizable: false,
    movable: true,
    skipTaskbar: true,
    hasShadow: false,
    show: false,
    webPreferences: { nodeIntegration: false, contextIsolation: true, preload: path.join(__dirname, 'overlay-preload.js') }
  });
  _overlayWindow.setAlwaysOnTop(true, 'screen-saver');
  _overlayWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  const overlayPath = app.isPackaged
    ? path.join(app.getAppPath(), 'src', 'overlay.html')
    : path.join(__dirname, 'src', 'overlay.html');
  _overlayWindow.webContents.once('did-finish-load', () => {
    if (_overlayWindow && !_overlayWindow.isDestroyed()) _overlayWindow.showInactive();
  });
  _overlayWindow.loadFile(overlayPath);
  _overlayWindow.on('closed', () => { _overlayWindow = null; });
}

ipcMain.handle('show-bounce-overlay', () => { _createOverlay(); return { ok: true }; });

ipcMain.handle('update-bounce-overlay', (_, data) => {
  if (_overlayWindow && !_overlayWindow.isDestroyed()) {
    _overlayWindow.webContents.send('overlay-update', data);
  }
  return { ok: true };
});

ipcMain.handle('hide-bounce-overlay', async () => {
  if (_overlayWindow && !_overlayWindow.isDestroyed()) {
    // Ask renderer to play fade-out, then close
    _overlayWindow.webContents.send('overlay-fade-out');
    await new Promise(r => setTimeout(r, 320));
    if (_overlayWindow && !_overlayWindow.isDestroyed()) _overlayWindow.close();
  }
  _overlayWindow = null;
  return { ok: true };
});

ipcMain.handle('overlay-dismiss', () => {
  // Renderer already plays the fade-out animation before calling this,
  // so we just close immediately here.
  if (_overlayWindow && !_overlayWindow.isDestroyed()) { _overlayWindow.close(); }
  _overlayWindow = null;
  return { ok: true };
});

ipcMain.handle('overlay-countdown', (_, sec) => {
  if (_overlayWindow && !_overlayWindow.isDestroyed()) {
    _overlayWindow.webContents.send('overlay-countdown', sec);
  }
  return { ok: true };
});

// ── Scan Badge Mode — shrink window to scan warning badge only ────────────────
let _preScan = null;
ipcMain.handle('enter-scan-badge', async () => {
  if (!mainWindow) return { ok: false };
  _inScanBadge = true;
  _preScan = mainWindow.getBounds();
  const { screen } = require('electron');

  // Try to position badge on Logic's monitor (not necessarily EasyBounce's monitor)
  let targetDisplay = null;
  try {
    const { stdout } = await execAsync(
      `osascript -e 'tell application "System Events" to get position of front window of process "Logic Pro"'`
    );
    const parts = stdout.trim().split(', ').map(Number);
    if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
      targetDisplay = screen.getDisplayNearestPoint({ x: parts[0], y: parts[1] });
    }
  } catch(e) { console.warn('[EB]', e); }

  if (!targetDisplay) {
    targetDisplay = screen.getDisplayNearestPoint({ x: _preScan.x, y: _preScan.y });
  }

  const { x: dx, y: dy, width: dw } = targetDisplay.workArea;
  const bw = 520; const bh = 80;
  mainWindow.setMinimumSize(200, 60);
  mainWindow.setResizable(false);
  // Top-center of Logic's monitor — same position as bounce overlay for visual consistency
  mainWindow.setBounds({ x: dx + Math.floor(dw / 2 - bw / 2), y: dy, width: bw, height: bh }, false);
  // screen-saver level = same as bounce overlay, never buried behind Logic.
  // setIgnoreMouseEvents(true) = click-through: HID events from LogicBridge
  // (disclosure triangles, Marker List clicks, etc.) pass straight to Logic
  // even though our badge is visually on top. Badge stays visible always.
  mainWindow.setAlwaysOnTop(true, 'screen-saver');
  // Stay on Logic's Space only — do NOT use setVisibleOnAllWorkspaces(true).
  // The badge is positioned on Logic's monitor; during scan focus stays on Logic's Space.
  mainWindow.setVisibleOnAllWorkspaces(false);
  mainWindow.setIgnoreMouseEvents(true, { forward: true });
  // Don't steal focus from Logic — just show badge on top
  mainWindow.showInactive();
  return { ok: true };
});

ipcMain.handle('set-ignore-mouse-events', (e, ignore, options) => {
  if (!mainWindow || !_inScanBadge) return;
  mainWindow.setIgnoreMouseEvents(ignore, options || {});
});

ipcMain.handle('exit-scan-badge', () => {
  if (!mainWindow) return { ok: false };
  _inScanBadge = false;
  mainWindow.setIgnoreMouseEvents(false); // restore interactivity
  mainWindow.setVisibleOnAllWorkspaces(false);
  mainWindow.setMinimumSize(1070, 640);
  mainWindow.setResizable(true);
  if (_preScan) {
    mainWindow.setBounds(_preScan, false);
    _preScan = null;
  }
  // Reset alwaysOnTop so app doesn't stay above Logic after scan
  mainWindow.setAlwaysOnTop(false);
  return { ok: true };
});

// ── Auto-updater ─────────────────────────────────────────────────────────────
const GITHUB_OWNER = 'bereggg';
const GITHUB_REPO  = 'easybounce-releases';
// Version is always read from package.json — no hardcoding needed
const CURRENT_VERSION = (() => { try { return require('./package.json').version; } catch(e) { return '1.0.0'; } })();
// Detect architecture: arm64 = Apple Silicon (M1/M2/M3), x64 = Intel
// Downloads the correct DMG for this machine automatically
const _dlArch = process.arch === 'arm64' ? 'arm64' : 'x64';
const STABLE_DOWNLOAD_URL = `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest/download/EasyBounce-${_dlArch}.dmg`;

let _updateAvailable = null; // { version, downloadUrl } or null

async function checkForUpdates(silent = false) {
  try {
    const https = require('https');
    // Use GitHub Releases API — returns latest non-prerelease release
    const apiUrl = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest`;
    const raw = await new Promise((resolve, reject) => {
      const req = https.get(apiUrl, { headers: { 'User-Agent': 'EasyBounce-Updater' } }, res => {
        let data = '';
        res.on('data', c => data += c);
        res.on('end', () => resolve(data));
      });
      req.on('error', reject);
      req.setTimeout(8000, () => { req.destroy(); reject(new Error('timeout')); });
    });

    const json = JSON.parse(raw);
    if (!json.tag_name) return { hasUpdate: false };

    // tag_name is like "v1.0.1" — strip leading 'v'
    const latestVersion = json.tag_name.replace(/^v/, '');

    function _versionGt(a, b) {
      // #37: parseInt instead of Number — handles "1.0.0-beta" → 1,0,0 instead of NaN
      const toNum = s => { const n = parseInt(s, 10); return isNaN(n) ? 0 : n; };
      const pa = a.split('.').map(toNum), pb = b.split('.').map(toNum);
      for (let i = 0; i < 3; i++) { if ((pa[i]||0) > (pb[i]||0)) return true; if ((pa[i]||0) < (pb[i]||0)) return false; }
      return false;
    }

    const releaseNotes = (json.body || '').trim();

    if (_versionGt(latestVersion, CURRENT_VERSION)) {
      _updateAvailable = { version: latestVersion, downloadUrl: STABLE_DOWNLOAD_URL, releaseNotes };
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('update-available', latestVersion, releaseNotes, STABLE_DOWNLOAD_URL);
      }
      return { hasUpdate: true, version: latestVersion, downloadUrl: STABLE_DOWNLOAD_URL, releaseNotes };
    } else {
      _updateAvailable = null;
      return { hasUpdate: false, releaseNotes };
    }
  } catch(e) { return { hasUpdate: false }; }
}

ipcMain.handle('check-for-updates', () => checkForUpdates(false));
ipcMain.handle('check-for-updates-silent', () => checkForUpdates(true));
ipcMain.handle('get-current-version', () => ({ version: CURRENT_VERSION }));

ipcMain.handle('check-accessibility', async () => {
  const { systemPreferences } = require('electron');
  const trusted = systemPreferences.isTrustedAccessibilityClient(false);
  return { trusted: !!trusted };
});

ipcMain.handle('open-accessibility-settings', async () => {
  const { shell, systemPreferences } = require('electron');
  const { execFile } = require('child_process');
  const runAS = (s) => new Promise(r => execFile('/usr/bin/osascript', ['-e', s], { timeout: 12000 }, r));
  // Trigger native macOS dialog first — this is the proper way to register AX permission in TCC.
  // On Sequoia, this shows "EasyBounce wants to control this computer" → user clicks Open Settings.
  // This properly stores the TCC entry unlike opening System Settings via URL.
  systemPreferences.isTrustedAccessibilityClient(true);
  shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility');
  await new Promise(r => setTimeout(r, 2200));
  // Find EasyBounce row by scanning table rows (exact static text match, not partial name search)
  await runAS([
    'tell application "System Events"',
    '  tell process "System Settings"',
    '    set w to window 1',
    '    set found to false',
    '    -- Try all scroll areas in the window (Ventura/Sonoma structure varies)',
    '    repeat with sc in (every scroll area of w)',
    '      try',
    '        repeat with r in (every row of table 1 of sc)',
    '          try',
    '            set txt to value of static text 1 of r as string',
    '            if txt = "EasyBounce" then',
    '              click r',
    '              set found to true',
    '              exit repeat',
    '            end if',
    '          end try',
    '        end repeat',
    '      end try',
    '      if found then exit repeat',
    '    end repeat',
    '    -- Fallback: try scroll areas inside groups',
    '    if not found then',
    '      repeat with g in (every group of w)',
    '        try',
    '          repeat with sc in (every scroll area of g)',
    '            try',
    '              repeat with r in (every row of table 1 of sc)',
    '                try',
    '                  set txt to value of static text 1 of r as string',
    '                  if txt = "EasyBounce" then',
    '                    click r',
    '                    set found to true',
    '                    exit repeat',
    '                  end if',
    '                end try',
    '              end repeat',
    '            end try',
    '            if found then exit repeat',
    '          end repeat',
    '        end try',
    '        if found then exit repeat',
    '      end repeat',
    '    end if',
    '  end tell',
    'end tell'
  ].join('\n'));
});

// Fired by accessibility.html when user taps "Done" or all permissions auto-detected
ipcMain.handle('permissions-complete', () => {
  if (global._permsDoneResolve) global._permsDoneResolve();
  return { ok: true };
});

ipcMain.handle('open-automation-settings', async () => {
  const { shell } = require('electron');
  const { execFile } = require('child_process');
  const runAS = (s) => new Promise(r => execFile('/usr/bin/osascript', ['-e', s], { timeout: 12000 }, r));
  shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Automation');
  await new Promise(r => setTimeout(r, 2200));
  // Click the EasyBounce disclosure row to expand it (shows Finder/Logic Pro/System Events sub-toggles)
  // Uses exact static text match to avoid clicking wrong app
  await runAS([
    'tell application "System Events"',
    '  tell process "System Settings"',
    '    set w to window 1',
    '    set found to false',
    '    -- Try all scroll areas directly on window',
    '    repeat with sc in (every scroll area of w)',
    '      try',
    '        set tbl to table 1 of sc',
    '        repeat with r in (every row of tbl)',
    '          try',
    '            set txt to value of static text 1 of r as string',
    '            if txt = "EasyBounce" then',
    '              -- Click the disclosure triangle / row to expand',
    '              click r',
    '              delay 0.3',
    '              set found to true',
    '              exit repeat',
    '            end if',
    '          end try',
    '        end repeat',
    '      end try',
    '      if found then exit repeat',
    '    end repeat',
    '    -- Fallback: look inside groups',
    '    if not found then',
    '      repeat with g in (every group of w)',
    '        try',
    '          repeat with sc in (every scroll area of g)',
    '            try',
    '              set tbl to table 1 of sc',
    '              repeat with r in (every row of tbl)',
    '                try',
    '                  set txt to value of static text 1 of r as string',
    '                  if txt = "EasyBounce" then',
    '                    click r',
    '                    delay 0.3',
    '                    set found to true',
    '                    exit repeat',
    '                  end if',
    '                end try',
    '              end repeat',
    '            end try',
    '            if found then exit repeat',
    '          end repeat',
    '        end try',
    '        if found then exit repeat',
    '      end repeat',
    '    end if',
    '  end tell',
    'end tell'
  ].join('\n'));
});

ipcMain.handle('trigger-automation-dialogs', async () => {
  const { execFile } = require('child_process');
  const run = (script) => new Promise(resolve => {
    execFile('/usr/bin/osascript', ['-e', script], { timeout: 7000 }, (err, out) =>
      resolve({ ok: !err, out: (out || '').trim() }));
  });
  // Trigger System Events — macOS shows "Allow?" dialog if not yet granted
  await run('tell application "System Events" to get name of first process');
  await new Promise(r => setTimeout(r, 400));
  // Trigger Finder
  await run('tell application "Finder" to get name of startup disk');
  await new Promise(r => setTimeout(r, 400));
  const lr = await run('return (application "Logic Pro" is running) or (application "Logic Pro X" is running)');
  if (lr.out === 'true') {
    await run('if application "Logic Pro" is running then tell application "Logic Pro" to get name else tell application "Logic Pro X" to get name end if');
  }
  return { ok: true };
});

ipcMain.handle('check-automation', async () => {
  const { execFile } = require('child_process');
  const run = (script) => new Promise(resolve => {
    execFile('/usr/bin/osascript', ['-e', script], { timeout: 5000 }, (err, out) =>
      resolve({ ok: !err, out: (out || '').trim() }));
  });
  const se = await run('tell application "System Events" to get name of first process');
  const fi = await run('tell application "Finder" to get name of startup disk');

  // Logic Pro: check only if running, and use a real AppleEvents command
  // (get name doesn't require TCC — use count of windows which does)
  const lr = await run('return (application "Logic Pro" is running) or (application "Logic Pro X" is running)');
  const logicRunning = lr.out === 'true';
  let logicOk = null;
  if (logicRunning) {
    const lo = await run(`
if application "Logic Pro" is running then
  tell application "Logic Pro" to return count of windows
else
  tell application "Logic Pro X" to return count of windows
end if`);
    logicOk = lo.ok;
  }
  return { systemEvents: se.ok, finder: fi.ok, logicPro: logicOk, logicRunning };
});

ipcMain.handle('open-external', (_, url) => {
  require('electron').shell.openExternal(url);
});

let _axWindow = null;
ipcMain.handle('show-accessibility-window', () => {
  if (_axWindow && !_axWindow.isDestroyed()) { _axWindow.focus(); return; }
  _axWindow = new BrowserWindow({
    width: 360, height: 580,
    resizable: false, minimizable: true, maximizable: false,
    alwaysOnTop: false,
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#161616',
    webPreferences: { nodeIntegration: false, contextIsolation: true, preload: path.join(__dirname, 'preload.js') }
  });
  _axWindow.loadFile(path.join(__dirname, 'src', 'accessibility.html'));
  _axWindow.on('closed', () => { _axWindow = null; });

  // Hide ax window when user switches to another app
  const _axHideIfExternal = () => {
    setTimeout(() => {
      const focused = BrowserWindow.getFocusedWindow();
      const isOurWindow = focused === mainWindow || focused === _axWindow;
      if (!isOurWindow && _axWindow && !_axWindow.isDestroyed()) {
        _axWindow.hide();
      }
    }, 80);
  };
  _axWindow.on('blur', _axHideIfExternal);
  mainWindow.on('blur', _axHideIfExternal);

  // Show again when EasyBounce main window is focused
  const _axRestoreOnFocus = () => {
    if (_axWindow && !_axWindow.isDestroyed()) _axWindow.showInactive();
  };
  mainWindow.on('focus', _axRestoreOnFocus);

  _axWindow.on('closed', () => {
    mainWindow.removeListener('focus', _axRestoreOnFocus);
    mainWindow.removeListener('blur', _axHideIfExternal);
  });
});

ipcMain.handle('close-accessibility-window', () => {
  if (_axWindow && !_axWindow.isDestroyed()) _axWindow.close();
});

// Restart the app (used when Accessibility was granted but requires relaunch to detect)
ipcMain.handle('restart-app', () => {
  app.relaunch();
  app.exit(0);
});

// Called right before opening System Settings — step aside so Settings appears in front
ipcMain.handle('ax-window-step-aside', () => {
  if (_axWindow && !_axWindow.isDestroyed()) {
    _axWindow.setAlwaysOnTop(false);
    _axWindow.hide();   // hide completely so Settings renders at full attention
  }
});

// Restore ax window to front once we need to show success
ipcMain.handle('ax-window-restore', () => {
  if (_axWindow && !_axWindow.isDestroyed()) {
    _axWindow.show();
    _axWindow.setAlwaysOnTop(true);
    _axWindow.focus();
  }
});

// Remove quarantine flag on first launch so users don't see "unidentified developer"
app.whenReady().then(async () => {
  const firstRunFlag = path.join(app.getPath('userData'), '.first_run_done');
  if (!fs.existsSync(firstRunFlag)) {
    try {
      const appPath = app.isPackaged ? path.join(process.execPath, '..', '..', '..') : null;
      if (appPath) await execAsync(`xattr -cr "${appPath}"`);
    } catch(e) { console.warn('[EB]', e); }
    try { fs.writeFileSync(firstRunFlag, '1'); } catch(e) { console.warn('[EB]', e); }
  }
});

// ── License ─────────────────────────────────────────────────────────────────────
ipcMain.handle('validate-license', async (_, key) => {
  if (!key || typeof key !== 'string' || key.length > 100) return { valid: false, reason: 'No key provided' };
  const result = await validateKey(key);
  if (result.valid) {
    // Store activation with machine binding
    const machineId = getMachineId();
    const activation = { key, machineId, activatedAt: Date.now(), schemaVersion: 1,
      type: result.licenseType || 'lifetime', lastChecked: Date.now() };
    try {
      const store = path.join(app.getPath('userData'), STORAGE_KEY);
      fs.writeFileSync(store, JSON.stringify(activation));
    } catch(e) { console.warn('[EB]', e); }
  }
  return result;
});

ipcMain.handle('check-license', async () => {
  // 1. Check license key first (takes priority over trial)
  try {
    const store = path.join(app.getPath('userData'), STORAGE_KEY);
    const data = JSON.parse(fs.readFileSync(store, 'utf8'));
    const machineId = getMachineId();
    if (data.machineId === machineId && data.key) {
      const result = await validateKey(data.key);
      if (result.valid) return { licensed: true, key: data.key, version: result.version };
    }
  } catch(e) { console.warn('[EB]', e); }

  // 2. Fall back to trial
  try {
    const trial = await getTrialInfo();
    if (trial.active) return { licensed: true, trial: true, daysRemaining: trial.daysRemaining };
  } catch(e) { console.warn('[EB]', e); }

  return { licensed: false };
});

ipcMain.handle('get-machine-id', () => getMachineId());

ipcMain.handle('get-trial-info', async () => getTrialInfo());

let _trialActivating = false;
ipcMain.handle('activate-trial', async () => {
  if (_trialActivating) return { ok: false, reason: 'Already activating…' };
  _trialActivating = true;
  try {
    const trial = await activateTrial();
    if (trial.ok && trial.active) {
      setTimeout(() => { ipcMain.emit('license-activated'); }, 600);
    }
    return trial;
  } finally {
    _trialActivating = false;
  }
});

ipcMain.handle('activate-and-launch', async (_, key) => {
  const { validateKey, getMachineId } = require('./license');
  const result = await validateKey(key);
  if (result.valid) {
    const machineId = getMachineId();
    const licenseFile = path.join(app.getPath('userData'), 'license.json');
    try {
      fs.writeFileSync(licenseFile, JSON.stringify({
        key, machineId, activatedAt: Date.now(),
        schemaVersion: 1,
        type: result.licenseType || 'lifetime',
        lastChecked: Date.now()
      }));
    } catch(e) { console.warn('[EB] license save failed:', e.message); }
    // Emit license-activated — whenReady handler creates window and destroys licWin
    setTimeout(() => { ipcMain.emit('license-activated'); }, 800);
    return { ok: true };
  }
  return { ok: false, reason: result.reason || 'Invalid key' };
});
ipcMain.handle('show-confirm', async (_, title, message) => {
  const { dialog, nativeImage } = require('electron');
  const warnIcon = nativeImage.createFromNamedImage('NSCaution');
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'none',
    icon: warnIcon || undefined,
    title,
    message,
    buttons: ['Continue', 'Cancel'],
    defaultId: 1,
    cancelId: 1
  });
  return result.response === 0;
});
// ── Notifications (Telegram + Email) ──────────────────────────────────────────
ipcMain.handle('notif-get-settings', () => notifications.loadSettings());
ipcMain.handle('notif-save-settings', (_, data) => notifications.saveSettings(data));

ipcMain.handle('notif-telegram-connect', () => {
  const code = notifications.generateCode();
  notifications.startTelegramPolling();

  return new Promise((resolve) => {
    notifications.registerPendingCode(code, (chatId) => {
      resolve({ ok: true, code, chatId });
    });

    // Return code to renderer immediately via a workaround:
    // We send the code first, then the promise resolves when user connects
    // But IPC can only resolve once. So we resolve with code immediately
    // and use a separate event for the actual connection.
    // Let's just resolve with the code and have renderer poll for status.
    resolve({ ok: true, code, pending: true });
  });
});

ipcMain.handle('notif-telegram-check', () => {
  const s = notifications.loadSettings();
  return { connected: !!s.telegramChatId, chatId: s.telegramChatId || null };
});

ipcMain.handle('notif-telegram-disconnect', () => {
  const s = notifications.loadSettings();
  delete s.telegramChatId;
  delete s.telegramConnected;
  notifications.saveSettings({ telegramChatId: null, telegramConnected: false });
  notifications.stopTelegramPolling();
  return { ok: true };
});

ipcMain.handle('notif-send-bounce', (_, bounceData) => notifications.sendBounceNotification(bounceData));
ipcMain.handle('send-feedback', (_, data) => notifications.sendFeedback(data));

ipcMain.handle('notif-test-telegram', async () => {
  const s = notifications.loadSettings();
  if (!s.telegramChatId) return { ok: false, reason: 'not connected' };
  return notifications.sendTelegramNotification({
    project: 'Test Project',
    totalFiles: 8,
    duration: '3:45',
    format: 'WAV 24/48',
    folder: '/Desktop/Stems/Test/'
  });
});

ipcMain.handle('notif-test-email', async () => {
  const s = notifications.loadSettings();
  if (!s.notificationEmail) return { ok: false, reason: 'no email' };
  return notifications.sendEmailNotification({
    project: 'Test Project',
    totalFiles: 8,
    totalPlanned: 8,
    errors: 0,
    duration: '3:45',
    format: 'WAV 24/48',
    totalSize: '1.2G',
    stems: [
      { name: 'Kick', type: 'stem' }, { name: 'Snare', type: 'stem' },
      { name: 'Bass', type: 'stem' }, { name: 'Guitars', type: 'stem' },
      { name: 'Strings', type: 'stem' }, { name: 'Vocals', type: 'stem' },
      { name: 'FX', type: 'stem' }, { name: 'Pads', type: 'stem' }
    ],
    folder: '/Desktop/Stems/Test/'
  });
});

ipcMain.handle('notif-test-discord', async () => {
  const s = notifications.loadSettings();
  if (!s.discordWebhookUrl) return { ok: false, reason: 'no webhook' };
  return notifications.sendDiscordNotification({
    project: 'Test Project',
    totalFiles: 8,
    totalPlanned: 8,
    errors: 0,
    duration: '3:45',
    format: 'WAV 24/48',
    totalSize: '1.2 GB',
    stems: [
      { name: 'Kick' }, { name: 'Snare' }, { name: 'Bass' },
      { name: 'Guitars' }, { name: 'Strings' }, { name: 'Vocals' },
      { name: 'FX' }, { name: 'Pads' }
    ],
    folder: '/Desktop/Stems/Test/'
  });
});

// ── CLI trigger server (for `x` terminal command) ───────────────────────────
const CLI_PORT = 7432;
let _cliServer = null;

function startCliServer() {
  _cliServer = http.createServer((req, res) => {
    const u = req.url.split('?')[0];

    if (u === '/ping') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('pong');
      return;
    }

    if (u === '/bounce') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, msg: 'bounce triggered' }));
      if (mainWindow) {
        // Bring app to front then trigger bounce
        mainWindow.show();
        mainWindow.focus();
        mainWindow.webContents.send('cli-bounce');
      }
      return;
    }

    if (u === '/status') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      // renderer will respond via IPC — here we just return running state
      res.end(JSON.stringify({ ok: true, running: !!mainWindow }));
      return;
    }

    res.writeHead(404); res.end('not found');
  });

  _cliServer.listen(CLI_PORT, '127.0.0.1', () => {
    console.log(`[EasyBounce] CLI server listening on 127.0.0.1:${CLI_PORT}`);
  });

  _cliServer.on('error', (e) => {
    // Port already in use — another instance is running, that's fine
    console.warn('[EasyBounce] CLI server error:', e.message);
  });
}

app.whenReady().then(() => startCliServer());
app.on('will-quit', () => { if (_cliServer) _cliServer.close(); });

// Proactively warm up Automation permission for System Events + Logic Pro
ipcMain.handle('warm-permissions', async () => {
  const { execFile } = require('child_process');
  const run = (args) => new Promise(resolve => {
    execFile('/usr/bin/osascript', args, { timeout: 5000 }, (err, out) => resolve({ err: err?.message, out }));
  });
  // Trigger System Events automation dialog (harmless)
  await run(['-e', 'tell application "System Events" to return name of processes whose name is "EasyBounce"']);
  const logicRunning = await run(['-e', 'return (application "Logic Pro" is running) or (application "Logic Pro X" is running)']);
  if (logicRunning.out && logicRunning.out.trim() === 'true') {
    await run(['-e', 'if application "Logic Pro" is running then tell application "Logic Pro" to return name else tell application "Logic Pro X" to return name end if']);
  }
  return { ok: true };
});

ipcMain.handle('show-metronome-warning', async () => {
  const { dialog, nativeImage } = require('electron');
  // Use system warning icon instead of app logo
  const warnIcon = nativeImage.createFromNamedImage('NSCaution');
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'none',
    icon: warnIcon || undefined,
    title: 'Metronome is ON',
    message: '⚠ Metronome (click track) is enabled!',
    detail: 'Your bounce will include the click track. What would you like to do?',
    buttons: ['Turn Off & Bounce', 'Bounce Anyway', 'Cancel'],
    defaultId: 0,
    cancelId: 2
  });
  if (result.response === 0) return 'turnoff';
  if (result.response === 1) return 'bounce';
  return 'cancel';
});

ipcMain.handle('check-cycle', () => bridge('check-cycle'));
ipcMain.handle('check-solo', () => bridge('readStates'));

ipcMain.handle('show-solo-warning', async () => {
  const { dialog, nativeImage } = require('electron');
  const warnIcon = nativeImage.createFromNamedImage('NSCaution');
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'none',
    icon: warnIcon || undefined,
    title: 'Solo is active in Logic',
    message: '⚠ One or more tracks are soloed!',
    detail: 'If you bounce now, only the soloed tracks will be heard in the mix. Remove solo first, or continue anyway.',
    buttons: ['Remove Solo & Bounce', 'Bounce Anyway', 'Cancel'],
    defaultId: 0,
    cancelId: 2
  });
  if (result.response === 0) return 'unsolo';
  if (result.response === 1) return 'bounce';
  return 'cancel';
});

ipcMain.handle('show-cycle-warning', async () => {
  const { dialog } = require('electron');
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    title: 'Cycle is OFF',
    message: '⚠️ Cycle (Loop) mode is disabled!',
    detail: 'The bounce will use the full project length instead of the cycle region. Enable Cycle in Logic first, or continue anyway.',
    buttons: ['Bounce Anyway', 'Cancel'],
    defaultId: 1,
    cancelId: 1
  });
  if (result.response === 0) return 'bounce';
  return 'cancel';
});
