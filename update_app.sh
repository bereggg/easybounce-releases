#!/bin/bash
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
cd "/Users/dbsound/Desktop/WORK-/EasyBounce"

# Compile Swift as universal binary (arm64 + x86_64)
echo "Compiling LogicBridge…"
swiftc LogicBridge.swift -o LogicBridge_arm64 -target arm64-apple-macos10.15 2>&1 | grep -v warning || true
swiftc LogicBridge.swift -o LogicBridge_x86 -target x86_64-apple-macos10.15 2>&1 | grep -v warning || true
lipo -create -output LogicBridge LogicBridge_arm64 LogicBridge_x86

echo "Compiling CloseLogicWindows…"
swiftc CloseLogicWindows.swift -o CloseLogicWindows -target arm64-apple-macosx12.0 -framework ApplicationServices -framework AppKit 2>&1 | grep -v warning || true

# Check if app exists
if [ ! -d "/Applications/EasyBounce.app" ]; then
  echo "❌ /Applications/EasyBounce.app not found. Build it first with electron-builder."
  exit 1
fi

# Kill the app before modifying files
pkill -x "EasyBounce" 2>/dev/null; sleep 0.5

# Extract, update files, repack asar
cd /tmp && rm -rf ea
npx asar extract "/Applications/EasyBounce.app/Contents/Resources/app.asar" ea
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/LogicBridge" ea/LogicBridge
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/CloseLogicWindows" ea/CloseLogicWindows
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/main.js" ea/main.js
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/preload.js" ea/preload.js
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/license.js" ea/license.js
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/notifications.js" ea/notifications.js
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/src/index.html" ea/src/index.html
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/src/overlay.html" ea/src/overlay.html
# Sync node_modules (dependencies needed at runtime: @sendgrid, electron-updater)
mkdir -p ea/node_modules
# no extra npm packages needed — email uses native fetch
# Copy accessibility page if it exists
[ -f "/Users/dbsound/Desktop/WORK-/EasyBounce/src/accessibility.html" ] && cp "/Users/dbsound/Desktop/WORK-/EasyBounce/src/accessibility.html" ea/src/accessibility.html
npx asar pack ea "/Applications/EasyBounce.app/Contents/Resources/app.asar"
rm -rf ea

# Update unpacked binary
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/LogicBridge" "/Applications/EasyBounce.app/Contents/Resources/app.asar.unpacked/LogicBridge"
cp "/Users/dbsound/Desktop/WORK-/EasyBounce/CloseLogicWindows" "/Applications/EasyBounce.app/Contents/Resources/app.asar.unpacked/CloseLogicWindows"

# Also update dist/mac-universal so build_dmg.sh always gets the latest binary
UNIVERSAL_LB="/Users/dbsound/Desktop/WORK-/EasyBounce/dist/mac-universal/EasyBounce.app/Contents/Resources/app.asar.unpacked/LogicBridge"
if [ -f "$UNIVERSAL_LB" ]; then
  cp "/Users/dbsound/Desktop/WORK-/EasyBounce/LogicBridge" "$UNIVERSAL_LB"
fi

# Inject NSAppleEventsUsageDescription into Info.plist (required for Automation permission dialog)
PLIST="/Applications/EasyBounce.app/Contents/Info.plist"
if ! /usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$PLIST" &>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string 'EasyBounce needs to control Logic Pro and System Events to automate bouncing.'" "$PLIST"
fi

# Re-sign. Use the SAME identity each time to avoid TCC invalidation
echo "Re-signing app…"
codesign --force --deep --sign - "/Applications/EasyBounce.app" 2>/dev/null

# DON'T reset TCC! The ad-hoc signature is stable enough.
# Only reset if the user explicitly asks or if they have issues.
# tccutil reset would force re-approval every update.

echo "Starting EasyBounce…"
open "/Applications/EasyBounce.app"
sleep 2

# Check if accessibility is granted
TRUSTED=$(osascript -e 'tell application "System Events" to get name of first process whose name is "EasyBounce"' 2>&1)
if echo "$TRUSTED" | grep -q "EasyBounce"; then
  echo "✅ Accessibility permission is OK"
else
  echo "⚠️  Accessibility might need re-approval."
  echo "   The app will show a dialog — follow it to grant permission."
fi

echo "Done!"
