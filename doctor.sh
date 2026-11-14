#!/usr/bin/env bash
# doctor.sh — diagnose OpenCode V2 on Termux.
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
[ -n "${TERMUX_VERSION:-}" ] && check "Termux" ok "$TERMUX_VERSION" || check "Termux" warn "TERMUX_VERSION is empty"
ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] && check "Architecture" ok "aarch64 (arm64)" || check "Architecture" fail "$ARCH (aarch64 required)"
[ -x "$LOADER" ] && check "glibc loader" ok "$LOADER" || check "glibc loader" fail "missing — pkg install glibc-repo glibc termux-exec-glibc"
if [ -f "$GLIBC_LIB/libc.so.6" ]; then check "glibc runtime" ok "$GLIBC_LIB"; else check "glibc runtime" fail "libc.so.6 not found"; fi
if [ -e "$COMPAT_LIB/libc.so" ]; then
  check "Shim libc.so (loader)" ok "$COMPAT_LIB/libc.so"
else
  check "Shim libc.so (loader)" fail "missing — the V2 binary fails to start (invalid ELF header); run install.sh/upgrade.sh"
fi
if [ -f "$PREFIX/etc/tls/cert.pem" ]; then check "TLS certificate" ok "termux/etc/tls/cert.pem"; else check "TLS certificate" warn "cert.pem not found (HTTPS may fail)"; fi
if [ -L "$UPDATER_BIN" ] && [ "$(readlink "$UPDATER_BIN")" = "$LOADER" ]; then
  check "Built-in updater (TUI /update)" ok "$UPDATER_BIN -> loader"
elif [ -f "$UPDATER_BIN" ]; then
  check "Built-in updater (TUI /update)" warn "payload waiting to be adopted — restart opencode-v2"
elif command -v which >/dev/null 2>&1; then
  check "Built-in updater (TUI /update)" warn "link missing — run opencode-v2 upgrade (or install.sh)"
else
  check "Built-in updater (TUI /update)" warn "needs pkg install which + opencode-v2 upgrade"
fi

# --- bionic LD_PRELOAD regression -------------------------------------------
# The Termux interactive shell sets LD_PRELOAD to a bionic library. The glibc
# loader loads it too -> "version `LIBC' not found". The launcher must drop it.
BIONIC_PRELOAD="$PREFIX/lib/libtermux-exec-ld-preload.so"
if [ -f "$BIONIC_PRELOAD" ]; then
  if [ -x "$LAUNCHER" ]; then
    OUT="$(LD_PRELOAD="$BIONIC_PRELOAD" "$LAUNCHER" --version 2>&1 || true)"
    if printf '%s' "$OUT" | grep -q "not found"; then
      check "LD_PRELOAD bionic" fail "launcher does not drop LD_PRELOAD yet -> $OUT"
    elif printf '%s' "$OUT" | grep -qE "^opencode v"; then
      check "LD_PRELOAD bionic" ok "launcher drops LD_PRELOAD correctly"
    else
      check "LD_PRELOAD bionic" warn "unexpected output: $OUT"
    fi
  else
    check "LD_PRELOAD bionic" warn "no launcher — cannot test"
  fi
fi

# --- payload ----------------------------------------------------------------
printf '\n%s\n' "[Installation]"
if [ -x "$REAL" ]; then
  SIZE=$(du -h "$REAL" 2>/dev/null | cut -f1)
  check "Payload binary" ok "$REAL ($SIZE)"
else
  check "Payload binary" fail "missing at $REAL"
fi
VER="$(installed_version)"
[ "$VER" = "unknown" ] && check "Installed version" fail "unreadable" || check "Installed version" ok "$VER"
if [ -x "$LAUNCHER" ]; then check "Launcher" ok "$LAUNCHER"; else check "Launcher" fail "missing at $LAUNCHER"; fi
if [ -d "$V2HOME" ]; then
  DSIZE=$(du -sh "$V2HOME" 2>/dev/null | cut -f1)
  check "V2 data (separate from V1)" ok "$V2HOME ($DSIZE)"
else
  check "V2 data (separate from V1)" warn "$V2HOME does not exist yet"
fi
if [ -f "$HOME/.local/share/opencode/opencode.db" ]; then
  check "V1 DB (must not be touched)" ok "$HOME/.local/share/opencode/opencode.db"
else
  check "V1 DB" warn "not found"
fi

# --- daemon -----------------------------------------------------------------
printf '\n%s\n' "[Background service]"
if daemon_alive; then
  check "Service process" ok "pid $(daemon_pid)"
  check "Service URL" ok "$(daemon_url)"
  DVER="$(daemon_version)"
  if [ "$DVER" = "$VER" ]; then check "Service version" ok "$DVER"; else check "Service version" warn "$DVER (payload $VER) — run opencode-v2 service restart"; fi
else
  check "Service process" warn "not running — run opencode-v2 service start"
fi
[ -f "$SERVER_LOG" ] && check "Service log" ok "$SERVER_LOG ($(wc -l <"$SERVER_LOG" 2>/dev/null || printf 0) lines)" || check "Service log" warn "not created yet"

# --- configuration ----------------------------------------------------------
printf '\n%s\n' "[Configuration & plugins]"
CFG="$HOME/.config/opencode/opencode.jsonc"
[ -f "$CFG" ] && check "Global config" ok "$CFG" || check "Global config" warn "$CFG is missing"
for f in opencode.jsonc opencode.json; do
  [ -f "$HOME/.config/opencode/$f" ] && check "Config present ($f)" ok "ok" && break
done
PLUG="$HOME/.config/opencode/plugins/memory.js"
if [ -f "$PLUG" ]; then
  if grep -q 'setup' "$PLUG" && grep -q 'server' "$PLUG"; then
    check "Plugin memory_save" ok "dual V1+V2 at $PLUG"
  else
    check "Plugin memory_save" warn "$PLUG — unrecognised format"
  fi
else
  check "Plugin memory_save" warn "not installed"
fi
TITLE_PLUG="$HOME/.config/opencode/plugins/session-title.js"
if [ -f "$TITLE_PLUG" ]; then
  if grep -q 'setup' "$TITLE_PLUG" && grep -q 'server' "$TITLE_PLUG"; then
    check "Session title plugin" ok "no model calls, at $TITLE_PLUG"
  else
    check "Session title plugin" warn "$TITLE_PLUG — unrecognised format"
  fi
else
  check "Session title plugin" warn "not installed (optional)"
fi
SKILL_COUNT=0
if [ -d "$HOME/.agents/skills" ]; then
  SKILL_COUNT=$(find "$HOME/.agents/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
fi
check "Skills in ~/.agents/skills" ok "$SKILL_COUNT SKILL.md"

# --- official version -------------------------------------------------------
printf '\n%s\n' "[Official server]"
LATEST=""
LATEST="$(latest_version 2>/dev/null || true)"
if [ -n "$LATEST" ]; then
  check "Latest version" ok "$LATEST"
  if [ "$LATEST" != "$VER" ]; then
    check "Version status" warn "installed $VER, latest $LATEST (run opencode-v2 upgrade)"
  else
    check "Version status" ok "already up to date"
  fi
else
  check "Latest version" warn "cannot reach the version server"
fi

# --- resources --------------------------------------------------------------
printf '\n%s\n' "[Resource]"
FREE_KB="$(df -k "$PREFIX" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$FREE_KB" ]; then
  FREE_MB=$((FREE_KB / 1024))
  if [ "$FREE_MB" -lt 500 ]; then
    check "Disk space" warn "${FREE_MB} MB free (the V2 payload needs ~250 MB)"
  else
    check "Disk space" ok "${FREE_MB} MB free"
  fi
fi

echo
printf 'Summary: %s✔%s%s  %s!%s%s  %s✖%s%s\n' "$C_GRN" "$C_OFF" "$PASS" "$C_YLW" "$C_OFF" "$WARN" "$C_RED" "$C_OFF" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
