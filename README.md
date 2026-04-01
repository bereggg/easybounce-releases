# 🎛 Stem Bouncer — Logic Pro Stem Export Tool

Automated stem bouncing for Logic Pro with beautiful UI.

---

## ⚡ Quick Start (5 minutes)

### Step 1 — Install Node.js
Go to https://nodejs.org and download the **LTS** version. Install it normally.

Verify: open **Terminal** and type:
```
node -v
```
You should see something like `v20.x.x`

---

### Step 2 — Install dependencies
In Terminal, navigate to this folder:
```bash
cd /path/to/stem-bouncer
npm install
```
Wait ~1-2 minutes for Electron to download (~100MB).

---

### Step 3 — Run the app
```bash
npm start
```

That's it! The app will open. 🎉

---

## 🎚 How to Use

### 1. Load your project
- Click **"Open .logicx project"** or drag & drop your `.logicx` file
- The app reads your project and shows all tracks automatically

### 2. Select a preset
- **Full Mix** — bounce everything
- **NO Drums** — mute all drum tracks, bounce the rest
- **NO Bass** — mute bass tracks
- **NO Vocals** — instrumental version
- **Inst Only** — no drums + no bass
- **+Custom** — create your own preset, choose exactly which tracks to mute

### 3. Set output folder
- Click the output folder path to change where files are saved

### 4. Bounce!
- Click the **BOUNCE** button
- The app will guide you through Logic's bounce dialog

---

## ⚠️ Important Notes

### Why doesn't it fully automate Logic?
Logic Pro does **not have a public API** for external apps. This means:
- The app **reads** your project file perfectly (track names, types)
- For the actual bounce, it **opens Logic and guides you** through the process
- It generates AppleScript that opens Logic and pre-fills what it can

### What DOES work automatically:
✅ Reading all track names from .logicx  
✅ Preset management (NO Drums, custom presets, etc.)  
✅ Remembering your output folder  
✅ Queue management — line up multiple bounces  
✅ Activity log  
✅ Opening Logic and triggering Cmd+B  

### What requires manual steps in Logic:
⚠️ Muting specific tracks (you do this in Logic's mixer)  
⚠️ Confirming the bounce dialog  

### Pro tip — Logic Track Stacks
If you use **Track Stacks** in Logic (e.g., a "Drums" stack with all drum tracks inside), the automation works much better because you only need to mute one stack instead of individual tracks.

---

## 🔮 Advanced: Full Automation via Keyboard Maestro

For 100% hands-free operation, pair this app with **Keyboard Maestro**:

1. Create a KM macro triggered by a hotkey
2. Have it run this AppleScript to mute tracks by name:

```applescript
tell application "Logic Pro"
  -- Unfortunately Logic doesn't expose track muting via AppleScript
  -- Use Accessibility API instead via System Events
end tell

-- KM can click the mute buttons at specific coordinates
-- Record a KM macro of you muting the tracks once
-- Then replay it before each bounce
```

---

## 🛠 Troubleshooting

**"node: command not found"**  
→ Restart Terminal after installing Node.js

**"Cannot find module 'electron'"**  
→ Run `npm install` again from the stem-bouncer folder

**"Can't read .logicx file"**  
→ Logic .logicx files are macOS packages (folders disguised as files)  
→ The app tries multiple methods to read it  
→ If it fails, demo tracks are shown so you can still test presets

**App opens but tracks don't load**  
→ Try right-clicking your .logicx file in Finder → "Show Package Contents"  
→ Navigate to Alternatives/000/ — you should see project.logicx  
→ This confirms your project file structure is readable

---

## 📦 Build a standalone .app (optional)

To create a proper macOS app you can put in /Applications:
```bash
npm run pack
```
The .app will appear in `dist/` folder.

---

## 🗂 Project Structure

```
stem-bouncer/
├── main.js          — Electron main process (file I/O, AppleScript)
├── preload.js       — Secure IPC bridge
├── package.json     — Dependencies
├── src/
│   └── index.html   — Full UI (HTML + CSS + JS)
└── scripts/
    └── applescript.js — AppleScript templates
```
