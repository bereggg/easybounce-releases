#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#   EasyBounce — One-command Release Publisher
#
#   Usage:
#     bash publish.sh             ← auto-bump patch (1.0.0 → 1.0.1)
#     bash publish.sh 1.1.0       ← specific version
#     bash publish.sh --dry-run   ← build only, no GitHub publish
#
#   Builds two DMGs:
#     EasyBounce-arm64.dmg  ← Apple Silicon (M1/M2/M3)
#     EasyBounce-x64.dmg    ← Intel Mac
# ══════════════════════════════════════════════════════════════════
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

GITHUB_OWNER="bereggg"
GITHUB_REPO="easybounce-releases"

DRY_RUN=false
[ "$1" = "--dry-run" ] && DRY_RUN=true && shift

# ── GitHub Token ──────────────────────────────────────────────────
GH_TOKEN="${GH_TOKEN:-}"
if [ -z "$GH_TOKEN" ] && [ "$DRY_RUN" = false ]; then
  TOKEN_FILE="$HOME/.easybounce_gh_token"
  if [ -f "$TOKEN_FILE" ]; then
    GH_TOKEN=$(cat "$TOKEN_FILE")
    echo "  ✓ GitHub token: $TOKEN_FILE"
  else
    echo ""
    echo "  ┌───────────────────────────────────────────────────────┐"
    echo "  │  Потрібен GitHub токен (одноразово)                   │"
    echo "  │  Створи: github.com/settings/tokens/new              │"
    echo "  │  Дозвіл: repo (full control of repositories)         │"
    echo "  └───────────────────────────────────────────────────────┘"
    echo ""
    read -p "  Вставте токен: " GH_TOKEN
    echo "$GH_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "  ✓ Збережено в $TOKEN_FILE (більше не питатиме)"
  fi
fi

# ── Версія ────────────────────────────────────────────────────────
CURRENT=$(node -p "require('./package.json').version")
if [ -n "$1" ]; then
  NEW_VERSION="$1"
else
  MAJOR=$(echo "$CURRENT" | cut -d. -f1)
  MINOR=$(echo "$CURRENT" | cut -d. -f2)
  PATCH=$(echo "$CURRENT" | cut -d. -f3)
  NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
fi

TAG="v${NEW_VERSION}"

# Versioned DMG names
DMG_ARM64_VERSIONED="dist/EasyBounce-${NEW_VERSION}-arm64.dmg"
DMG_X64_VERSIONED="dist/EasyBounce-${NEW_VERSION}-x64.dmg"
# Stable DMG names (постійні лінки — ніколи не змінюються)
DMG_ARM64_STABLE="dist/EasyBounce-arm64.dmg"
DMG_X64_STABLE="dist/EasyBounce-x64.dmg"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   EasyBounce Publisher — Dual Arch Build                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Поточна:  v${CURRENT}"
echo "  Реліз:    ${TAG}"
echo "  Збірки:   arm64 (Apple Silicon) + x64 (Intel)"
[ "$DRY_RUN" = true ] && echo "  Режим:    DRY RUN (без публікації)"
echo ""
read -p "  Продовжити? [y/n]: " CONFIRM
[ "$CONFIRM" != "y" ] && echo "  Скасовано." && exit 0

# ── 1. Bump version ───────────────────────────────────────────────
echo ""
echo "▶  Оновлення версії до ${NEW_VERSION}..."
node -e "
  const fs = require('fs');
  const p = JSON.parse(fs.readFileSync('./package.json', 'utf8'));
  p.version = '${NEW_VERSION}';
  fs.writeFileSync('./package.json', JSON.stringify(p, null, 4) + '\n');
"
echo "   ✓ package.json → v${NEW_VERSION}"

# ── 2. Git commit версії ──────────────────────────────────────────
echo ""
echo "▶  Збереження в git..."
git add -A 2>/dev/null || true
git commit -m "release: ${TAG}" 2>/dev/null || echo "   ℹ  git: нічого нового для коміту"
git push 2>/dev/null || echo "   ⚠  git push не вдався (продовжуємо)"
echo "   ✓ git: release: ${TAG}"

# ── 3. Компіляція Swift ───────────────────────────────────────────
echo ""
echo "▶  Компіляція Swift бінарників..."
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

swiftc LogicBridge.swift -o LogicBridge_arm64 -target arm64-apple-macos10.15 2>&1 | grep -v warning || true
swiftc LogicBridge.swift -o LogicBridge_x86  -target x86_64-apple-macos10.15 2>&1 | grep -v warning || true
lipo -create -output LogicBridge LogicBridge_arm64 LogicBridge_x86
rm -f LogicBridge_arm64 LogicBridge_x86
echo "   ✓ LogicBridge (universal arm64+x86_64)"

swiftc CloseLogicWindows.swift -o CloseLogicWindows -target arm64-apple-macosx12.0 \
  -framework ApplicationServices -framework AppKit 2>&1 | grep -v warning || true
echo "   ✓ CloseLogicWindows"

# ── 4. Build arm64 DMG ────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "▶  [1/2] Збірка arm64 (Apple Silicon M1/M2/M3)"
echo "   Підписання + нотаризація ~10хв..."
echo "════════════════════════════════════════════════"
bash build_dmg.sh arm64

if [ ! -f "$DMG_ARM64_VERSIONED" ]; then
  echo "   ❌ Збірка провалилась: $DMG_ARM64_VERSIONED не знайдено"
  exit 1
fi
cp "$DMG_ARM64_VERSIONED" "$DMG_ARM64_STABLE"
echo "   ✓ arm64: $(du -sh "$DMG_ARM64_VERSIONED" | cut -f1)"

# ── 5. Build x64 DMG ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "▶  [2/2] Збірка x64 (Intel Mac)"
echo "   Підписання + нотаризація ~10хв..."
echo "════════════════════════════════════════════════"
bash build_dmg.sh x64

if [ ! -f "$DMG_X64_VERSIONED" ]; then
  echo "   ❌ Збірка провалилась: $DMG_X64_VERSIONED не знайдено"
  exit 1
fi
cp "$DMG_X64_VERSIONED" "$DMG_X64_STABLE"
echo "   ✓ x64:   $(du -sh "$DMG_X64_VERSIONED" | cut -f1)"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "  ── DRY RUN ЗАВЕРШЕНО ──"
  echo "  $DMG_ARM64_VERSIONED"
  echo "  $DMG_X64_VERSIONED"
  exit 0
fi

# ── 6. Create GitHub Release ──────────────────────────────────────
echo ""
echo "▶  Створення GitHub реліза ${TAG}..."

RELEASE_BODY="## EasyBounce ${TAG}\n\n**Встановлення:**\n- Apple Silicon (M1/M2/M3): завантажте \`EasyBounce-arm64.dmg\`\n- Intel Mac: завантажте \`EasyBounce-x64.dmg\`\n\nВідкрийте DMG і перетягніть у /Applications.\n\n**Вимоги:** macOS 11+ · Logic Pro"

RELEASE_JSON=$(curl -sf -X POST \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases" \
  --data-binary "{\"tag_name\":\"${TAG}\",\"name\":\"EasyBounce ${TAG}\",\"body\":\"${RELEASE_BODY}\",\"draft\":false,\"prerelease\":false}" 2>&1)

RELEASE_ID=$(echo "$RELEASE_JSON" | /opt/homebrew/bin/node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).id||'')}catch(e){}})" 2>/dev/null || true)
UPLOAD_URL=$(echo "$RELEASE_JSON" | /opt/homebrew/bin/node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const u=JSON.parse(d).upload_url||'';console.log(u.split('{')[0])}catch(e){}})" 2>/dev/null || true)

if [ -z "$RELEASE_ID" ]; then
  echo "   ❌ Помилка створення реліза:"
  echo "$RELEASE_JSON"
  exit 1
fi
echo "   ✓ Реліз створено (ID: ${RELEASE_ID})"

# ── 7. Upload ─────────────────────────────────────────────────────
echo ""
echo "▶  Завантаження файлів на GitHub..."

_upload() {
  local FILE="$1" NAME="$2"
  local SIZE=$(du -sh "$FILE" | cut -f1)
  echo "   $NAME ($SIZE)..."
  RES=$(curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    -H "Accept: application/vnd.github.v3+json" \
    "${UPLOAD_URL}?name=${NAME}" \
    --data-binary @"${FILE}" 2>&1)
  if echo "$RES" | /opt/homebrew/bin/node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.exit(JSON.parse(d).state==='uploaded'?0:1)}catch(e){process.exit(1)}})" 2>/dev/null; then
    echo "   ✓ $NAME"
  else
    echo "   ⚠  $NAME — перевір на GitHub"
  fi
}

# Stable names (постійні лінки для сайту і авто-оновлення)
_upload "$DMG_ARM64_STABLE"    "EasyBounce-arm64.dmg"
_upload "$DMG_X64_STABLE"      "EasyBounce-x64.dmg"
# Versioned copies (архів)
_upload "$DMG_ARM64_VERSIONED" "EasyBounce-${NEW_VERSION}-arm64.dmg"
_upload "$DMG_X64_VERSIONED"   "EasyBounce-${NEW_VERSION}-x64.dmg"

# ── 8. Done ───────────────────────────────────────────────────────
URL_ARM64="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest/download/EasyBounce-arm64.dmg"
URL_X64="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest/download/EasyBounce-x64.dmg"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   ✅  ОПУБЛІКОВАНО                                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Версія:   ${TAG}"
echo "  Реліз:    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  ЛІНКИ ДЛЯ САЙТУ (постійні, ніколи не змінюються):     │"
echo "  │                                                          │"
echo "  │  Apple Silicon (M1/M2/M3):                              │"
echo "  │  ${URL_ARM64}"
echo "  │                                                          │"
echo "  │  Intel Mac:                                              │"
echo "  │  ${URL_X64}"
echo "  │                                                          │"
echo "  │  ✓ Авто-оновлення в додатку скачує правильний DMG      │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
