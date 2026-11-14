#!/usr/bin/env bash
# install.sh — install OpenCode V2 on Termux (Android arm64).
#
# Usage (one command):
#   curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/install.sh | bash
#
# From a repo clone:
#   git clone https://github.com/kusnuzon/opencode-termux-v2 && cd opencode-termux-v2 && ./install.sh
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || printf '.')"

# These constants are used before common.sh is loaded (a piped script has no
# files next to it), so they are redefined here.
REPO_SLUG="kusnuzon/opencode-termux-v2"
RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}"
DEFAULT_REF="main"

# fetch_remote <repo-path> <destination-file> [ref]
# Fetches a file from GitHub. It tries the API first (raw header) because
# raw.githubusercontent.com often serves a stale version from network proxy
# caches; the API is always fresh. If the API fails (rate limit), use raw.
fetch_remote() {
  local path="$1" dest="$2" ref="${3:-$DEFAULT_REF}"
  if curl -fsSL --max-time 60 \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${REPO_SLUG}/contents/${path}?ref=${ref}" \
    -o "$dest" 2>/dev/null; then
    return 0
  fi
  if curl -fsSL --max-time 60 -o "$dest" "${RAW_BASE}/${ref}/${path}" 2>/dev/null; then
    return 0
  fi
  # fallback: wget (no header) or python (with the raw header)
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=60 -O "$dest" "${RAW_BASE}/${ref}/${path}" >/dev/null 2>&1 && return 0
  fi
  if command -v python >/dev/null 2>&1; then
    python - "$dest" "https://api.github.com/repos/${REPO_SLUG}/contents/${path}?ref=${ref}" <<'PY' >/dev/null 2>&1
import sys, urllib.request
dest, url = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"User-Agent": "opencode-v2",
                                           "Accept": "application/vnd.github.raw"})
open(dest, "wb").write(urllib.request.urlopen(req, timeout=60).read())
PY
    [ -s "$dest" ] && return 0
  fi
  return 1
}

# Bootstrap networking before downloading anything. On Termux the glibc
# packages can break curl ("cannot locate symbol
# SSL_set_quic_tls_early_data_enabled"), which makes the installer stop with a
# misleading "download failed" message.
net_bootstrap() {
  curl -fsS --max-time 10 -o /dev/null https://github.com >/dev/null 2>&1 && return 0
  echo "! curl is unhealthy — reinstalling curl/libcurl/openssl" >&2
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold curl libcurl openssl ca-certificates >/dev/null 2>&1 || true
  command -v pkg >/dev/null 2>&1 &&
    pkg install -y curl libcurl openssl ca-certificates >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  curl -fsS --max-time 10 -o /dev/null https://github.com >/dev/null 2>&1
}

net_bootstrap || true

# Load common.sh from a local clone; if running through a pipe, download it.
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh"
else
  REF="${OPENCODE_V2_REF:-$DEFAULT_REF}"
  TMPD="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/opencode-v2-inst.XXXXXX")"
  trap 'rm -rf "$TMPD"' EXIT
  mkdir -p "$TMPD/lib"
  fetch_remote "lib/common.sh" "$TMPD/lib/common.sh" "$REF" \
    || { echo "Failed to download lib/common.sh from repo $REPO_SLUG ($REF)" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "$TMPD/lib/common.sh"
  SCRIPT_DIR="$TMPD"
fi

VERSION_ARG=""
DRY_RUN=0
NO_PLUGIN=0
NO_EXTRA=0
export NO_EXTRA
CHECK_ONLY=0
UPGRADE=0
WITH_MEMORY=1
REF_PIN="${OPENCODE_V2_REF:-$DEFAULT_REF}"

usage() {
  cat <<'EOF'
Install OpenCode V2 on Termux (Android arm64).

Usage:
  install.sh [options]

Options:
  --version <ver>   Install a specific version (default: latest)
  --upgrade         Same as upgrade.sh (keeps the configuration)
  --check           Only report status, change nothing
  --dry-run         Show the plan without installing
  --no-plugin       Do not install the bundled plugins (memory_save + session titles)
  --no-extra        Do not install the large optional packages (tesseract, chromium)
  --no-memory       Do not install the memory/AGENTS/RECENT templates + ~/.bashrc hook
  --with-memory     (default) Install private memory: MEMORY.md, AGENTS.md,
                    RECENT.md (automatic session summaries) + ~/.bashrc hook
  --ref <ref>       Fetch the support scripts from another branch/tag
  -h, --help        Show this help

Example:
  curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/install.sh | bash
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION_ARG="${2:-}"; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-plugin) NO_PLUGIN=1; shift ;;
    --no-extra) NO_EXTRA=1; export NO_EXTRA; shift ;;
    --no-memory) WITH_MEMORY=0; shift ;;
    --with-memory) WITH_MEMORY=1; shift ;;
    --ref) REF_PIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

printf '%s\n' "╭──────────────────────────────────────────────╮"
printf '%s\n' "│  OpenCode V2 installer — Termux / Android       │"
printf '%s\n' "╰──────────────────────────────────────────────╯"

require_termux
ensure_tools

CURRENT="$(installed_version)"
info "PREFIX                   : $PREFIX"
info "Installed version        : ${CURRENT}"
REPO_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || printf 'n/a')"
info "Repository version       : $REPO_VERSION"
echo

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ -f "$SCRIPT_DIR/doctor.sh" ]; then
    bash "$SCRIPT_DIR/doctor.sh" || warn "doctor found problems — see the '✖' lines above"
  else
    warn "doctor.sh is not present here — skipping the detailed check"
  fi
  exit 0
fi

# --- determine the target version -------------------------------------------
TARGET="$VERSION_ARG"
if [ -z "$TARGET" ]; then
  step "Fetching the latest version from the official server"
  META="$(latest_metadata)" || die "Failed to reach the OpenCode version server"
  TARGET="$(json_field version "$META")"
  [ -n "$TARGET" ] || die "Cannot read the latest version from the official metadata"
fi
info "Target version : $TARGET"
echo

if [ "$DRY_RUN" -eq 1 ]; then
  step "Plan (dry-run):"
  info "  1. Ensure the Termux glibc runtime (glibc-repo, glibc, termux-exec-glibc)"
  info "  2. Prepare the library shim (libc.so -> libc.so.6) for the glibc loader"
  info "  3. Download the official @opencode/cli-linux-arm64 $TARGET payload (~100 MB)"
  info "  4. Verify the sha512 checksum from the npm registry"
  info "  5. Install the payload to $ROOT/opencode.real"
  info "  6. Install the launcher to $LAUNCHER (command: opencode-v2)"
  info "  7. Enable the built-in updater (TUI /update) via $UPDATER_BIN"
  info "  8. Start the background service + smoke test"
  [ "$NO_PLUGIN" -eq 0 ] && info "  9. Install the bundled plugins (memory_save + session titles) into ~/.config/opencode/plugins/"
  [ "$WITH_MEMORY" -eq 1 ] && info " 10. Install private memory (MEMORY.md, AGENTS.md, RECENT.md) + ~/.bashrc hook"
  exit 0
fi

if [ -n "$CURRENT" ] && [ "$CURRENT" != "unknown" ] && [ "$CURRENT" = "$TARGET" ] && [ -x "$REAL" ] && [ "$UPGRADE" -eq 0 ]; then
  ok "Version $TARGET is already installed"
else
  # --- glibc runtime --------------------------------------------------------
  ensure_glibc

  # --- download the payload -------------------------------------------------
  BACKUP=""
  if [ -x "$REAL" ]; then
    BACKUP="$ROOT/opencode.real.bak"
    cp "$REAL" "$BACKUP"
  fi
  download_payload "$TARGET" "$REAL.new" || die "Payload installation failed"
  mv "$REAL.new" "$REAL"
  printf '%s\n' "$TARGET" >"$VERSION_FILE"
  ok "Payload installed: $REAL (version $TARGET)"
fi

# --- launcher ---------------------------------------------------------------
mkdir -p "$PREFIX/bin" "$ROOT"
LAUNCHER_SRC="$SCRIPT_DIR/opencode-v2-launcher"
if [ ! -f "$LAUNCHER_SRC" ]; then
  fetch_remote "opencode-v2-launcher" "$LAUNCHER_SRC" "$REF_PIN" \
    || die "Failed to download opencode-v2-launcher"
fi
sed "s|@PREFIX@|$PREFIX|g" "$LAUNCHER_SRC" >"$LAUNCHER.tmp"
mv "$LAUNCHER.tmp" "$LAUNCHER"
chmod 755 "$LAUNCHER"
ok "Launcher installed: $LAUNCHER (command: opencode-v2)"

# --- built-in updater -------------------------------------------------------
# Makes the TUI /update command (and `opencode update`) work: the updater only
# recognises the "curl" install method when ~/.opencode/bin/opencode resolves to
# the running executable, which on Termux is the glibc loader.
ensure_updater_link
ok "Built-in updater links to the glibc loader: $UPDATER_BIN"

# --- support scripts into $ROOT --------------------------------------------
mkdir -p "$ROOT/lib"
for aux in lib/common.sh doctor.sh upgrade.sh uninstall.sh; do
  src="$SCRIPT_DIR/$aux"
  dst="$ROOT/${aux#lib/}"
  [ "$aux" = "lib/common.sh" ] && dst="$ROOT/lib/common.sh"
  if [ ! -f "$src" ]; then
    mkdir -p "$(dirname "$src")"
    fetch_remote "$aux" "$src" "$REF_PIN" || { warn "Failed to fetch $aux"; continue; }
  fi
  cp "$src" "$dst"
  # /usr/bin/env does not exist on Termux -> rewrite the shebang to the Termux bash path.
  sed -i "1s|^#!.*|#!$PREFIX/bin/bash|" "$dst"
  chmod 755 "$dst"
done
dim "Support scripts: $ROOT (doctor, upgrade, uninstall)"

# --- loader library shim ----------------------------------------------------
# The V2 binary (Bun) needs "libc.so"; the Termux glibc only ships a GNU ld
# script (a text file) -> the glibc loader fails with "invalid ELF header".
if ensure_compat_libs; then
  ok "glibc library shim: $COMPAT_LIB (libc.so -> libc.so.6)"
else
  die "Failed to create the glibc library shim in $COMPAT_LIB"
fi

# --- bundled plugins (memory_save + session titles + update notice) ---------
PLUGIN_DIR="$HOME/.config/opencode/plugins"
install_plugin() {
  local name="$1"
  local src="$SCRIPT_DIR/plugins/$name"
  local dst="$PLUGIN_DIR/$name"
  if [ ! -f "$src" ]; then
    mkdir -p "$SCRIPT_DIR/plugins"
    fetch_remote "plugins/$name" "$src" "$REF_PIN" \
      || { warn "Failed to download plugins/$name"; return 1; }
  fi
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    local backup
    if [ "$name" = "memory.js" ]; then
      backup="$dst.v1.bak"
      [ -e "$backup" ] && backup="$dst.v1.$(date +%Y%m%d%H%M%S).bak"
    else
      backup="$dst.bak-$(date +%Y%m%d%H%M%S)"
    fi
    cp "$dst" "$backup"
    dim "Old plugin backed up to $backup"
  fi
  cp "$src" "$dst"
  ok "Plugin installed: $dst"
}
if [ "$NO_PLUGIN" -eq 1 ]; then
  dim "Bundled plugins skipped (--no-plugin)"
else
  mkdir -p "$PLUGIN_DIR"
  install_plugin memory.js || true
  install_plugin session-title.js || true
  install_plugin update-notice.js || true
fi

# --- private memory + automatic session summaries ---------------------------
OC_DIR="$HOME/.config/opencode"
DIGEST_DIR="$OC_DIR/bin"
DIGEST_FILE="$DIGEST_DIR/session-digest.py"
if [ "$WITH_MEMORY" -eq 1 ]; then
  step "Installing private memory + session summaries"
  mkdir -p "$DIGEST_DIR"

  DIGEST_SRC="$SCRIPT_DIR/plugins/session-digest.py"
  if [ ! -f "$DIGEST_SRC" ]; then
    mkdir -p "$SCRIPT_DIR/plugins"
    fetch_remote "plugins/session-digest.py" "$DIGEST_SRC" "$REF_PIN" \
      || warn "Failed to download plugins/session-digest.py"
  fi
  if [ -f "$DIGEST_SRC" ]; then
    cp "$DIGEST_SRC" "$DIGEST_FILE"
    sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$DIGEST_FILE"
    chmod 755 "$DIGEST_FILE"
    ok "Session digest generator: $DIGEST_FILE"
  fi

  # kuota: estimated remaining free-model quota (local databases only, no network)
  KUOTA_FILE="$DIGEST_DIR/kuota"
  KUOTA_SRC="$SCRIPT_DIR/plugins/kuota.py"
  if [ ! -f "$KUOTA_SRC" ]; then
    mkdir -p "$SCRIPT_DIR/plugins"
    fetch_remote "plugins/kuota.py" "$KUOTA_SRC" "$REF_PIN" \
      || warn "Failed to download plugins/kuota.py"
  fi
  if [ -f "$KUOTA_SRC" ]; then
    cp "$KUOTA_SRC" "$KUOTA_FILE"
    sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$KUOTA_FILE"
    chmod 755 "$KUOTA_FILE"
    mkdir -p "$PREFIX/bin"
    ln -sf "$KUOTA_FILE" "$PREFIX/bin/kuota"
    ok "Quota estimator: $KUOTA_FILE (command: kuota)"
  fi

  # Template files are ONLY installed when missing — memory that already holds
  # user facts must never be overwritten.
  for f in MEMORY.md AGENTS.md opencode.jsonc; do
    if [ -f "$OC_DIR/$f" ]; then
      dim "already exists, skipped: $OC_DIR/$f"
      continue
    fi
    src="$SCRIPT_DIR/memory/$f"
    if [ ! -f "$src" ]; then
      mkdir -p "$SCRIPT_DIR/memory"
      fetch_remote "memory/$f" "$src" "$REF_PIN" \
        || { warn "Failed to fetch memory/$f"; continue; }
    fi
    cp "$src" "$OC_DIR/$f"
    if [ "$f" = "opencode.jsonc" ]; then
      sed -i "s|/data/data/com.termux/files/home|$HOME|g" "$OC_DIR/$f"
    fi
  done
  [ -f "$OC_DIR/RECENT.md" ] || printf '# RECENT\n\nNo sessions recorded yet.\n' >"$OC_DIR/RECENT.md"
  if [ -x "$DIGEST_FILE" ]; then
    python3 "$DIGEST_FILE" >/dev/null 2>&1 || true
  fi
  ok "Memory/templates, rules, and instructions ready in $OC_DIR"

  if ! grep -q "_oc_refresh_digest" "$HOME/.bashrc" 2>/dev/null; then
    [ -f "$HOME/.bashrc" ] || : >"$HOME/.bashrc"
    cat >>"$HOME/.bashrc" <<'EOS'

# --- refresh the session digest before opencode starts (install.sh) ---
_oc_refresh_digest() {
  [ -x "$HOME/.config/opencode/bin/session-digest.py" ] || return 0
  python3 "$HOME/.config/opencode/bin/session-digest.py" >/dev/null 2>&1
}
# V1 keeps its own database. Drop the V2 XDG_* values so starting V1 from a V2
# shell cannot point it at the V2 database ("no session table", blank screen).
_oc_tty_repair() {
  [ -t 1 ] || return 0
  stty sane 2>/dev/null
  printf '\033[?1049l\033[?25h\033[0m'
}
opencode() {
  _oc_refresh_digest
  local rc=0
  ( unset XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; command opencode "$@" )
  rc=$?
  [ "$rc" -ne 0 ] && _oc_tty_repair
  return "$rc"
}
opencode-v2() {
  _oc_refresh_digest
  local rc=0
  command opencode-v2 "$@"
  rc=$?
  [ "$rc" -ne 0 ] && _oc_tty_repair
  return "$rc"
}
EOS
    ok "~/.bashrc: session digest refreshes automatically"
  fi
fi

# --- V2 configuration (separate from V1) -----------------------------------
mkdir -p "$V2HOME" "$XDG_DATA_DIR" "$XDG_STATE_DIR" "$XDG_CACHE_DIR" "$LOG_DIR"
write_state
info "V2 data (separate from V1) : $XDG_DATA_DIR"
info "V2 state/log               : $XDG_STATE_DIR / $LOG_DIR"

# --- smoke test -------------------------------------------------------------
step "Smoke test: starting the background service"
if ! daemon_start; then
  err "Smoke test failed. See the log: $SERVER_LOG"
  exit 1
fi

step "Smoke test: opencode-v2 --version"
VERSION_OUT="$("$LAUNCHER" --version 2>&1 || true)"
printf '%s\n' "$VERSION_OUT" | sed 's/^/    /'
case "$VERSION_OUT" in
  *"$TARGET"*) ok "opencode-v2 works (version $TARGET)" ;;
  *) warn "Version output does not match, check manually: $LAUNCHER --version" ;;
esac

echo
ok "Installation complete"
info ""
info "Command       : opencode-v2"
info "Status        : opencode-v2 service status"
info "Check         : opencode-v2 doctor"
info "Server log    : $SERVER_LOG"
info ""
info "OpenCode V1 stays intact (the 'opencode' command). Both share the same"
info "memory_save + session-title plugins and keep separate databases."
