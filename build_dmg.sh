#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="1.0.0"
DMG_NAME="EasyBounce-${VERSION}"
TMP_DIR="$ROOT/dist/dmg_tmp"
DMG_TMP="$ROOT/dist/${DMG_NAME}_tmp.dmg"
DMG_OUT="$ROOT/dist/${DMG_NAME}.dmg"

# ── Source: universal build (works on Apple Silicon + Intel) ──────────────────
APP_SRC="$ROOT/dist/mac-universal/EasyBounce.app"
if [ ! -d "$APP_SRC" ]; then
  echo "❌ Universal build not found: $APP_SRC"
  echo "   Run: npm run build:universal  first"
  exit 1
fi

echo "▶ Preparing DMG contents…"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# ── Copy app + README ─────────────────────────────────────────────────────────
cp -r "$APP_SRC" "$TMP_DIR/EasyBounce.app"
cp "$ROOT/README.txt" "$TMP_DIR/README.txt"
ln -s /Applications "$TMP_DIR/Applications"

# Follow symlinks (-L) for accurate size, add 300MB buffer for HFS+ overhead
APP_SIZE=$(du -smL "$APP_SRC" 2>/dev/null | cut -f1)
DMG_SIZE=$((APP_SIZE + 300))

# ── Create empty writable DMG ─────────────────────────────────────────────────
echo "▶ Creating DMG (${DMG_SIZE}MB)…"
rm -f "$DMG_TMP" "$DMG_OUT"
hdiutil create -volname "EasyBounce" \
  -size ${DMG_SIZE}m \
  -fs HFS+ \
  -ov \
  "$DMG_TMP"

# ── Mount ──────────────────────────────────────────────────────────────────────
echo "▶ Mounting…"
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -nobrowse "$DMG_TMP")
MOUNT_DIR=$(echo "$MOUNT_INFO" | grep "/Volumes/" | sed 's/.*\/Volumes\//\/Volumes\//' | tail -1)
DISK_DEV=$(echo "$MOUNT_INFO" | grep "^/dev/" | head -1 | awk '{print $1}')
echo "  Mounted at: $MOUNT_DIR"
sleep 1

# ── Copy files into mounted DMG ───────────────────────────────────────────────
echo "▶ Copying files…"
cp -r "$TMP_DIR/EasyBounce.app" "$MOUNT_DIR/"
cp "$TMP_DIR/README.txt" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"
sleep 1

# ── Copy background ────────────────────────────────────────────────────────────
mkdir -p "$MOUNT_DIR/.background"
cp "$ROOT/assets/dmg_bg.png" "$MOUNT_DIR/.background/bg.png"

# ── Set window layout via osascript ───────────────────────────────────────────
# Layout (left → right): README.txt | EasyBounce.app | Applications
echo "▶ Setting window layout…"
VOL_NAME=$(basename "$MOUNT_DIR")
osascript << APPLESCRIPT
tell application "Finder"
  tell disk "${VOL_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 100, 1020, 580}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 72
    set background picture of theViewOptions to file ".background:bg.png"
    -- Left: README.txt, Center: EasyBounce.app, Right: Applications
    set position of item "README.txt"   of container window to {220, 184}
    set position of item "EasyBounce"   of container window to {374, 184}
    set position of item "Applications" of container window to {528, 184}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# ── Unmount ────────────────────────────────────────────────────────────────────
echo "▶ Finalizing…"
hdiutil detach "$DISK_DEV" 2>/dev/null || hdiutil detach "$MOUNT_DIR" 2>/dev/null
sleep 1

# ── Convert to compressed read-only DMG ───────────────────────────────────────
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT"
rm -f "$DMG_TMP"
rm -rf "$TMP_DIR"

echo ""
echo "✅ Done: $DMG_OUT"
echo "   Size: $(du -sh "$DMG_OUT" | cut -f1)"
echo "   Arch: universal (Apple Silicon + Intel)"
