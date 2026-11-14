#!/usr/bin/env bash
# common.sh — shared functions for the OpenCode V2 installer/upgrade/uninstall/doctor on Termux.
# sourced, not executed.

APP="opencode-v2"
REPO_SLUG="kusnuzon/opencode-termux-v2"
# shellcheck disable=SC2034  # used by install.sh
DEFAULT_REF="main"
# shellcheck disable=SC2034  # used by install.sh
RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}"

# --- paths -------------------------------------------------------------------
: "${PREFIX:=/data/data/com.termux/files/usr}"
ROOT="$PREFIX/share/$APP"
REAL="$ROOT/opencode.real"
VERSION_FILE="$ROOT/VERSION"
# shellcheck disable=SC2034  # used by doctor.sh/upgrade.sh/uninstall.sh
LAUNCHER="$PREFIX/bin/$APP"
V2HOME="$HOME/.$APP"
XDG_DATA_DIR="$V2HOME/data"
XDG_STATE_DIR="$V2HOME/state"
XDG_CACHE_DIR="$V2HOME/cache"
LOG_DIR="$V2HOME/log"
SERVER_LOG="$LOG_DIR/server.log"
REGISTRATION="$XDG_STATE_DIR/opencode/service.json"
LOADER="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
GLIBC_LIB="$PREFIX/glibc/lib"
COMPAT_LIB="$ROOT/lib/compat"
STATE_FILE="$V2HOME/install.json"

# --- output -----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_DIM=$'\033[0;2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
err()  { printf '%s✖%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
step() { printf '%s→%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

die() { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- GitHub token (avoid the 60 requests/hour anonymous API limit) -----------
# GitHub API calls without a token are capped at 60/hour and answer HTTP 403
# once the quota is gone, which used to make "download failed" look like a
# broken installer. Reuse a token when one is available: env first, then gh.
_OC_GH_TOKEN_CACHE=""
oc_gh_token() {
  if [ -n "$_OC_GH_TOKEN_CACHE" ]; then
    printf '%s' "$_OC_GH_TOKEN_CACHE"
    return 0
  fi
  local tok="${OPENCODE_V2_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
  if [ -z "$tok" ] && have gh; then
    tok="$(gh auth token --hostname github.com 2>/dev/null || true)"
  fi
  _OC_GH_TOKEN_CACHE="$tok"
  printf '%s' "$tok"
}

oc_api_url() {
  case "$1" in
    "https://api.github.com/"*) return 0 ;;
  esac
  return 1
}

# --- environment checks -----------------------------------------------------
is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] || [ -d "$PREFIX/glibc" ] || [ "${PREFIX:-}" = "/data/data/com.termux/files/usr" ]
}

require_termux() {
  is_termux || die "This script is for Termux on Android only. detected PREFIX=$PREFIX"
  local arch
  arch="$(uname -m)"
  [ "$arch" = "aarch64" ] || die "Only arm64 (aarch64) is supported. detected arch=$arch"
}

# --- network & apt (robust on a fresh Termux) --------------------------------
# Two real problems: (1) `apt-get install` without update -> "Unable to locate
# package"; (2) the glibc packages overwrite libcurl -> curl dies with
# "cannot locate symbol SSL_set_quic_tls_early_data_enabled", so every download
# fails. The installer and upgrade both use these helpers.

apt_update_retry() {
  local i
  for i in 1 2 3; do
    pkg update -y >/dev/null 2>&1 && return 0
    sleep $((i * 2))
  done
  return 1
}

# Any completed HTTPS request means curl works: -f would turn a GitHub API 403
# (quota exhausted) into a false "curl is broken" and trigger a pointless reinstall.
curl_ok() { curl -sS --max-time 10 -o /dev/null https://github.com >/dev/null 2>&1; }

heal_curl() {
  curl_ok && return 0
  warn "curl is unhealthy — reinstalling curl/libcurl/openssl"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold curl libcurl openssl ca-certificates >/dev/null 2>&1 || \
    pkg install -y curl libcurl openssl ca-certificates >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  curl_ok
}

# download_url <url> <dest> [accept] — curl → wget → python.
download_url() {
  local url="$1" dest="$2" accept="${3:-}" part="$2.part" tok=""
  local -a hdr=() whdr=()
  if oc_api_url "$url"; then
    tok="$(oc_gh_token)"
  fi
  [ -n "$accept" ] && hdr+=(-H "Accept: $accept")
  [ -n "$tok" ] && hdr+=(-H "Authorization: Bearer $tok")
  mkdir -p "$(dirname "$dest")" || return 1
  rm -f "$part"
  if have curl; then
    curl -fsSL --max-time 300 "${hdr[@]+"${hdr[@]}"}" "$url" -o "$part" 2>/dev/null
    if [ -s "$part" ]; then mv -f "$part" "$dest"; return 0; fi
    rm -f "$part"
  fi
  [ -n "$tok" ] && whdr+=("--header=Authorization: Bearer $tok")
  if have wget && wget -q --timeout=60 "${whdr[@]+"${whdr[@]}"}" -O "$part" "$url" >/dev/null 2>&1 && [ -s "$part" ]; then
    mv -f "$part" "$dest"; return 0
  fi
  rm -f "$part"
  if have python; then
    python - "$url" "$part" "$accept" "$tok" <<'PY' >/dev/null 2>&1 || true
import sys, urllib.request
url, dest, accept = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
token = sys.argv[4] if len(sys.argv) > 4 else ""
req = urllib.request.Request(url, headers={"User-Agent": "opencode-v2"})
if accept:
    req.add_header("Accept", accept)
if token:
    req.add_header("Authorization", "Bearer " + token)
open(dest, "wb").write(urllib.request.urlopen(req, timeout=60).read())
PY
    [ -s "$part" ] && { mv -f "$part" "$dest"; return 0; }
  fi
  rm -f "$part"
  if oc_api_url "$url" && [ -z "$tok" ]; then
    warn "download failed: GitHub's API allows 60 requests/hour without a token (HTTP 403). Run 'gh auth login' or export GITHUB_TOKEN, then retry."
  fi
  return 1
}

# --- glibc runtime ----------------------------------------------------------
ensure_glibc() {
  if [ -x "$LOADER" ] && [ -f "$GLIBC_LIB/libc.so.6" ]; then
    heal_curl >/dev/null 2>&1 || true
    return 0
  fi
  step "Installing the glibc runtime (required to run Linux binaries on Android)"
  have pkg || die "pkg not found — the Termux packages are incomplete"
  pkg install -y glibc-repo >/dev/null 2>&1 || true
  apt_update_retry || true
  pkg install -y glibc termux-exec-glibc >/dev/null 2>&1 || true
  [ -x "$LOADER" ] || die "Failed to install the glibc runtime. Run manually: pkg install glibc-repo glibc termux-exec-glibc"
  # glibc can overwrite libcurl: repair curl before the next download.
  heal_curl >/dev/null 2>&1 || warn "curl is still broken after glibc (downloads will use wget/python)"
  ok "glibc runtime ready"
}

# --- library shim for the glibc loader --------------------------------------
# The V2 binary (Bun) has a DT_NEEDED entry "libc.so" (not libc.so.6). In the
# Termux glibc package libc.so is a GNU ld script (a text file), so the glibc
# loader fails to open it: "libc.so: invalid ELF header".
# Fix: a shim directory holding the symlinks libc.so -> libc.so.6 (and libm.so ->
# libm.so.6), with the shim directory placed FIRST in --library-path.
# Termux's own glibc libraries are left untouched, so the ld script stays intact
# for the linker toolchain.
ensure_compat_libs() {
  mkdir -p "$COMPAT_LIB" 2>/dev/null || return 1
  local n target
  for n in libc libm; do
    target="$GLIBC_LIB/$n.so.6"
    [ -f "$target" ] || continue
    ln -sf "$target" "$COMPAT_LIB/$n.so" 2>/dev/null || true
  done
  [ -e "$COMPAT_LIB/libc.so" ]
}

# Library path for the glibc loader: shim first, then Termux glibc.
glibc_lib_path() {
  printf '%s:%s' "$COMPAT_LIB" "$GLIBC_LIB"
}

# --- environment sanitising for the glibc loader ----------------------------
# The Termux interactive shell sets LD_PRELOAD to a bionic library
# (libtermux-exec-ld-preload.so). The glibc loader honours LD_PRELOAD too, then
# tries to load that bionic library into the glibc process and fails:
#   "version `LIBC' not found (required by .../libtermux-exec-ld-preload.so)"
# The version symbol "LIBC" only exists in bionic libc, while glibc uses
# GLIBC_2.x.
#
# The same pattern is used by the native OpenCode V1 helper (unset LD_PRELOAD
# before exec'ing the loader) and by the official Termux glibc-runner ("unset
# LD_PRELOAD" on its first line). Once dropped, bionic child processes still run
# normally: they inherit LD_PRELOAD from the glibc scope, and the bionic
# termux-exec is not needed because Termux already provides /system/bin/sh and
# linker64.
#
# Note: the glibc variant of libtermux-exec.so must NOT be used here. That
# library interposes execve, but bionic children still receive an LD_PRELOAD
# pointing at a glibc library -> "CANNOT LINK EXECUTABLE ... library libc.so.6
# not found".
sanitize_glibc_env() {
  unset LD_PRELOAD
  unset GLIBC_LD_PRELOAD
  unset LD_LIBRARY_PATH
  unset LD_AUDIT
  export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
}

# --- built-in updater (the TUI /update command) ------------------------------
# `opencode update` and the TUI `/update` command only detect the "curl" install
# method when realpath(process.execPath) equals realpath(~/.opencode/bin/opencode).
# Termux runs the payload through the glibc loader, so process.execPath is the
# loader: keeping ~/.opencode/bin/opencode as a symlink to that loader makes the
# updater choose "curl", download the official payload to that path and replace
# the symlink. The launcher adopts that payload on the next start.
UPDATER_BIN="${UPDATER_BIN:-$HOME/.opencode/bin/opencode}"

ensure_updater_link() {
  mkdir -p "$(dirname "$UPDATER_BIN")"
  if [ -f "$UPDATER_BIN" ] && [ ! -L "$UPDATER_BIN" ]; then
    return 0          # a downloaded payload is waiting; the launcher adopts it
  fi
  if [ -L "$UPDATER_BIN" ] && [ "$(readlink "$UPDATER_BIN")" = "$LOADER" ]; then
    return 0
  fi
  ln -sfn "$LOADER" "$UPDATER_BIN"
}

BASE_PKGS="curl tar unzip gzip coreutils ca-certificates jq python git sqlite wget openssh gh ncdu htop which"
# Optional/large: needs x11-repo; failure is only a warning.
EXTRA_PKGS="tesseract chromium"

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ensure_tools() {
  local missing=() p
  for p in $BASE_PKGS; do
    pkg_installed "$p" || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    step "Installing dependencies: ${missing[*]}"
    have pkg || die "pkg not found"
    apt_update_retry || true
    # shellcheck disable=SC2086
    pkg install -y "${missing[@]}" >/dev/null 2>&1 ||
      die "Failed to install dependencies: ${missing[*]}"
  fi
  heal_curl >/dev/null 2>&1 || warn "curl is still broken; downloads will use wget/python"

  if [ "${NO_EXTRA:-0}" -eq 0 ]; then
    pkg install -y x11-repo >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    pkg install -y $EXTRA_PKGS >/dev/null 2>&1 ||
      warn "optional packages skipped: $EXTRA_PKGS (install manually: pkg install $EXTRA_PKGS)"
  fi
}

# --- version ----------------------------------------------------------------
# Official metadata: {"version":"2.1.2","package":"@opencode/cli", ...}
latest_metadata() {
  curl -fsSL --max-time 30 https://opencode.ai/update/api/latest/cli/npm
}

latest_version() {
  latest_metadata | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1
}

installed_version() {
  [ -f "$VERSION_FILE" ] && head -1 "$VERSION_FILE" || printf 'unknown'
}

# --- download & verify the payload -----------------------------------------
# The tarball comes straight from the npm registry (not through npm install,
# because Node on Termux reports process.platform=android, so no android/arm64
# package exists). The sha512 checksum comes from the registry metadata.
package_name_for() {
  local version="$1" scope="@opencode"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://registry.npmjs.org/${scope}%2fcli-linux-arm64/${version}" || true)
  if [ "$code" = "404" ]; then
    scope="@opencode-ai"
  fi
  printf '%s/cli-linux-arm64' "$scope"
}

sha512_of_file() {
  sha512sum "$1" | cut -d' ' -f1
}

base64_to_hex() {
  printf '%s' "$1" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

# download_payload <version> <dest-binary>
# Downloads the official tarball, verifies the sha512, then extracts the binary.
download_payload() {
  local version="$1" dest="$2"
  local tmp pkg tarball url integrity expected actual
  tmp="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/opencode-v2-dl.XXXXXX")"
  pkg="$(package_name_for "$version")"
  tarball="cli-linux-arm64-${version}.tgz"
  url="https://registry.npmjs.org/${pkg}/-/${tarball}"

  step "Downloading OpenCode V2 ${version} (~100 MB)"
  download_url "$url" "$tmp/$tarball" \
    || { rm -rf "$tmp"; die "Failed to download $url"; }

  integrity=$(download_url "https://registry.npmjs.org/${pkg}/${version}" "$tmp/meta.json" &&
    sed -n 's/.*"integrity":"sha512-\([^"]*\)".*/\1/p' "$tmp/meta.json" | head -1)
  if [ -n "$integrity" ]; then
    expected="$(base64_to_hex "$integrity")"
    actual="$(sha512_of_file "$tmp/$tarball")"
    if [ "$expected" != "$actual" ]; then
      rm -rf "$tmp"
      die "sha512 checksum mismatch — the file may be corrupt. Rejected."
    fi
    ok "sha512 checksum verified"
  else
    warn "Integrity metadata not found, skipping checksum verification"
  fi

  tar -xzf "$tmp/$tarball" -C "$tmp" || { rm -rf "$tmp"; die "Failed to extract $tarball"; }
  [ -f "$tmp/package/bin/opencode" ] || { rm -rf "$tmp"; die "Binary not found inside $tarball"; }
  mkdir -p "$(dirname "$dest")"
  cp "$tmp/package/bin/opencode" "$dest"
  chmod 755 "$dest"
  rm -rf "$tmp"
}

# --- daemon / background service --------------------------------------------
# V2 always starts its background service by spawning process.execPath. On
# Termux process.execPath = the glibc loader path, so the spawn always fails
# ("serve: error while loading shared libraries"). The fix: the launcher starts
# the server daemon itself (through the loader), and the daemon registers itself
# in state/service.json. The client then finds that daemon and never spawns ->
# no child process fails.
daemon_registration() {
  [ -f "$REGISTRATION" ] && cat "$REGISTRATION" 2>/dev/null || printf ''
}

daemon_pid() {
  daemon_registration | sed -n 's/.*"pid":\([0-9]*\).*/\1/p' | head -1
}

daemon_version() {
  daemon_registration | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1
}

daemon_url() {
  daemon_registration | sed -n 's/.*"url":"\([^"]*\)".*/\1/p' | head -1
}

daemon_alive() {
  local pid
  pid="$(daemon_pid)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

daemon_healthy() {
  daemon_alive || return 1
  local want have_version
  want="$(installed_version)"
  have_version="$(daemon_version)"
  [ -z "$have_version" ] && return 0
  [ "$want" = "$have_version" ] || return 1
  return 0
}

daemon_stop() {
  local pid
  pid="$(daemon_pid)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$REGISTRATION"
}

# daemon_start — starts `opencode serve --service` detached.
daemon_start() {
  ensure_glibc
  ensure_compat_libs || die "Failed to create the glibc library shim in $COMPAT_LIB"
  mkdir -p "$XDG_DATA_DIR" "$XDG_STATE_DIR" "$XDG_CACHE_DIR" "$LOG_DIR"
  daemon_stop
  step "Starting the OpenCode V2 background service"
  (
    sanitize_glibc_env
    export HOME="$HOME"
    export XDG_DATA_HOME="$XDG_DATA_DIR"
    export XDG_STATE_HOME="$XDG_STATE_DIR"
    export XDG_CACHE_HOME="$XDG_CACHE_DIR"
    export PATH="$PREFIX/bin:$PATH"
    export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
    exec setsid "$LOADER" --library-path "$(glibc_lib_path)" "$REAL" serve --service
  ) >>"$SERVER_LOG" 2>&1 </dev/null &
  disown 2>/dev/null || true

  local _
  for _ in $(seq 1 60); do
    if daemon_alive && [ -n "$(daemon_url)" ]; then
      ok "Background service is up at $(daemon_url)"
      return 0
    fi
    sleep 0.5
  done
  err "Background service failed to start. Last 10 log lines:"
  tail -10 "$SERVER_LOG" >&2 2>/dev/null || true
  return 1
}

# daemon_ensure — make sure a live daemon with a matching version exists.
daemon_ensure() {
  if daemon_healthy; then
    return 0
  fi
  if [ -f "$REGISTRATION" ]; then
    dim "Restarting background service (version mismatch or dead process)"
  fi
  daemon_start
}

# --- client -----------------------------------------------------------------
# opencode_client <args...> — runs the V2 client through the glibc loader with
# an environment isolated from OpenCode V1 (separate DB & state).
opencode_client() {
  ensure_compat_libs || die "Failed to create the glibc library shim in $COMPAT_LIB"
  sanitize_glibc_env
  export XDG_DATA_HOME="$XDG_DATA_DIR"
  export XDG_STATE_HOME="$XDG_STATE_DIR"
  export XDG_CACHE_HOME="$XDG_CACHE_DIR"
  export PATH="$PREFIX/bin:$PATH"
  export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
  exec "$LOADER" --library-path "$(glibc_lib_path)" "$REAL" "$@"
}

# --- misc -------------------------------------------------------------------
json_field() {
  # json_field <key> <text> — simple, no jq.
  printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

write_state() {
  mkdir -p "$V2HOME"
  cat >"$STATE_FILE" <<EOF
{
  "version": "$(installed_version)",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "prefix": "$PREFIX",
  "root": "$ROOT",
  "data": "$XDG_DATA_DIR",
  "state": "$XDG_STATE_DIR"
}
EOF
}
