#!/usr/bin/env node
const { execSync } = require('child_process');
const path = require('path');

// APP_ARCH passed as env var from build_dmg.sh: APP_ARCH=arm64 node sign_app.js
const arch = process.env.APP_ARCH || 'arm64';
// electron-builder outputs "mac" for x64, "mac-arm64" for arm64
const macDir = arch === 'x64' ? 'mac' : `mac-${arch}`;
const APP = path.resolve(__dirname, `dist/${macDir}/EasyBounce.app`);
const IDENTITY = 'Developer ID Application: Dmytro Berezhnyi (2VKTV5VPVB)';
const ENTITLEMENTS = path.resolve(__dirname, 'entitlements.mac.plist');
const OSX_SIGN = path.resolve(__dirname, 'node_modules/@electron/osx-sign/bin/electron-osx-sign.js');

const sign = (target) => execSync(
  `codesign --force --sign "${IDENTITY}" --timestamp --options runtime --entitlements "${ENTITLEMENTS}" "${target}"`,
  { stdio: 'pipe' }
);

// Step 1: osx-sign для всього
console.log('  Running @electron/osx-sign…');
execSync(`node "${OSX_SIGN}" "${APP}" --identity="${IDENTITY}" --hardened-runtime --entitlements="${ENTITLEMENTS}" --entitlements-inherit="${ENTITLEMENTS}" --no-gatekeeper-assess --timestamp`, { stdio: 'inherit' });

// Step 2: Явно перепідписати Electron Framework через Versions/A
console.log('  Re-signing Electron Framework…');
const FW = `${APP}/Contents/Frameworks`;
const frameworks = ['Electron Framework', 'Mantle', 'ReactiveObjC', 'Squirrel'];
for (const fw of frameworks) {
  const versionedBinary = `${FW}/${fw}.framework/Versions/A/${fw}`;
  try {
    sign(versionedBinary);
    console.log(`    ✓ ${fw}`);
  } catch(e) {
    console.log(`    ✗ ${fw}: ${e.message}`);
  }
  // Потім перепідписати весь framework bundle
  try {
    sign(`${FW}/${fw}.framework`);
  } catch(e) {}
}

// Step 3: Перепідписати main app останнім
console.log('  Re-signing main app…');
sign(APP);

console.log(`  ✓ Signed successfully (${arch})`);
