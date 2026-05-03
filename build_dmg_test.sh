#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="${1:-arm64}"

if [ "$ARCH" = "x64" ]; then
  APP_SRC="$ROOT/dist/mac/EasyBounce.app"
else
  APP_SRC="$ROOT/dist/mac-${ARCH}/EasyBounce.app"
fi

VERSION=$(node -p "require('${ROOT}/package.json').version")
TMP_DIR="$ROOT/dist/dmg_test_tmp"
DMG_OUT="$ROOT/dist/EasyBounce-TEST.dmg"

if [ ! -d "$APP_SRC" ]; then
  echo "❌ Не знайдено: $APP_SRC"
  echo "   Запусти спочатку: npm run build:${ARCH}"
  exit 1
fi

echo "▶ Preparing DMG contents…"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
ditto "$APP_SRC" "$TMP_DIR/EasyBounce.app"
cp "$ROOT/README.txt" "$TMP_DIR/README.txt"
cp "$ROOT/manual/easybounce-manual_full.pdf" "$TMP_DIR/EasyBounce Manual.pdf"
ln -s /Applications "$TMP_DIR/Applications"

APP_SIZE=$(du -smL "$APP_SRC" 2>/dev/null | cut -f1)
PDF_SIZE=$(du -sm "$ROOT/manual/easybounce-manual_full.pdf" 2>/dev/null | cut -f1)
DMG_SIZE=$((APP_SIZE + PDF_SIZE + 100))

echo "▶ Creating DMG (${DMG_SIZE}MB)…"
rm -f "$DMG_OUT"
hdiutil create -volname "EasyBounce" -size ${DMG_SIZE}m -fs HFS+ -ov "$DMG_OUT"

echo "▶ Mounting…"
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -nobrowse "$DMG_OUT")
MOUNT_DIR=$(echo "$MOUNT_INFO" | grep "/Volumes/" | sed 's/.*\/Volumes\//\/Volumes\//' | tail -1)
DISK_DEV=$(echo "$MOUNT_INFO" | grep "^/dev/" | head -1 | awk '{print $1}')
echo "  Mounted at: $MOUNT_DIR"
sleep 1

echo "▶ Copying files…"
ditto "$TMP_DIR/EasyBounce.app" "$MOUNT_DIR/EasyBounce.app"
cp "$TMP_DIR/README.txt" "$MOUNT_DIR/"
cp "$TMP_DIR/EasyBounce Manual.pdf" "$MOUNT_DIR/EasyBounce Manual.pdf"
ln -s /Applications "$MOUNT_DIR/Applications"
sleep 1

mkdir -p "$MOUNT_DIR/.background"
cp "$ROOT/assets/dmg_bg.png" "$MOUNT_DIR/.background/bg.png"

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
    set position of item "README.txt"            of container window to {140, 184}
    set position of item "EasyBounce Manual.pdf" of container window to {294, 184}
    set position of item "EasyBounce"            of container window to {498, 184}
    set position of item "Applications"          of container window to {672, 184}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

echo "▶ Unmounting…"
hdiutil detach "$DISK_DEV" 2>/dev/null || hdiutil detach "$MOUNT_DIR" 2>/dev/null
rm -rf "$TMP_DIR"

echo ""
echo "✅ TEST DMG: $DMG_OUT"
open -R "$DMG_OUT"
