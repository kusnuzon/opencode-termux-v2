#!/usr/bin/env bash
# doctor.sh — diagnosis OpenCode V2 di Termux.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || printf '.')"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh"
elif [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  # shellcheck source=../lib/common.sh
  . "$SCRIPT_DIR/../lib/common.sh"
fi

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1" status="$2" detail="${3:-}"
  case "$status" in
    ok)   PASS=$((PASS+1)); printf '  %s✔%s %-34s %s\n' "$C_GRN" "$C_OFF" "$label" "$detail" ;;
    warn) WARN=$((WARN+1)); printf '  %s!%s %-34s %s\n' "$C_YLW" "$C_OFF" "$label" "$detail" ;;
    *)    FAIL=$((FAIL+1)); printf '  %s✖%s %-34s %s\n' "$C_RED" "$C_OFF" "$label" "$detail" ;;
  esac
}

printf '%s\n' "== OpenCode V2 doctor =="
echo

# --- environment ------------------------------------------------------------
printf '%s\n' "[Environment]"
[ -n "${TERMUX_VERSION:-}" ] && check "Termux" ok "$TERMUX_VERSION" || check "Termux" warn "TERMUX_VERSION kosong"
ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] && check "Arsitektur" ok "aarch64 (arm64)" || check "Arsitektur" fail "$ARCH (butuh aarch64)"
[ -x "$LOADER" ] && check "Loader glibc" ok "$LOADER" || check "Loader glibc" fail "hilang — pkg install glibc-repo glibc termux-exec-glibc"
if [ -f "$GLIBC_LIB/libc.so.6" ]; then check "glibc runtime" ok "$GLIBC_LIB"; else check "glibc runtime" fail "libc.so.6 tidak ditemukan"; fi
if [ -e "$COMPAT_LIB/libc.so" ]; then
  check "Shim libc.so (loader)" ok "$COMPAT_LIB/libc.so"
else
  check "Shim libc.so (loader)" fail "hilang — binary V2 gagal start (invalid ELF header); jalankan install.sh/upgrade.sh"
fi
if [ -f "$PREFIX/etc/tls/cert.pem" ]; then check "Sertifikat TLS" ok "termux/etc/tls/cert.pem"; else check "Sertifikat TLS" warn "cert.pem tidak ditemukan (HTTPS bisa gagal)"; fi

# --- regresi LD_PRELOAD bionic ------------------------------------------------
# Shell interaktif Termux menyetel LD_PRELOAD ke pustaka bionic. Loader glibc
# ikut memuatnya -> "version `LIBC' not found". Launcher harus membuangnya.
BIONIC_PRELOAD="$PREFIX/lib/libtermux-exec-ld-preload.so"
if [ -f "$BIONIC_PRELOAD" ]; then
  if [ -x "$LAUNCHER" ]; then
    OUT="$(LD_PRELOAD="$BIONIC_PRELOAD" "$LAUNCHER" --version 2>&1 || true)"
    if printf '%s' "$OUT" | grep -q "not found"; then
      check "LD_PRELOAD bionic" fail "launcher belum membuang LD_PRELOAD -> $OUT"
    elif printf '%s' "$OUT" | grep -qE "^opencode v"; then
      check "LD_PRELOAD bionic" ok "launcher membuang LD_PRELOAD dengan benar"
    else
      check "LD_PRELOAD bionic" warn "output tak terduga: $OUT"
    fi
  else
    check "LD_PRELOAD bionic" warn "launcher tidak ada — tidak bisa diuji"
  fi
fi

# --- payload ----------------------------------------------------------------
printf '\n%s\n' "[Pemasangan]"
if [ -x "$REAL" ]; then
  SIZE=$(du -h "$REAL" 2>/dev/null | cut -f1)
  check "Payload binary" ok "$REAL ($SIZE)"
else
  check "Payload binary" fail "tidak ada di $REAL"
fi
VER="$(installed_version)"
[ "$VER" = "unknown" ] && check "Versi terpasang" fail "tidak terbaca" || check "Versi terpasang" ok "$VER"
if [ -x "$LAUNCHER" ]; then check "Launcher" ok "$LAUNCHER"; else check "Launcher" fail "tidak ada di $LAUNCHER"; fi
if [ -d "$V2HOME" ]; then
  DSIZE=$(du -sh "$V2HOME" 2>/dev/null | cut -f1)
  check "Data V2 (terpisah dari V1)" ok "$V2HOME ($DSIZE)"
else
  check "Data V2 (terpisah dari V1)" warn "$V2HOME belum ada"
fi
if [ -f "$HOME/.local/share/opencode/opencode.db" ]; then
  check "DB V1 (tidak boleh disentuh)" ok "$HOME/.local/share/opencode/opencode.db"
else
  check "DB V1" warn "tidak ditemukan"
fi

# --- daemon -----------------------------------------------------------------
printf '\n%s\n' "[Background service]"
if daemon_alive; then
  check "Proses service" ok "pid $(daemon_pid)"
  check "URL service" ok "$(daemon_url)"
  DVER="$(daemon_version)"
  if [ "$DVER" = "$VER" ]; then check "Versi service" ok "$DVER"; else check "Versi service" warn "$DVER (payload $VER) — jalankan opencode-v2 service restart"; fi
else
  check "Proses service" warn "tidak berjalan — jalankan opencode-v2 service start"
fi
[ -f "$SERVER_LOG" ] && check "Log service" ok "$SERVER_LOG ($(wc -l <"$SERVER_LOG" 2>/dev/null || printf 0) baris)" || check "Log service" warn "belum ada"

# --- konfigurasi ------------------------------------------------------------
printf '\n%s\n' "[Konfigurasi & plugin]"
CFG="$HOME/.config/opencode/opencode.jsonc"
[ -f "$CFG" ] && check "Config global" ok "$CFG" || check "Config global" warn "$CFG tidak ada"
for f in opencode.jsonc opencode.json; do
  [ -f "$HOME/.config/opencode/$f" ] && check "Config terbuka ($f)" ok "ok" && break
done
PLUG="$HOME/.config/opencode/plugins/memory.js"
if [ -f "$PLUG" ]; then
  if grep -q 'setup' "$PLUG" && grep -q 'server' "$PLUG"; then
    check "Plugin memory_save" ok "dual V1+V2 di $PLUG"
  else
    check "Plugin memory_save" warn "$PLUG — format tidak dikenali"
  fi
else
  check "Plugin memory_save" warn "belum terpasang"
fi
TITLE_PLUG="$HOME/.config/opencode/plugins/session-title.js"
if [ -f "$TITLE_PLUG" ]; then
  if grep -q 'setup' "$TITLE_PLUG" && grep -q 'server' "$TITLE_PLUG"; then
    check "Plugin judul sesi" ok "tanpa panggilan model di $TITLE_PLUG"
  else
    check "Plugin judul sesi" warn "$TITLE_PLUG — format tidak dikenali"
  fi
else
  check "Plugin judul sesi" warn "belum terpasang (opsional)"
fi
SKILL_COUNT=0
if [ -d "$HOME/.agents/skills" ]; then
  SKILL_COUNT=$(find "$HOME/.agents/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
fi
check "Skill di ~/.agents/skills" ok "$SKILL_COUNT SKILL.md"

# --- versi resmi ------------------------------------------------------------
printf '\n%s\n' "[Server resmi]"
LATEST=""
LATEST="$(latest_version 2>/dev/null || true)"
if [ -n "$LATEST" ]; then
  check "Versi terbaru" ok "$LATEST"
  if [ "$LATEST" != "$VER" ]; then
    check "Status versi" warn "terpasang $VER, terbaru $LATEST (jalankan opencode-v2 upgrade)"
  else
    check "Status versi" ok "sudah terbaru"
  fi
else
  check "Versi terbaru" warn "tidak bisa menghubungi server versi"
fi

# --- resource ---------------------------------------------------------------
printf '\n%s\n' "[Resource]"
FREE_KB="$(df -k "$PREFIX" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$FREE_KB" ]; then
  FREE_MB=$((FREE_KB / 1024))
  if [ "$FREE_MB" -lt 500 ]; then
    check "Ruang disk" warn "${FREE_MB} MB tersisa (payload V2 butuh ~250 MB)"
  else
    check "Ruang disk" ok "${FREE_MB} MB tersisa"
  fi
fi

echo
printf 'Ringkasan: %s✔%s%s  %s!%s%s  %s✖%s%s\n' "$C_GRN" "$C_OFF" "$PASS" "$C_YLW" "$C_OFF" "$WARN" "$C_RED" "$C_OFF" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
