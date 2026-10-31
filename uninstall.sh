#!/usr/bin/env bash
# uninstall.sh — menghapus OpenCode V2 dari Termux (V1 tidak disentuh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || printf '.')"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh"
elif [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  # shellcheck source=../lib/common.sh
  . "$SCRIPT_DIR/../lib/common.sh"
else
  echo "lib/common.sh tidak ditemukan" >&2
  exit 1
fi

PURGE_DATA=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE_DATA=1; shift ;;
    -h|--help)
      echo "Pemakaian: uninstall.sh [--purge]"
      echo "  --purge  Hapus juga data/sesi/log OpenCode V2 di $V2HOME"
      exit 0
      ;;
    *) err "Opsi tidak dikenal: $1"; exit 1 ;;
  esac
done

step "Menghentikan background service"
daemon_stop || true
ok "Service dihentikan"

if [ -e "$LAUNCHER" ]; then
  rm -f "$LAUNCHER"
  ok "Launcher dihapus: $LAUNCHER"
fi

if [ -d "$ROOT" ]; then
  rm -rf "$ROOT"
  ok "Payload & skrip pendukung dihapus: $ROOT"
fi

if [ "$PURGE_DATA" -eq 1 ]; then
  if [ -d "$V2HOME" ]; then
    rm -rf "$V2HOME"
    ok "Data V2 dihapus: $V2HOME"
  fi
else
  dim "Data V2 tetap disimpan di $V2HOME (hapus dengan --purge)"
fi

PLUGIN="$HOME/.config/opencode/plugins/memory.js"
if [ -f "$PLUGIN.v1.bak" ]; then
  mv "$PLUGIN.v1.bak" "$PLUGIN"
  ok "Plugin memory_save dipulihkan ke versi V1"
fi

TITLE="$HOME/.config/opencode/plugins/session-title.js"
if [ -f "$TITLE" ]; then
  TITLE_BACKUP="$(ls -1t "$TITLE".bak-* 2>/dev/null | head -n 1 || true)"
  if [ -n "$TITLE_BACKUP" ]; then
    mv "$TITLE_BACKUP" "$TITLE"
    ok "Plugin judul sesi dipulihkan dari cadangan"
  else
    rm -f "$TITLE"
    ok "Plugin judul sesi dihapus"
  fi
fi

echo
ok "OpenCode V2 dihapus. OpenCode V1 (perintah 'opencode') tetap utuh."
