# EasyBounce — Codebase Map

Reference for fast context recall. Keep this honest — update when behavior changes.

---

## Stack

- **Electron 33** (macOS only). Main process = `main.js`, renderer = `src/index.html` (single-file SPA, ~14k lines).
- **LogicBridge.swift** — native AX-based bridge to Logic Pro. Compiled to `LogicBridge` binary, invoked via `execFile` from main process. Universal (`LogicBridge_arm64`, `LogicBridge_x86`).
- **Small Swift helpers**: `BlockInput`, `CloseLogicWindows`, `EscapeLogic`, `MixerScroll`, `Patcher`. Each compiled to a named binary, each handles one AX action.
- **AppleScript** for Logic doc metadata (name, path) via `osascript`.
- **No frameworks** in renderer — plain JS + CSS variables.

---

## File Map

```
EasyBounce/
├── main.js                 Electron main process — IPC handlers, window management
├── preload.js              contextBridge → window.api
├── LogicBridge.swift       AX scan + channel actions (solo/mute/findByName/etc)
├── LogicBridge             compiled universal binary (built from .swift)
├── src/
│   ├── index.html          Entire renderer app (UI + logic + themes)
│   ├── overlay.html        Floating AOT bounce progress window
│   ├── mini.html           Legacy — current mini-mode is inside index.html
│   ├── accessibility.html  First-run AX permission prompt
│   ├── shared.css          Design tokens (colors, spacing, radii, fonts)
│   ├── icons-sprite.svg    (unused — icons are inline <symbol> in index.html)
│   └── fonts/              Space Grotesk, JetBrains Mono
├── build_dmg.sh            Full release DMG: sign + notarize + staple [arm64|x64]
├── build_dmg_test.sh       Quick test DMG without notarization (for layout checks)
├── publish.sh              One-command release: bump version + git + 2×DMG + GitHub upload
├── make_dmg_bg.py          Generates assets/dmg_bg.png via PIL (4-icon layout, glass cards)
├── SyncEasyBounce.sh       Rsyncs dev build → /Applications/EasyBounce.app
├── assign_key.js, generate_key.js, hash_keys.js, issued_keys.json
│                           Licensing (local key verification)
├── assets/
│   └── dmg_bg.png          DMG background (820×480): README + Manual + App + Applications
└── dist/                   electron-builder output
```

---

## Data Persistence

### localStorage (renderer)
| Key | Purpose |
|---|---|
| `ui.compactMode` | `'1'`/`'0'` — compact (Easy) vs expanded (Pro) |
| `sb_proj_folder_map` | `{projectName: userPickedFolder}` — overrides auto-output per project |
| `SK.folder` | Current output folder |
| `SK.project` | Last scanned project name |
| `sb4_channel_type_map` | Per-channel classification (drums/vocals/etc) |
| `sb4_master_channels` | Known "master/sum" channel names |
| (many more — see the `SK` constants block) | |

### userData (main process, `~/Library/Application Support/EasyBounce/`)
**This directory survives app updates. Drag-replace to /Applications does NOT wipe it.**

| File | Purpose |
|---|---|
| `compact-state.json` | Persists compact-mode between launches |
| `rename-history.json` | `{name: {n: count, t: timestamp}}` — autocomplete dictionary |
| `window-bounds.json` | Remembered window position/size |

### Logs
- Session logs: `~/Library/Logs/EasyBounce/easybounce_<timestamp>.log`
- Keeps last 20, deletes oldest 10 when > 20.

---

## IPC Contract (preload.js bridges main ↔ renderer)

Key channels grouped by area. All exposed as `window.api.<name>`.

### Window / Mode
- `enterCompactMode` / `exitCompactMode` / `isCompactMode`
- `enterMiniMode` / `exitMiniMode` — picture-in-picture widget (uses JS tween, 340ms ease-out cubic at `main.js:_tweenBounds`)
- `enterScanBadge` / `exitScanBadge` — 520×85 AOT scan banner
- `setAlwaysOnTop`, `setUserPin`, `setIgnoreMouseEvents`

### Logic / AX (via LogicBridge)
- `scanChannels` — full mixer scan: `{channels: [{index, name, color, isMuted, ...}], error}`
- `soloByName` / `unsoloByName` / `soloIndex` — single-channel solo
- `muteByName` / `unmuteByName` / `muteMany` / `unmuteMany` / `resetMutes`
- `channelNameAt(i)` — get name at AX index (used for sidechain guardrail)
- `findChannelByName(n)` — reverse lookup
- `openMixer` / `closeMarkerList` / `openMarkerList`
- `getProjectName` — returns `{name, path, folder}` via AppleScript `path of document 1`

### Filesystem
- `openFolder` — native dir picker
- `revealFolder`, `openLogsFolder`, `writeLog`
- `loadRenameHistory` / `saveRenameHistory` — autocomplete dict

### Bounce
- `moveToLogicSpace` — Mission Control space sync
- `runScript` — arbitrary AppleScript exec

---

## State Machines

### `_bouncePhase` (renderer, global)
Transitions during a single bounce: `solo` → `render` → `mute` → `format` → `navigate` → `naming` → `done`/`error`.

Countdown (`etaEl`) text branches by phase:
- Any setup phase (`solo`, `mute`, `format`, `navigate`, `naming`) → "Preparing…"
- `render` with AX progress 2–98% → time-based ETA
- `render` with AX progress ≥ 98% → count down `3→2→1`

Location: `src/index.html:~8330` (searchable: `_bouncePhase`, `_axLastProgress`).

### Queue item lifecycle
`pending` → `running` → `done`/`error`/`cancelled`

Status flag drives:
- Draggability (`pending`, `error`, `cancelled` draggable; `running`/`done` not)
- Reset button (`↺` visible only for terminal states)
- Color of status pill (`.qst`)

On drop of a failed item: auto-resets to `pending` (`_attachQNameEdit` area, ~line 7680).

---

## Data Models

### Queue item (`queue[i]`)
```js
{
  id: 'q_<timestamp><random>',
  name: 'Drums',                    // user-visible (editable via dblclick)
  type: 'stem' | 'mix' | 'group' | 'set',
  status: 'pending' | 'running' | 'done' | 'error' | 'cancelled',
  channelIndex, channelName, color, // for stem
  channels: [{name, channelIndex, color}],  // for group (merge)
  jobs: [{...stem/mix/group}],      // for set — nested items
  mutedIndices, mutedNames,         // for mix (version)
  markers: [...], markerMode,
  sidechainEnabled, sidechainIndex, sidechainChannel,
  stemGroup, stemPresetId,
  error?: string
}
```

### Per-stem render overrides
`modebarState.perStemOverrides` — `{ [jobId]: { master, sc, mode } }`
Allows each queue item to have its own master/sc/mode axis values, overriding global modebar.
- `_injectStemOverrideUI()` — injects ⊞ sliders button + pills into every queue row
- `_injectSetOverrideUI()` — injects ⊞ into set headers and set body rows
- Both called from a monkey-patch that wraps `renderQueue()` and fires after each render

### Queue drag & drop
- `dataTransfer.setData('qid', id)` — standard mechanism for all drag operations
- Drop on `#qlist` → reorder
- Drop on `.qset-body` → move item into set (set-in-set forbidden)
- Alt+drag set header → duplicate set with incremented name (`_qIncrName`)
- `saveUndo()` called before every destructive mutation → Cmd+Z restores via `undoQueue()`
```

### History session (persisted, array in localStorage)
```js
{
  id: <timestamp>,
  date: ISO,
  projectName: 'Track Name',
  count: 11,                        // total rendered files
  files: [                          // expanded list of what was rendered
    {
      name, type: 'stem'|'mix'|'group'|'set',
      logicName, color, channels, jobs, stemGroup, stemPresetId
    }
  ],
  formats: [...],                   // WAV/MP3/AIFF settings at time of bounce
  plugins: [...],                   // bounced-with plugin states
  status: 'success' | 'partial' | 'failed'
}
```

Restore via `repeatSession(id)` at `src/index.html:~11060` — re-adds everything to queue with original names and structure. Missing channels → warning with list.

### Channel (from `scanChannels`)
```js
{
  index: <AX position, 0-based>,
  name, color,
  isMuted: bool,
  isBus: bool,               // !hasMonitoring && !hasRecord
  hasRecord: bool,           // record button visible in AX
  hasMonitoring: bool,       // input monitoring button visible in AX
  hasInputBtn: bool,         // "input" slot button — present on Audio + Aux, absent on Inst/VCA
  hasMidiPlugin: bool,       // "MIDI plug-in" button — exclusive to Software Instrument strips
  hasBnc: bool,              // Bnc (bounce) button → Output channel
  routingBus: string,        // first "Bus N" found (backward-compat)
  outputBus: string,         // "Bus N" from Output slot (AXHelp = "Output slot")
  inputBus: string           // "Bus N" from Input slot (AXHelp = "Input slot") — aux only
}
```

#### Channel type derivation (JS, `chType`)
Computed in renderer after scan — LogicBridge does NOT emit `chType` directly:
```
hasBnc                               → 'Output'
hasRecord || hasMonitoring           → 'Audio' (or 'Inst' if hasRecord && !hasMonitoring)
hasMidiPlugin                        → 'Inst'  (Software Instrument, drum machine sub-outs)
hasInputBtn (no rec/mon/midi)        → 'Bus'   (true Aux: FX returns + summing stacks)
none of above                        → 'Other' (VCA, hardware inputs)
```

**Why `hasInputBtn` matters:** in a narrow Mixer, Logic hides `record` and `monitoring` from the AX tree. Without them, Instrument sub-outs (e.g. drum machine samples like `ILAN_RUBIN_*`) look identical to Aux channels. `hasMidiPlugin` is always visible regardless of strip width and definitively identifies Software Instrument channels.

---

## Feature Flows

### Scan (`scanLogic()` at ~line 2592)
1. Enter scan-badge mode (`enterScanBadge` → 520×85 AOT, click-through)
2. `openMixer` (AX)
3. `scanChannels` — retries up to 3× on empty result
4. `getProjectName` — returns `{name, path, folder}`. If folder present → `_autoSetOutputFromProject`
5. Populate `channels` array, render tree
6. `exitScanBadge` → restore window

### Bounce (`doBounce()` at ~line 8420)
1. **Sidechain guardrail**: for each job with `sidechainEnabled`, verify `sidechainIndex` still points to `sidechainChannel` name via `channelNameAt` + `findChannelByName`. Mismatch → 3-button modal (`_showSidechainMismatchModal`): Re-select / Bounce without / Cancel.
2. Iterate `queue` for pending jobs per marker pass.
3. Per-job: solo → bounce dialog → format → name → render (AX progress poll) → unsolo.
4. Smart retry on hang/stall: close ML, wait, reopen, resume from next pending.
5. Write `history` entry at end.

### Rename autocomplete (`_attachQNameEdit` at ~line 7336)
1. Double-click on `.qname` span → replaces with `<input>`.
2. `input` event → `_renameSuggest(typed)` → if match: fill `input.value = typed + suffix`, `setSelectionRange(typed.length, full.length)` → suffix rendered via `::selection` transparent-background, 38% currentColor.
3. Tab / → → collapse selection to end (accept).
4. Enter → commit, save dict via `saveRenameHistory` IPC.
5. Esc → revert to `oldVal`.

Dict ranking: `score = n * 10 - ageDays * 0.5`. Higher = shown first.

### Mini-mode animation (`main.js:_tweenBounds`)
JS tween 60fps, ease-out cubic, 340ms. `setBounds` called per frame without native animate flag. Min-size is lowered BEFORE tween so intermediate frames aren't clamped.

---

## Theming

Themes defined as CSS-string blocks in `src/index.html:~11850–12130`. Each theme overrides:
- body background
- `.titlebar`
- `.bbtn` (and `.bbtn.running` — different per theme; Obsidian now dims during bounce)
- `.stat-card`, `.panel`, `.modal`, `.q-item`, etc.

Active theme selected via `applySkin(name)`. Themes currently: `default` (purple), `aurora`, `apple` (blue), `glassy`, `bubblegum` (pink-purple), `luxury` (lime green), `obsidian` (grayscale), `sunset`, `ocean`, etc.

Design tokens (colors, radii, timings, font sizes) in `src/shared.css`. Prefer `var(--accent)`, `var(--fs-sm)`, `var(--r)`, `var(--t-fast)` over hardcoded values.

---

## Modes & Layouts

| Mode | Window size | Min | Purpose |
|---|---|---|---|
| Pro (default) | 1200×760 | 1130×640 | Full UI |
| Easy / Compact | 500×any | 500×500 | Narrow queue-focused panel |
| Mini | 300×88 (bottom-right) | 200×80 | PiP during bounce |
| Scan badge | 520×85 (top-center) | 200×60 | Click-through AOT during scan |

Transitions between modes wrapped in `_tweenBounds` for smoothness.

### Guards
- `_inBounce` blocks `enter-compact-mode` (but NOT `exit-compact-mode` — UI can downgrade during render).
- `_inScanBadge`, `_inMiniMode`, `_userPinned` affect AOT logic throughout main.js.
- Renderer's `toggleCompactMode` is free — doesn't block on mode state; IPC failures are silent (user wanted freedom to toggle visually during bounce).

---

## Naming Conventions

- `_foo` = private/module-local in renderer
- `SK.*` = localStorage key constants
- `MF_*` = mixer filter constants
- `ico-*` = SVG symbol IDs in the big `<defs>` block near line 966
- `q-*` / `qitem` / `qname` / `qsub` / `qst` = queue item classes
- `hist-*` = history panel classes
- `tb-*` = titlebar classes
- `em-*` / `body.easy` / `body.compact-mode` = Easy/compact mode visibility

---

## Gotchas

- **AppleScript path**: `path of document 1` works in Logic Pro. `file of document 1 as alias` throws silently — do NOT use it.
- **`setBounds(b, true)`** (native animate) jumps weird between very different sizes. Use `_tweenBounds` instead.
- **`setMinimumSize` clamps setBounds**. Lower mins BEFORE resizing smaller, set them after resizing larger.
- **`title=""` attribute + custom CSS tooltip** → OS native tooltip wins. Remove `title` when using `data-tip` + `:hover::after`.
- **`font:inherit` doesn't include `letter-spacing`**. Add `letter-spacing:inherit` separately.
- **Scan badge uses `setIgnoreMouseEvents(true, {forward:true})`** — clicks pass THROUGH to Logic. Don't expect clicks on badge.
- **Drag & drop during bounce**: reordering `queue[]` mid-iteration can shift indices past the current `i`. Failed items dropped BEFORE current index get skipped this pass.
- **Fullscreen Logic**: LogicBridge uses AX which works in fullscreen. Don't use HID clicks for fullscreen-hostile flows — fallback to AX.

---

## Common Edit Locations

Search-friendly anchors (approximate line numbers — use Grep):

| What | File | Anchor |
|---|---|---|
| Queue render | `src/index.html` | `function renderQueue` |
| Queue rename + autocomplete | `src/index.html` | `_attachQNameEdit` |
| Queue undo | `src/index.html` | `saveUndo`, `undoQueue` |
| Per-stem overrides inject | `src/index.html` | `_injectStemOverrideUI`, `_injectSetOverrideUI` |
| History render | `src/index.html` | `hist-item` template |
| Bounce loop | `src/index.html` | `doBounce` + `for (let i = 0; i < queue.length; i++)` |
| Scan | `src/index.html` | `scanLogic` |
| Sidechain modal | `src/index.html` | `_showSidechainMismatchModal` |
| Autocomplete dict | `src/index.html` | `_renameDict`, `_renameSuggest`, `_renameRecord` |
| Themes | `src/index.html` | `obsidian:`, `luxury:`, etc |
| Icons | `src/index.html` | `ico-minimize`, `<symbol id=` |
| Mini-mode UI | `src/index.html` | `mini-mode-ui` markup |
| AOT wrapper | `main.js` | `withMixerAOTPaused` |
| Tween | `main.js` | `_tweenBounds` |
| IPC handlers | `main.js` | `ipcMain.handle(` |
| AX scan core | `LogicBridge.swift` | `scanChannels` |
| Channel name lookups | `LogicBridge.swift` | `channelNameAt`, `findChannelByName` |

---

## Build / Release

```bash
# Dev run
npm start

# Sync dev build to /Applications
./SyncEasyBounce.sh

# Test DMG layout quickly (no notarization)
bash build_dmg_test.sh [arm64]

# Full release DMG for one arch (sign + notarize + staple)
bash build_dmg.sh arm64
bash build_dmg.sh x64

# Regenerate DMG background image
python3 make_dmg_bg.py

# Full publish: bump version + build both arches + GitHub release
bash publish.sh             # auto-bump patch
bash publish.sh 1.2.0       # specific version
bash publish.sh --dry-run   # build only, no GitHub upload
```

Requires Xcode command-line tools to rebuild LogicBridge (`swiftc LogicBridge.swift -o LogicBridge`).

### DMG layout (820×480)
Icons at y=184, x positions: README=140, Manual=294, EasyBounce=498, Applications=672.
Two glass cards: left (70–375), right (435–760). Arrow between cards at x=405, inner arrow at x=590.
Background generated by `make_dmg_bg.py` using PIL with `ImageChops.add` (screen blend glows).

---

## Security / Privacy

- No network calls from renderer. One exception: `_postAnalytics` in main.js on quit (anonymous ping).
- All data local. No cloud sync (by design).
- Does NOT modify Logic project file. Everything goes through AX (same as clicking manually).
- AX permission required (prompted on first launch via `accessibility.html`).

---

## FX Channel Classification (`_classifyFxChannel`)

Used by the +FX popover (Wet+Dry pass) and auto-whitelist seeding.

### Channel types in popover
Only `Bus`-type channels (true Aux) appear. Audio, Inst, Output, Other are excluded.

### Classification priority
1. `chType === 'Audio'` → excluded
2. `chType === 'Inst'` → excluded
3. `chType === 'Output'` → excluded
4. `hasRecord || hasMonitoring` → excluded (fallback when chType not set)
5. `hasMidiPlugin` → excluded (Instrument, always reliable)
6. `chType === 'Other'` → excluded (VCA, hardware input)
7. Channel is in `fxWhitelist` → **FX** (user's explicit choice)
8. `inputBus` ∈ outputBusesCache → **STACK** (summing stack)
9. `inputBus` ∉ outputBusesCache → **FX** (send return)
10. Name matches `_FX_RETURN_RX` → **FX** (heuristic fallback)
11. Name matches `_STACK_RX` → **STACK** (heuristic fallback)
12. Otherwise → **BUS** (shown in popover but not auto-selected)

### `_FX_RETURN_RX` regex notes
All terms use `\b` word boundaries to avoid false matches on preset names containing words like `plate` (e.g. `ILAN_RUBIN_snare_QDC_brass_plate_rimshot`).

### `_outputBusesCache`
Built from `_masterChannels` after each scan. Uses `outputBus` (AXHelp-confirmed) as primary, falls back to `routingBus`. Determines which buses are "output" (fed by source tracks) vs "input" (FX return targets).

### Wet+Dry two-pass muting
- `fxWhitelist` (`sessionStorage eb_fx_whitelist`) — channels muted on **DRY** pass
- `fxWetMute` (`sessionStorage eb_fx_wet_mute`) — channels muted on **WET** pass
- Both editable via +FX popover (DRY checkbox left, WET checkbox right per row)

---

## Todo / Known Issues

Keep honest — annotate as resolved when fixed.

- Compact-mode toggle during bounce can visually mismatch window size briefly. User opted OUT of blocking (wants to preview), so this is by-design.
- History entries with missing channels: warning shown but restoration still proceeds with best-effort name match.
- `inputBus` only populated when standalone Mixer is on the same Space as EasyBounce. On other Spaces: falls back to name heuristics.
- `CloseLogicWindows` can hang ~30s when Logic is on a different Space (AX blocks). Deferred fix.
