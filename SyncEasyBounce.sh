#!/bin/bash
# SyncEasyBounce — run this to sync all changes to the app
# Put this file in WORK-/EasyBounce/ folder

WORK="/Users/dbsound/Desktop/WORK-/EasyBounce"
APP="/Applications/EasyBounce.app"

echo "🔄 Syncing EasyBounce..."

# Kill running app
pkill -f "EasyBounce" 2>/dev/null
sleep 0.5

# Update asar
cd /tmp
rm -rf eb_sync
npx asar extract "$APP/Contents/Resources/app.asar" eb_sync 2>/dev/null

cp "$WORK/src/index.html" eb_sync/src/index.html
cp "$WORK/main.js" eb_sync/main.js
cp "$WORK/preload.js" eb_sync/preload.js
cp "$WORK/license.js" eb_sync/license.js 2>/dev/null
cp "$WORK/LogicBridge" eb_sync/LogicBridge 2>/dev/null

npx asar pack eb_sync "$APP/Contents/Resources/app.asar" 2>/dev/null
rm -rf eb_sync

# Also update the unpacked binary (this is what the app actually executes)
if [ -f "$WORK/LogicBridge" ]; then
  cp "$WORK/LogicBridge" "$APP/Contents/Resources/app.asar.unpacked/LogicBridge"
fi

echo "✅ Done! Opening EasyBounce..."
open "$APP"
