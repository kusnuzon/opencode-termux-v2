#!/usr/bin/env bash
# upgrade.sh — memperbarui OpenCode V2 di Termux.
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

CHECK_ONLY=0
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --version) TARGET="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Pemakaian: upgrade.sh [--check] [--version <ver>]"
      exit 0
      ;;
    *) err "Opsi tidak dikenal: $1"; exit 1 ;;
  esac
done

require_termux
ensure_tools

CURRENT="$(installed_version)"
info "Versi terpasang : $CURRENT"

if [ -z "$TARGET" ]; then
  step "Mencari versi terbaru"
  META="$(latest_metadata)" || die "Gagal menghubungi server versi"
  TARGET="$(json_field version "$META")"
  [ -n "$TARGET" ] || die "Tidak bisa membaca versi terbaru"
fi
info "Versi terbaru  : $TARGET"
echo

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$CURRENT" = "$TARGET" ]; then
    ok "Sudah versi terbaru ($TARGET)"
  else
    warn "Ada versi baru: $TARGET — jalankan upgrade.sh tanpa --check"
  fi
  exit 0
fi

if [ "$CURRENT" = "$TARGET" ] && [ -x "$REAL" ]; then
  ok "Sudah versi terbaru ($TARGET), tidak ada perubahan"
  exit 0
fi

ensure_glibc
ensure_compat_libs || die "Gagal membuat shim pustaka glibc di $COMPAT_LIB"

BACKUP="$ROOT/opencode.real.bak"
if [ -x "$REAL" ]; then
  cp "$REAL" "$BACKUP"
  dim "Binary lama dicadangkan: $BACKUP"
fi

step "Mengunduh versi $TARGET"
if ! download_payload "$TARGET" "$REAL.new"; then
  err "Unduhan gagal"
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$REAL"
    warn "Binary lama dipulihkan"
  fi
  exit 1
fi

mv "$REAL.new" "$REAL"
chmod 755 "$REAL"
printf '%s\n' "$TARGET" >"$VERSION_FILE"
ok "Binary diperbarui ke versi $TARGET"

step "Menjalankan ulang background service"
daemon_stop || true
if ! daemon_start; then
  err "Service gagal start setelah upgrade"
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$REAL"
    printf '%s\n' "$CURRENT" >"$VERSION_FILE"
    daemon_stop || true
    daemon_start || true
    warn "Rollback ke versi $CURRENT dilakukan"
  fi
  exit 1
fi

step "Verifikasi"
OUT="$("$LAUNCHER" --version 2>&1 || true)"
printf '%s\n' "$OUT" | sed 's/^/    /'
case "$OUT" in
  *"$TARGET"*) ok "Upgrade selesai: $TARGET" ;;
  *) warn "Verifikasi versi tidak sesuai, cek manual" ;;
esac
write_state
