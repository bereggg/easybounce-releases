#!/bin/bash
# ── EasyBounce — Release Builder ─────────────────────────────────────────────
# Builds universal (arm64 + x86_64) .app and wraps it in an installer .pkg
# that also installs the `x` terminal command to /usr/local/bin/x
#
# Usage: bash build_release.sh
# Output: dist/EasyBounce-<version>.pkg
# ─────────────────────────────────────────────────────────────────────────────

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(node -p "require('./package.json').version")
PRODUCT="EasyBounce"
OUT="$ROOT/dist"
PKG_NAME="${PRODUCT}-${VERSION}.pkg"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   EasyBounce Release Builder v${VERSION}     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Compile Swift bridges ──────────────────────────────────────────────────
echo "▶ Compiling LogicBridge (arm64 + x64)..."
swiftc -O -target arm64-apple-macos11 -o "$ROOT/LogicBridge_arm64" "$ROOT/LogicBridge.swift" 2>/dev/null
swiftc -O -target x86_64-apple-macos10.15 -o "$ROOT/LogicBridge_x64" "$ROOT/LogicBridge.swift" 2>/dev/null
lipo -create -output "$ROOT/LogicBridge" "$ROOT/LogicBridge_arm64" "$ROOT/LogicBridge_x64"
rm -f "$ROOT/LogicBridge_arm64" "$ROOT/LogicBridge_x64"
echo "  ✓ LogicBridge universal binary"

echo "▶ Compiling CloseLogicWindows (arm64 + x64)..."
swiftc -O -target arm64-apple-macos11 -o "$ROOT/CloseLogicWindows_arm64" "$ROOT/CloseLogicWindows.swift" 2>/dev/null
swiftc -O -target x86_64-apple-macos10.15 -o "$ROOT/CloseLogicWindows_x64" "$ROOT/CloseLogicWindows.swift" 2>/dev/null
lipo -create -output "$ROOT/CloseLogicWindows" "$ROOT/CloseLogicWindows_arm64" "$ROOT/CloseLogicWindows_x64"
rm -f "$ROOT/CloseLogicWindows_arm64" "$ROOT/CloseLogicWindows_x64"
echo "  ✓ CloseLogicWindows universal binary"

# ── 2. Build Electron app (universal) ────────────────────────────────────────
echo ""
echo "▶ Building Electron app (universal: arm64 + x64)..."
cd "$ROOT"
npx electron-builder --mac dir --universal 2>&1 | grep -E "target|error|warn|✓|packed|•" || true
echo "  ✓ Electron build done"

# Find the built .app
APP_SRC=$(find "$OUT" -name "${PRODUCT}.app" -maxdepth 3 | head -1)
if [ -z "$APP_SRC" ]; then
  echo "❌ Could not find built ${PRODUCT}.app in dist/"
  exit 1
fi
echo "  Found: $APP_SRC"

# Inject NSAppleEventsUsageDescription into built app's Info.plist
BUILT_PLIST="$APP_SRC/Contents/Info.plist"
if ! /usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$BUILT_PLIST" &>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string 'EasyBounce needs to control Logic Pro and System Events to automate bouncing.'" "$BUILT_PLIST"
fi
codesign --force --deep --sign - "$APP_SRC" 2>/dev/null

# ── 3. Build PKG payload ───────────────────────────────────────────────────────
echo ""
echo "▶ Assembling PKG payload..."

PKG_ROOT="$OUT/pkg_root"
PKG_SCRIPTS="$OUT/pkg_scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/Applications"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_SCRIPTS"

# Copy app
cp -r "$APP_SRC" "$PKG_ROOT/Applications/${PRODUCT}.app"
echo "  ✓ App → /Applications/${PRODUCT}.app"

# Copy x script
cp "$ROOT/x" "$PKG_ROOT/usr/local/bin/x"
chmod +x "$PKG_ROOT/usr/local/bin/x"
echo "  ✓ x script → /usr/local/bin/x"

# ── 4. postinstall script ─────────────────────────────────────────────────────
cat > "$PKG_SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
# Make x executable (just in case)
chmod +x /usr/local/bin/x

# Remove quarantine from app
xattr -cr /Applications/EasyBounce.app 2>/dev/null || true

echo "✅ EasyBounce installed!"
echo "   App: /Applications/EasyBounce.app"
echo "   Terminal command: x  (triggers bounce from anywhere)"
exit 0
POSTINSTALL
chmod +x "$PKG_SCRIPTS/postinstall"

# ── 5. Build component pkg ────────────────────────────────────────────────────
echo ""
echo "▶ Building PKG..."

COMPONENT_PKG="$OUT/component.pkg"
FINAL_PKG="$OUT/${PKG_NAME}"

pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier "com.easybounce.app" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_PKG"

# ── 6. Create distribution XML for productbuild ───────────────────────────────
DIST_XML="$OUT/distribution.xml"
cat > "$DIST_XML" << DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>EasyBounce ${VERSION}</title>
  <organization>com.easybounce</organization>
  <domains enable_localSystem="true"/>
  <options customize="never" require-scripts="true" rootVolumeOnly="true"/>
  <welcome file="welcome.html" mime-type="text/html"/>
  <background file="icon.png" alignment="bottomleft" scaling="none"/>
  <choices-outline>
    <line choice="default">
      <line choice="com.easybounce.app"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="com.easybounce.app" visible="false">
    <pkg-ref id="com.easybounce.app"/>
  </choice>
  <pkg-ref id="com.easybounce.app" version="${VERSION}" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
DISTXML

# Create welcome page
WELCOME_HTML="$OUT/welcome.html"
cat > "$WELCOME_HTML" << 'WELCOME'
<html><body style="font-family:-apple-system,sans-serif;padding:20px;color:#1c1c1e;background:#f5f5f7;">
<h2 style="color:#6c63ff;">🎚 EasyBounce</h2>
<p>Logic Pro stem bouncer — automatic, fast, reliable.</p>
<p>This installer will:</p>
<ul>
  <li>Install <strong>EasyBounce.app</strong> to /Applications</li>
  <li>Install the <strong><code>x</code></strong> terminal command to /usr/local/bin<br>
    <small style="color:#666;">Type <code>x</code> in any Terminal window to instantly trigger a bounce</small>
  </li>
</ul>
<p style="color:#666;font-size:12px;">Requires macOS 11+ (Apple Silicon native, Intel supported)</p>
</body></html>
WELCOME

# Copy icon for background
cp "$ROOT/assets/icon.png" "$OUT/icon.png" 2>/dev/null || true

productbuild \
  --distribution "$DIST_XML" \
  --package-path "$OUT" \
  --resources "$OUT" \
  "$FINAL_PKG"

# Cleanup temp files
rm -f "$COMPONENT_PKG" "$DIST_XML" "$WELCOME_HTML" "$OUT/icon.png"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"

# ── 7. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✅  BUILD COMPLETE                     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  PKG: $FINAL_PKG"
echo "  Size: $(du -sh "$FINAL_PKG" | cut -f1)"
echo ""
echo "  Install: open \"$FINAL_PKG\""
echo "  After install, type 'x' in Terminal to bounce 🎚"
echo ""
