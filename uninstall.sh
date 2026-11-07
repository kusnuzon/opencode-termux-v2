#!/usr/bin/env bash
# uninstall.sh — remove OpenCode V2 from Termux (V1 is left untouched).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || printf '.')"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh"
elif [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  # shellcheck source=../lib/common.sh
  . "$SCRIPT_DIR/../lib/common.sh"
else
  echo "lib/common.sh not found" >&2
  exit 1
fi

PURGE_DATA=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE_DATA=1; shift ;;
    -h|--help)
      echo "Usage: uninstall.sh [--purge]"
      echo "  --purge  Also delete OpenCode V2 data/sessions/logs in $V2HOME"
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

step "Stopping the background service"
daemon_stop || true
ok "Service stopped"

if [ -e "$LAUNCHER" ]; then
  rm -f "$LAUNCHER"
  ok "Launcher removed: $LAUNCHER"
fi

if [ -d "$ROOT" ]; then
  rm -rf "$ROOT"
  ok "Payload and helper scripts removed: $ROOT"
fi

if [ "$PURGE_DATA" -eq 1 ]; then
  if [ -d "$V2HOME" ]; then
    rm -rf "$V2HOME"
    ok "V2 data removed: $V2HOME"
  fi
else
  dim "V2 data kept in $V2HOME (delete it with --purge)"
fi

PLUGIN="$HOME/.config/opencode/plugins/memory.js"
if [ -f "$PLUGIN.v1.bak" ]; then
  mv "$PLUGIN.v1.bak" "$PLUGIN"
  ok "memory_save plugin restored to the V1 version"
fi

TITLE="$HOME/.config/opencode/plugins/session-title.js"
if [ -f "$TITLE" ]; then
  TITLE_BACKUP="$(ls -1t "$TITLE".bak-* 2>/dev/null | head -n 1 || true)"
  if [ -n "$TITLE_BACKUP" ]; then
    mv "$TITLE_BACKUP" "$TITLE"
    ok "Session title plugin restored from backup"
  else
    rm -f "$TITLE"
    ok "Session title plugin removed"
  fi
fi

echo
ok "OpenCode V2 removed. OpenCode V1 (the 'opencode' command) is still intact."
