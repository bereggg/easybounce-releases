#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#   EasyBounce — Update + Git Save + Publish
#   Usage: bash release.sh           ← auto-bump patch
#          bash release.sh 1.2.0     ← specific version
#          bash release.sh --dry-run ← build only, no GitHub
# ══════════════════════════════════════════════════════════════════
set -e
cd "$(dirname "$0")"

# ── 1. Update app (compile Swift + inject into .app) ─────────────
echo ""
echo "▶  Step 1: Update app..."
bash update_app.sh

# ── 2. Git commit ─────────────────────────────────────────────────
echo ""
echo "▶  Step 2: Git save..."
git add -A
COMMIT_MSG="release: $(date '+%Y-%m-%d %H:%M')"
git commit -m "$COMMIT_MSG" || echo "   (nothing new to commit)"
echo "   ✓ Git saved: $COMMIT_MSG"

# ── 3. Publish ────────────────────────────────────────────────────
echo ""
echo "▶  Step 3: Publish..."
bash publish.sh "$@"
