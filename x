#!/bin/bash
# ── EasyBounce CLI trigger ────────────────────────────────────────────────────
# Type `x` in terminal to instantly start a bounce from EasyBounce.
# The app must be running. If not — it opens automatically.
# Usage: x           → trigger bounce
#        x status    → check if app is running

PORT=7432
CMD="${1:-bounce}"

ping_app() {
  curl -sf --max-time 1 "http://127.0.0.1:${PORT}/ping" > /dev/null 2>&1
}

open_app() {
  echo "⏳ EasyBounce not running — opening..."
  open -a EasyBounce
  # Wait up to 8s for server to start
  for i in $(seq 1 16); do
    sleep 0.5
    ping_app && return 0
  done
  echo "❌ EasyBounce did not start in time." && exit 1
}

case "$CMD" in
  status)
    if ping_app; then
      echo "✅ EasyBounce is running (port ${PORT})"
    else
      echo "⚫ EasyBounce is not running"
    fi
    ;;
  bounce|"")
    ping_app || open_app
    RESULT=$(curl -sf --max-time 3 "http://127.0.0.1:${PORT}/bounce")
    if [ $? -eq 0 ]; then
      echo "⚡ Bounce triggered — EasyBounce is running"
    else
      echo "❌ Failed to trigger bounce"
      exit 1
    fi
    ;;
  *)
    echo "Usage: x [bounce|status]"
    ;;
esac
