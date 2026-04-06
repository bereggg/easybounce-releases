const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const http = require('http');
// Prevent macOS from throttling JS timers in hidden/background windows
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-background-timer-throttling');
const { validateKey, getMachineId, getTrialInfo, activateTrial, STORAGE_KEY } = require('./license');
const notifications = require('./notifications');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

let mainWindow;
let _preMini = null;
let _overlayWindow = null;
// In packaged app LogicBridge is in app.asar.unpacked (not executable from inside asar)
const BRIDGE = app.isPackaged
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'LogicBridge')
  : path.join(__dirname, 'LogicBridge');
let cancelRequested = false;
let _scanTreeActive = false;

function createWindow() {
  // Clamp initial window size to available work area (screen minus dock + menu bar)
  const { screen } = require('electron');
  const { width: sw, height: sh } = screen.getPrimaryDisplay().workAreaSize;
  const winW = Math.min(1200, Math.max(1000, sw - 20));
  const winH = Math.min(760,  Math.max(640,  sh - 20));

  mainWindow = new BrowserWindow({
    width: winW, height: winH,
    minWidth: 1000, minHeight: 640,
    titleBarStyle: 'hiddenInset',
    vibrancy: 'under-window',
    visualEffectState: 'active',
    backgroundColor: '#00000000',
    transparent: true,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js')
    }
  });
  const srcPath = path.join(__dirname, 'src', 'index.html');
  const devPath = '/Users/dbsound/Desktop/WORK-/EasyBounce/src/index.html';
  const fs2 = require('fs');
  // isDev = true on developer's machine (source files present), false on end-user's Mac
  const isDev = fs2.existsSync(devPath);
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
  // ── PRODUCTION: block DevTools + silence renderer console ──────────────────
  if (!isDev) {
    mainWindow.webContents.on('devtools-opened', () => {
      mainWindow.webContents.closeDevTools();
    });
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
  try { execAsync('killall caffeinate 2>/dev/null').catch(() => {}); } catch(e) {}

  // ── Step 1: License / Trial check ─────────────────────────────────────────
  const licenseFile = path.join(app.getPath('userData'), 'license.json');
  let licensed = false;
  try {
    const data = JSON.parse(fs.readFileSync(licenseFile, 'utf8'));
    if (data.machineId === getMachineId() && data.key) licensed = true;
  } catch(e) {}

  if (!licensed) {
    try {
      const trial = await getTrialInfo();
      if (trial.active) licensed = true;
    } catch(e) {}
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
async function bridge(...args) {
  if (!fs.existsSync(BRIDGE)) {
    return { error: 'LogicBridge not found — run: swiftc LogicBridge.swift -o LogicBridge -framework ApplicationServices -framework AppKit' };
  }
  return new Promise((resolve) => {
    const { execFile } = require('child_process');
    execFile(BRIDGE, args, { timeout: 30000 }, (err, stdout) => {
      try { resolve(JSON.parse((stdout || '').trim())); }
      catch { resolve({ error: err?.message || 'parse error' }); }
    });
  });
}

// ── IPC handlers ──────────────────────────────────────────────────────────────
ipcMain.handle('scan-channels', () => bridge('scan'));
ipcMain.handle('scan-master-plugins', () => bridge('scanMasterPlugins'));
ipcMain.handle('master-plugins', () => bridge('masterPlugins'));
ipcMain.handle('set-master-plugin', (_, name, active) => bridge('setMasterPlugin', name, String(active)));
ipcMain.handle('set-all-master-plugins', (_, active) => bridge('setAllMasterPlugins', String(active)));
ipcMain.handle('master-plugins-quick', () => bridge('masterPluginsQuick'));
ipcMain.handle('scan-tree', async () => {
  _scanTreeActive = true;
  // Step aside so CGEvent Option+click reaches Logic, not our alwaysOnTop overlay
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow) mainWindow.setAlwaysOnTop(false);
  try { return await bridge('scan-tree'); }
  finally {
    _scanTreeActive = false;
    if (mainWindow && wasOnTop) {
      mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
      mainWindow.showInactive();
    }
  }
});
ipcMain.handle('maximize-logic',         () => bridge('maximizeLogic'));
ipcMain.handle('exit-fullscreen-only',   () => bridge('exitFullscreenOnly'));
ipcMain.handle('minimize-inspector', async () => {
  // Step aside so CGEvent drag reaches Logic, not our alwaysOnTop overlay
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow) mainWindow.setAlwaysOnTop(false);
  const result = await bridge('minimizeInspector');
  if (mainWindow && wasOnTop) {
    mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
    mainWindow.showInactive(); // re-show badge if it went behind Logic during drag
  }
  return result;
});
ipcMain.handle('check-inspector', () => bridge('checkInspector'));
ipcMain.handle('open-mixer', () => bridge('openMixer'));
ipcMain.handle('close-mixer', () => bridge('closeMixer'));
ipcMain.handle('ensure-mixer', () => bridge('ensureMixer'));
ipcMain.handle('send-key', (_, keyCode, ...mods) => bridge('sendKey', String(keyCode), ...mods));
ipcMain.handle('stop-render', () => bridge('stop-render'));
ipcMain.handle('type-text', (_, text) => bridge('typeText', text));
ipcMain.handle('click-window-button', (_, name) => bridge('clickWindowButton', name));
ipcMain.handle('get-windows', () => bridge('getWindows'));
ipcMain.handle('set-filename-bounce', (_, name) => bridge('setFilenameAndBounce', name));
ipcMain.handle('set-filename-and-bounce', (_, name) => bridge('setFilenameAndBounce', name));
ipcMain.handle('check-metronome', () => bridge('metronome'));
ipcMain.handle('set-format', async (_, fmt, bit, sr) => {
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow) mainWindow.setAlwaysOnTop(false);
  try { return await bridge('setFormat', fmt, bit, sr); }
  finally {
    if (mainWindow && wasOnTop) {
      mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
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
ipcMain.handle('cancel-bounce', () => { cancelRequested = true;  return { ok: true }; });
ipcMain.handle('reset-cancel',  () => { cancelRequested = false; return { ok: true }; });
ipcMain.handle('check-cancel',  () => ({ cancelled: cancelRequested }));

// ── Shell commands (for caffeinate etc.) ─────────────────────────────────────
ipcMain.handle('run-shell', async (_, cmd) => {
  const { exec } = require('child_process');
  return new Promise(resolve => {
    exec(cmd, { timeout: 30000 }, (err, stdout) => resolve({ ok: !err, stdout: (stdout || '').trim() }));
  });
});
ipcMain.handle('hide-window', () => {
  if (mainWindow) { mainWindow.setAlwaysOnTop(false); mainWindow.hide(); }
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

ipcMain.handle('check-logic', async () => {
  try {
    const { stdout } = await execAsync('ps aux | grep -i "logic pro" | grep -v grep');
    return { running: stdout.trim().length > 0 };
  } catch { return { running: false }; }
});

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

ipcMain.handle('run-script', async (_, script) => {
  const tmp = path.join(app.getPath('temp'), 'sb_script.scpt');
  fs.writeFileSync(tmp, script);
  try {
    const { stdout } = await execAsync(`osascript "${tmp}"`, { timeout: 30000 });
    return { ok: true, output: stdout.trim() };
  } catch (e) { return { ok: false, error: e.message }; }
  finally { try { fs.unlinkSync(tmp); } catch {} }
});

ipcMain.handle('wait', (_, ms) => new Promise(r => {
  // Resolve immediately if cancel was requested — makes cancel feel instant
  const end = Date.now() + ms;
  const tick = setInterval(() => {
    if (cancelRequested || Date.now() >= end) { clearInterval(tick); r(); }
  }, 80);
}));
ipcMain.handle('get-home', () => require('os').homedir());
ipcMain.handle('set-clipboard', (_, text) => { require('child_process').execSync('printf "%s" "' + text.replace(/"/g, '\"') + '" | pbcopy'); return {ok:true}; });

ipcMain.handle('mkdir', (_, p) => {
  require('fs').mkdirSync(p, { recursive: true });
  return { ok: true };
});

// Check if any file whose name starts with `prefix` exists in `folder`
ipcMain.handle('find-file', (_, folder, prefix) => {
  try {
    const files = require('fs').readdirSync(folder);
    return files.some(f => f.startsWith(prefix));
  } catch(e) { return false; }
});
ipcMain.handle('mute-by-name',   (_, n) => bridge('muteByName',   n));
ipcMain.handle('unmute-by-name', (_, n) => bridge('unmuteByName', n));
ipcMain.handle('solo-by-name',   (_, n) => bridge('soloByName',   n));
ipcMain.handle('unsolo-by-name', (_, n) => bridge('unsoloByName', n));
ipcMain.handle('mute-many',   (_, names) => bridge('muteMany',   names.join('|')));
ipcMain.handle('unmute-many', (_, names) => bridge('unmuteMany', names.join('|')));
ipcMain.handle('reset-mutes', () => bridge('resetMutes'));
ipcMain.handle('mixer-get-filters',    () => bridge('getMixerFilters'));
ipcMain.handle('mixer-filter-toggle',  (_, name) => bridge('mixerFilterToggle', name));
ipcMain.handle('mixer-enable-all',     () => bridge('enableAllMixerFilters'));
ipcMain.handle('set-mixer-height', (_, h) => bridge('setMixerHeight', String(h || 280)));
ipcMain.handle('apply-bounce-preset', async (_, params) => {
  // Step aside so popup menus appear above Logic, not behind our alwaysOnTop overlay
  const wasOnTop = mainWindow?.isAlwaysOnTop?.() ?? false;
  if (mainWindow) mainWindow.setAlwaysOnTop(false);
  try { return await bridge('applyBouncePreset', JSON.stringify(params)); }
  finally {
    if (mainWindow && wasOnTop) {
      mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
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
  } catch(e) {}
  await new Promise(r => setTimeout(r, 600));
  // Re-activate Logic to be sure we're on its Space
  try {
    await execAsync(`osascript -e 'tell application "Logic Pro" to activate'`);
  } catch(e) {}
  await new Promise(r => setTimeout(r, 200));
  mainWindow.setVisibleOnAllWorkspaces(false);
  await new Promise(r => setTimeout(r, 80));
  mainWindow.show();
  mainWindow.focus();
  return { ok: true };
});
ipcMain.handle('set-always-on-top', (_, val) => {
  if (mainWindow) {
    if (val) {
      // 'pop-up-menu' is above Logic's menus — EasyBounce stays visible during AX interactions
      mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
    } else {
      mainWindow.setAlwaysOnTop(false);
    }
  }
  return { ok: true };
});

// ── Mini Mode — resize main window to compact widget ──────────────────────────
ipcMain.handle('enter-mini-mode', () => {
  if (!mainWindow) return { ok: false };
  _preMini = mainWindow.getBounds();
  const { screen } = require('electron');
  const display = screen.getDisplayNearestPoint({ x: _preMini.x, y: _preMini.y });
  const { x: dx, y: dy, width: dw, height: dh } = display.workArea;
  mainWindow.setMinimumSize(200, 80);
  mainWindow.setResizable(false);
  mainWindow.setBounds({ x: dx + dw - 320, y: dy + dh - 108, width: 300, height: 88 }, true);
  mainWindow.setAlwaysOnTop(true, 'floating');
  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  return { ok: true };
});

ipcMain.handle('exit-mini-mode', () => {
  if (!mainWindow) return { ok: false };
  mainWindow.setMinimumSize(1000, 640);
  mainWindow.setResizable(true);
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
  const { x: dx, y: dy, width: dw, height: dh } = screen.getPrimaryDisplay().workArea;
  const W = 300, H = 92;
  // Top-left corner — mirrored to mini mode (bottom-right).
  // This area has no critical Logic UI, so blocking clicks there is fine.
  _overlayWindow = new BrowserWindow({
    width: W, height: H,
    x: dx,
    y: dy,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: false,
    movable: true,
    skipTaskbar: true,
    hasShadow: false,
    show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false }
  });
  _overlayWindow.setAlwaysOnTop(true, 'screen-saver');
  _overlayWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  const overlayPath = app.isPackaged
    ? path.join(app.getAppPath(), 'src', 'overlay.html')
    : path.join(__dirname, 'src', 'overlay.html');
  // did-finish-load is more reliable than ready-to-show for transparent windows
  _overlayWindow.webContents.once('did-finish-load', () => {
    if (_overlayWindow && !_overlayWindow.isDestroyed()) {
      _overlayWindow.show();
      // Re-give Logic the focus we just took
      require('child_process').exec('osascript -e \'tell application id "com.apple.logic10" to activate\'');
    }
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

// ── Scan Badge Mode — shrink window to scan warning badge only ────────────────
let _preScan = null;
ipcMain.handle('enter-scan-badge', () => {
  if (!mainWindow) return { ok: false };
  _preScan = mainWindow.getBounds();
  const { screen } = require('electron');
  const display = screen.getDisplayNearestPoint({ x: _preScan.x, y: _preScan.y });
  const { x: dx, y: dy, width: dw, height: dh } = display.workArea;
  const bw = 380; const bh = 80;
  mainWindow.setMinimumSize(200, 60);
  mainWindow.setResizable(false);
  // Bottom-right corner — visible but out of Logic's way
  mainWindow.setBounds({ x: dx + dw - bw - 16, y: dy + dh - bh - 16, width: bw, height: bh }, false);
  mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
  // Don't steal focus from Logic — just show badge on top
  mainWindow.showInactive();
  return { ok: true };
});

ipcMain.handle('exit-scan-badge', () => {
  if (!mainWindow) return { ok: false };
  mainWindow.setMinimumSize(1000, 640);
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
const APPCAST_URL = 'https://raw.githubusercontent.com/bereggg/easybounce-releases/main/appcast.xml';
const CURRENT_VERSION = '1.0.0';

let _updateAvailable = null; // {version, url} or null
async function checkForUpdates(silent = false) {
  try {
    const https = require('https');
    const xml = await new Promise((resolve, reject) => {
      https.get(APPCAST_URL, res => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => resolve(data));
      }).on('error', reject);
    });

    const match = xml.match(/sparkle:version="([^"]+)"/);
    if (!match) return { hasUpdate: false };

    const latestVersion = match[1];
    if (latestVersion !== CURRENT_VERSION) {
      _updateAvailable = { version: latestVersion };
      // Notify renderer about update
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('update-available', latestVersion);
      }
      // renderer handles UI when not silent
      return { hasUpdate: true, version: latestVersion };
    } else {
      _updateAvailable = null;
      return { hasUpdate: false };
    }
  } catch(e) { return { hasUpdate: false }; }
}

ipcMain.handle('check-for-updates', () => checkForUpdates(false));
ipcMain.handle('check-for-updates-silent', () => checkForUpdates(true));

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
    } catch(e) {}
    try { fs.writeFileSync(firstRunFlag, '1'); } catch(e) {}
  }
});

// ── License ─────────────────────────────────────────────────────────────────────
ipcMain.handle('validate-license', (_, key) => {
  const result = validateKey(key);
  if (result.valid) {
    // Store activation with machine binding
    const machineId = getMachineId();
    const activation = { key, machineId, activatedAt: Date.now(), version: result.version };
    require('electron').app.commandLine; // dummy
    try {
      const store = require('path').join(app.getPath('userData'), 'license.json');
      require('fs').writeFileSync(store, JSON.stringify(activation));
    } catch(e) {}
  }
  return result;
});

ipcMain.handle('check-license', async () => {
  // 1. Check license key first (takes priority over trial)
  try {
    const store = require('path').join(app.getPath('userData'), 'license.json');
    const data = JSON.parse(require('fs').readFileSync(store, 'utf8'));
    const machineId = getMachineId();
    if (data.machineId === machineId && data.key) {
      const result = await validateKey(data.key);
      if (result.valid) return { licensed: true, key: data.key, version: result.version };
    }
  } catch(e) {}

  // 2. Fall back to trial
  try {
    const trial = await getTrialInfo();
    if (trial.active) return { licensed: true, trial: true, daysRemaining: trial.daysRemaining };
  } catch(e) {}

  return { licensed: false };
});

ipcMain.handle('get-machine-id', () => getMachineId());

ipcMain.handle('get-trial-info', async () => getTrialInfo());

ipcMain.handle('activate-trial', async () => {
  const trial = await activateTrial();
  if (trial.ok && trial.active) {
    setTimeout(() => { ipcMain.emit('license-activated'); }, 600);
  }
  return trial;
});

ipcMain.handle('activate-and-launch', async (_, key) => {
  const { validateKey, getMachineId } = require('./license');
  const result = await validateKey(key);
  if (result.valid) {
    const machineId = getMachineId();
    const licenseFile = path.join(app.getPath('userData'), 'license.json');
    fs.writeFileSync(licenseFile, JSON.stringify({ key, machineId, activatedAt: Date.now() }));
    // Emit license-activated — whenReady handler creates window and destroys licWin
    setTimeout(() => { ipcMain.emit('license-activated'); }, 800);
    return { ok: true };
  }
  return { ok: false, reason: result.reason || 'Invalid key' };
});
ipcMain.handle('show-confirm', async (_, title, message) => {
  const { dialog } = require('electron');
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
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
  const { dialog } = require('electron');
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    title: 'Metronome is ON',
    message: '⚠️ Metronome (click track) is enabled!',
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
  const { dialog } = require('electron');
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    title: 'Solo is active in Logic',
    message: '⚠️ One or more tracks are soloed!',
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
