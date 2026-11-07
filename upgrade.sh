#!/usr/bin/env bash
# upgrade.sh — update OpenCode V2 on Termux.
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

CHECK_ONLY=0
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --version) TARGET="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: upgrade.sh [--check] [--version <ver>]"
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

require_termux
ensure_tools

CURRENT="$(installed_version)"
info "Installed version : $CURRENT"

if [ -z "$TARGET" ]; then
  step "Looking up the latest version"
  META="$(latest_metadata)" || die "Failed to reach the version server"
  TARGET="$(json_field version "$META")"
  [ -n "$TARGET" ] || die "Cannot read the latest version"
fi
info "Latest version    : $TARGET"
echo

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$CURRENT" = "$TARGET" ]; then
    ok "Already the latest version ($TARGET)"
  else
    warn "A new version is available: $TARGET — run upgrade.sh without --check"
  fi
  exit 0
fi

if [ "$CURRENT" = "$TARGET" ] && [ -x "$REAL" ]; then
  ok "Already the latest version ($TARGET), nothing to do"
  exit 0
fi

ensure_glibc
ensure_compat_libs || die "Failed to create the glibc library shim in $COMPAT_LIB"

BACKUP="$ROOT/opencode.real.bak"
if [ -x "$REAL" ]; then
  cp "$REAL" "$BACKUP"
  dim "Old binary backed up: $BACKUP"
fi

step "Downloading version $TARGET"
if ! download_payload "$TARGET" "$REAL.new"; then
  err "Download failed"
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$REAL"
    warn "Old binary restored"
  fi
  exit 1
fi

mv "$REAL.new" "$REAL"
chmod 755 "$REAL"
printf '%s\n' "$TARGET" >"$VERSION_FILE"
ok "Binary updated to version $TARGET"

step "Restarting the background service"
daemon_stop || true
if ! daemon_start; then
  err "Service failed to start after the upgrade"
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$REAL"
    printf '%s\n' "$CURRENT" >"$VERSION_FILE"
    daemon_stop || true
    daemon_start || true
    warn "Rolled back to version $CURRENT"
  fi
  exit 1
fi

step "Verification"
OUT="$("$LAUNCHER" --version 2>&1 || true)"
printf '%s\n' "$OUT" | sed 's/^/    /'
case "$OUT" in
  *"$TARGET"*) ok "Upgrade finished: $TARGET" ;;
  *) warn "Version verification did not match, please check manually" ;;
esac
write_state
