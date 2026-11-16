#!/usr/bin/env bash
# common.sh — shared functions for the OpenCode V2 installer/upgrade/uninstall/doctor on Termux.
# sourced, not executed.

APP="opencode-v2"
REPO_SLUG="kusnuzon/opencode-termux-v2"
# shellcheck disable=SC2034  # used by install.sh
DEFAULT_REF="main"
# shellcheck disable=SC2034  # used by install.sh
RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}"
# Payload mirror, same mechanism as the V1 repo: every release attaches the
# binary tarball + sha256 so installs do not depend on the npm registry.
MIRROR_TAG_PREFIX="opencode-termux-v2-"
MIRROR_ASSET="opencode-v2-linux-arm64.tar.gz"
MIRROR_BASE="${OPENCODE_V2_MIRROR_BASE:-https://github.com/${REPO_SLUG}/releases/download}"

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

# --- progress-bar begin (synced from codemux/lib/progress-bar.sh) ---
# progress_bar <percent> [width] [label] — plain ASCII bar + percentage.
# Out-of-range and non-numeric input is clamped, never an error: the callers
# use it inside command substitution, where an error would print garbage.
progress_bar() {
  local pct="${1:-0}" width="${2:-24}" label="${3:-}"
  local filled blank bar dash
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  [ "$width" -gt 0 ] 2>/dev/null || width=24
  filled=$((pct * width / 100))
  blank=$((width - filled))
  printf -v bar '%*s' "$filled" ''
  printf -v dash '%*s' "$blank" ''
  bar="${bar// /#}"
  dash="${dash// /-}"
  printf '[%s%s] %3d%%' "$bar" "$dash" "$pct"
  [ -n "$label" ] && printf '  %s' "$label"
  return 0
}

# progress_step <current> <total> <label> — a numbered bar line.
progress_step() {
  progress_bar "$((10#${1:-0} * 100 / 10#${2:-1}))" 24 "${1:-0}/${2:-0} ${3:-}"
}
# --- progress-bar end ---

# --- tmux-config begin (synced from codemux/lib/tmux-config.sh) ---
# Managed tmux config: dark status bar (tmux 3.8 defaults to green on black),
# a 20-column tab strip you can tap, plus the extended keys the pi TUI needs.
# Everything outside the markers belongs to the user and is never touched.
#
# The strip is one tmux window per tab:
#   " 0:menu          ✕ │ "  tap the name to switch, tap ✕ to close it
#   "  keep    │ close   "  the same tab while a close waits for an answer
# and " + new tab " sits at the right end of the bar.
#
# Clicks are read from #{mouse_status_range}, never from #{mouse_x}: tmux scrolls
# the window list by itself when the tabs do not fit, so a column count would
# point at the wrong tab. Every tap area is a #[range=user|...] region instead,
# which survives scrolling and any change of width.
#
# The handler is a script (codemux installs it next to the menu) because a
# .tmux.conf cannot define a function. Each binding ends with `exit 0`: tmux
# prints "'<script>' returned 1" on the message line for a failing run-shell,
# and that looks like a broken strip.
TMUXCONF_BEGIN='# --- codemux:tmux begin (managed; edits inside this block are overwritten) ---'
TMUXCONF_END='# --- codemux:tmux end ---'

# tmuxconf_block — print the managed block, markers included.
tmuxconf_block() {
  cat <<TMUXCONF
$TMUXCONF_BEGIN
# pi relies on extended keys so Shift+Enter and friends reach the TUI.
set -g extended-keys on
set -g extended-keys-format csi-u

# Tap a tab on the status bar to switch to it (tmux's own binding).
set -g mouse on

# Dark status bar on top: tmux 3.8 defaults to green on black. The window list
# stays the plain "index: name" strip — no custom formats to mis-render.
set -g status-position top
set -g status-style "bg=#101010,fg=#c0c0c0"
set -g status-left ""
set -g window-status-separator ""
# The menu names each tab, so tmux must not rename it back to the command.
set -g automatic-rename off

# One tab = 20 columns, always: a space, the index + a name cut to 12 columns
# (p15 pads the slot, so a short name never shrinks the target under a finger),
# then the ✕ button and the separator of that tab.
set -g window-status-format "#{?#{==:#{window_index},#{@closepending}},#[range=user|k#{window_index}]#[fg=#c0c0c0]  keep    #[range=user|x#{window_index}]#[fg=#5f6368]│#[fg=#ff6b6b#,bold] close   #[default], #[range=user|t#{window_index}]#{p15:#{window_index}:#{=12:window_name}}#[range=user|c#{window_index}] ✕ #[range=user|t#{window_index}]#[fg=#5f6368]│#[default]}"
set -g window-status-current-format "#{?#{==:#{window_index},#{@closepending}},#[range=user|k#{window_index}]#[fg=#c0c0c0]  keep    #[range=user|x#{window_index}]#[fg=#5f6368]│#[fg=#ff6b6b#,bold] close   #[default],#[fg=#ffffff#,bg=#2a2a2a#,bold] #[range=user|t#{window_index}]#{p15:#{window_index}:#{=12:window_name}}#[range=user|c#{window_index}] ✕ #[range=user|t#{window_index}] #[default]}"
set -g window-status-current-style "default"
set -g status-right "#[range=user|new] + new tab #[default]"

bind-key -n MouseDown1Status "run-shell \"sh \$HOME/.config/codemux/tabctl.sh tap '#{mouse_status_range}' >/dev/null 2>&1; exit 0\""
bind-key -n MouseDown1StatusRight "run-shell \"sh \$HOME/.config/codemux/tabctl.sh new >/dev/null 2>&1; exit 0\""
set -g pane-border-style "fg=#2a2a2a"
set -g pane-active-border-style "fg=#5f6368"
set -g message-style "bg=#1a1a1a,fg=#e0e0e0"
set -g message-command-style "bg=#1a1a1a,fg=#e0e0e0"
$TMUXCONF_END
TMUXCONF
}

# tmuxconf_slice <file> — print the managed block found in <file>, markers
# included; prints nothing when the file has no markers. Never fails.
tmuxconf_slice() {
  local file="$1" line inside=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$TMUXCONF_BEGIN" ]; then
      inside=1
      printf '%s\n' "$line"
      continue
    fi
    if [ "$inside" -eq 1 ] && [ "$line" = "$TMUXCONF_END" ]; then
      printf '%s\n' "$line"
      inside=0
      continue
    fi
    [ "$inside" -eq 1 ] && printf '%s\n' "$line"
  done <"$file"
  return 0
}

# tmuxconf_tabctl <path> — print the click handler for the tab strip.
# A .tmux.conf cannot define a function and a strip button that does nothing is
# worse than no button, so the handler ships inside this block: the three repos
# install the same script and V1/V2 need no extra file of their own.
#   tap <range>   t<i> switch, c<i> ask, k<i> keep, x<i> close, new add a tab
# Any non-zero exit makes tmux print "'<script>' returned N" over the whole
# status bar, so every path ends with `exit 0`.
tmuxconf_tabctl() {
  cat <<'TABCTL'
#!/bin/sh
# codemux tabctl — the mouse actions of the .tmux.conf tab strip.
# Installed by codemux (lib/tmux-config.sh). Do not edit by hand.
#
# The confirmation state is the session option @closepending: the tab format
# draws that one tab as two buttons, and the buttons are ranges (k…/x…), so this
# script never has to know where a tab sits on the screen. Taps are resolved
# from #{mouse_status_range}, never from a column count: tmux scrolls the window
# list by itself once the tabs overflow a column count would be wrong anyway.

set -u
action="${1:-}"
range="${2:-}"

sess="$(tmux display-message -p '#S' 2>/dev/null)" || exit 0
[ -n "$sess" ] || exit 0

clear_pending() { tmux set-option -u -t "$sess" @closepending >/dev/null 2>&1; }
window_count() { tmux list-windows -t "$sess:" 2>/dev/null | wc -l; }
last_tab() { tmux display-message -t "$sess" 'Last tab - keeping it open' >/dev/null 2>&1; }

case "$action" in
  new)
    clear_pending
    tmux new-window -t "$sess:" >/dev/null 2>&1
    ;;
  tap)
    idx="${range#?}"
    # Only a plain index is ever passed on to tmux as a window target.
    case "$idx" in
      '' | *[!0-9]*) idx="" ;;
    esac
    case "$range" in
      new)
        clear_pending
        tmux new-window -t "$sess:" >/dev/null 2>&1
        ;;
      t*)
        clear_pending
        [ -n "$idx" ] && tmux select-window -t "$sess:$idx" >/dev/null 2>&1
        ;;
      c*)
        clear_pending
        if [ "$(window_count)" -le 1 ]; then
          last_tab
        elif [ -n "$idx" ]; then
          tmux set-option -t "$sess" @closepending "$idx" >/dev/null 2>&1
        fi
        ;;
      k*)
        clear_pending
        ;;
      x*)
        clear_pending
        if [ "$(window_count)" -le 1 ]; then
          last_tab
        elif [ -n "$idx" ]; then
          tmux kill-window -t "$sess:$idx" >/dev/null 2>&1
          # keep the indexes dense, so a tab number is always its position
          tmux move-window -r -t "$sess:" >/dev/null 2>&1
        fi
        ;;
    esac
    ;;
esac
exit 0
TABCTL
}

tmuxconf_tabctl_path() { printf '%s' "${HOME:-}/.config/codemux/tabctl.sh"; }

# tmuxconf_tabctl_state — ok, stale or missing for the installed handler.
tmuxconf_tabctl_state() {
  local dst want
  dst="$(tmuxconf_tabctl_path)"
  [ -f "$dst" ] || { printf 'missing'; return 0; }
  want="$(tmuxconf_tabctl)"
  if [ "$(cat "$dst" 2>/dev/null)" = "$want" ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_tabctl_install — write the handler, idempotent.
tmuxconf_tabctl_install() {
  local dst tmp
  dst="$(tmuxconf_tabctl_path)"
  [ -n "$dst" ] || return 1
  [ "$(tmuxconf_tabctl_state)" = ok ] && return 0
  mkdir -p "${dst%/*}" 2>/dev/null || return 1
  tmp="$dst.tmp.$$"
  tmuxconf_tabctl >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 700 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# tmuxconf_conf_state <file> — ok, stale or missing for the managed block alone.
tmuxconf_conf_state() {
  local file="${1:-$HOME/.tmux.conf}" want have
  if [ ! -f "$file" ]; then
    printf 'missing'
    return 0
  fi
  grep -qxF "$TMUXCONF_BEGIN" "$file" 2>/dev/null || {
    printf 'missing'
    return 0
  }
  want="$(tmuxconf_block)"
  have="$(tmuxconf_slice "$file")"
  if [ "$want" = "$have" ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_state <file> — the block AND the click handler it binds to. A strip
# whose buttons cannot run anything is not "ok", so that counts as stale.
tmuxconf_state() {
  local file="${1:-$HOME/.tmux.conf}" cstate
  cstate="$(tmuxconf_conf_state "$file")"
  if [ "$cstate" != "ok" ]; then
    printf '%s' "$cstate"
    return 0
  fi
  if [ "$(tmuxconf_tabctl_state)" = ok ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_conf_write <file> — make the managed block present and current.
# Creates the file, appends the block to a user file, or replaces the block
# in place; the previous content is backed up before any change. Returns 0
# when the block is up to date afterwards, 1 when it could not be written.
tmuxconf_conf_write() {
  local conf="${1:-$HOME/.tmux.conf}" state block tmp line skip bak
  state="$(tmuxconf_conf_state "$conf")"
  [ "$state" = "ok" ] && return 0

  mkdir -p "${conf%/*}" 2>/dev/null || return 1
  block="$(tmuxconf_block)" || return 1

  if [ -f "$conf" ]; then
    bak="$conf.bak-tmuxconf-$(date +%Y%m%d%H%M%S)"
    cp "$conf" "$bak" 2>/dev/null || true
  fi

  case "$state" in
    missing)
      if [ -s "$conf" ]; then
        # keep the user's file intact, add a blank line as separator
        [ -z "$(tail -c 1 "$conf" 2>/dev/null)" ] || { printf '\n' >>"$conf"; } 2>/dev/null || return 1
        { printf '%s\n' "$block" >>"$conf"; } 2>/dev/null || return 1
      else
        { printf '%s\n' "$block" >"$conf"; } 2>/dev/null || return 1
      fi
      return 0 ;;
    stale)
      tmp="$conf.tmuxconf.$$"
      skip=0
      : >"$tmp" || return 1
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$TMUXCONF_BEGIN" ]; then
          printf '%s\n' "$block" >>"$tmp"
          skip=1
          continue
        fi
        if [ "$skip" -eq 1 ] && [ "$line" = "$TMUXCONF_END" ]; then
          skip=0
          continue
        fi
        [ "$skip" -eq 1 ] && continue
        printf '%s\n' "$line" >>"$tmp"
      done <"$conf"
      mv -f "$tmp" "$conf" || {
        rm -f "$tmp"
        return 1
      }
      return 0 ;;
  esac
  return 1
}

# tmuxconf_install [file] — write the block and the click handler it binds to.
tmuxconf_install() {
  tmuxconf_conf_write "${1:-$HOME/.tmux.conf}" || return 1
  tmuxconf_tabctl_install || return 1
  return 0
}
# --- tmux-config end ---

# progress_step_line — progress_step with a newline, so a caller can print the
# bar without adding its own printf (the installer prints one line per stage).
progress_step_line() {
  progress_step "$@"
  printf '\n'
}

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

# download_url <url> <dest> [accept] [progress] — curl → wget → python.
# progress=1 shows curl's bar + percentage on a terminal (used for the big
# payload). A partial file must never be treated as success: curl can exit on
# --max-time after writing part of a large payload, so check the exit status.
download_url() {
  local url="$1" dest="$2" accept="${3:-}" progress="${4:-0}" part="$2.part" tok="" rc=0 max_time="${OPENCODE_V2_DOWNLOAD_TIMEOUT:-900}"
  local -a hdr=() whdr=()
  if oc_api_url "$url"; then
    tok="$(oc_gh_token)"
  fi
  [ -n "$accept" ] && hdr+=(-H "Accept: $accept")
  [ -n "$tok" ] && hdr+=(-H "Authorization: Bearer $tok")
  mkdir -p "$(dirname "$dest")" || return 1
  rm -f "$part"
  if have curl; then
    if [ "$progress" = "1" ] && [ -t 2 ]; then
      curl -fL --progress-bar --max-time "$max_time" "${hdr[@]+"${hdr[@]}"}" \
        "$url" -o "$part"
      rc=$?
    else
      curl -fsSL --max-time "$max_time" "${hdr[@]+"${hdr[@]}"}" \
        "$url" -o "$part" 2>/dev/null
      rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ -s "$part" ]; then
      mv -f "$part" "$dest"
      return 0
    fi
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

BASE_PKGS="curl tar unzip gzip coreutils ca-certificates jq python git sqlite wget openssh gh ncdu htop which tmux"
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

# Latest version published as a mirror release in this repo (GitHub only).
# Used when the official version server is unreachable on a mobile network.
mirror_latest_version() {
  local tag=""
  if have gh; then
    tag="$(gh api "repos/${REPO_SLUG}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  fi
  if [ -z "$tag" ]; then
    tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
      "https://github.com/${REPO_SLUG}/releases/latest" 2>/dev/null | sed 's|.*/tag/||')"
  fi
  case "$tag" in
    "${MIRROR_TAG_PREFIX}"*) printf '%s' "${tag#"${MIRROR_TAG_PREFIX}"}" ;;
    *) return 1 ;;
  esac
}

latest_version() {
  local v
  v="$(latest_metadata 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  mirror_latest_version
}

installed_version() {
  [ -f "$VERSION_FILE" ] && head -1 "$VERSION_FILE" || printf 'unknown'
}

# --- download & verify the payload -----------------------------------------
# Preferred source: the GitHub release mirror, exactly like the V1 repo. It is
# reachable on networks where the npm registry is slow or blocked. The npm
# registry stays as a fallback because Node on Termux reports
# process.platform=android, so `npm install` itself cannot be used.
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

# extract_payload_binary <dir> <dest-binary>
# Accepts the mirror tarball (opencode at the top level), a repacked backup
# (opencode.real), or the npm tarball (package/bin/opencode).
extract_payload_binary() {
  local dir="$1" dest="$2" bin=""
  if [ -f "$dir/opencode" ]; then
    bin="$dir/opencode"
  elif [ -f "$dir/opencode.real" ]; then
    bin="$dir/opencode.real"
  elif [ -f "$dir/package/bin/opencode" ]; then
    bin="$dir/package/bin/opencode"
  else
    bin="$(find "$dir" -type f \( -name opencode -o -name opencode.real \) 2>/dev/null | head -1)"
  fi
  [ -n "$bin" ] || return 1
  mkdir -p "$(dirname "$dest")"
  cp "$bin" "$dest"
  chmod 755 "$dest"
}

# download_payload_from_mirror <version> <dest-binary>
# Returns 1 (without dying) when the mirror is unavailable or invalid so the
# caller can fall back to the npm registry. A fresh CDN edge or a partially
# downloaded file can fail the checksum once, so retry a single time.
download_payload_from_mirror() {
  local version="$1" dest="$2"
  local tmp url sha_url expected actual attempt
  url="${MIRROR_BASE}/${MIRROR_TAG_PREFIX}${version}/${MIRROR_ASSET}"
  sha_url="${url}.sha256"

  step "Downloading OpenCode V2 ${version} from the GitHub mirror (~115 MB)"
  for attempt in 1 2; do
    tmp="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/opencode-v2-mirror.XXXXXX")"
    if ! download_url "$url" "$tmp/$MIRROR_ASSET" "" 1; then
      rm -rf "$tmp"
      [ "$attempt" -eq 1 ] || return 1
      warn "mirror download failed — retrying once"
      sleep 2
      continue
    fi
    if download_url "$sha_url" "$tmp/$MIRROR_ASSET.sha256"; then
      expected="$(awk '{print $1; exit}' "$tmp/$MIRROR_ASSET.sha256" 2>/dev/null)"
      actual="$(sha256sum "$tmp/$MIRROR_ASSET" | cut -d' ' -f1)"
      if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        rm -rf "$tmp"
        [ "$attempt" -eq 1 ] || {
          warn "mirror sha256 checksum mismatch — ignoring the GitHub mirror"
          return 1
        }
        warn "mirror sha256 checksum mismatch — retrying once"
        sleep 2
        continue
      fi
      ok "sha256 checksum verified"
    else
      warn "mirror checksum missing, skipping verification"
    fi

    tar -xzf "$tmp/$MIRROR_ASSET" -C "$tmp" ||
      { rm -rf "$tmp"; return 1; }
    extract_payload_binary "$tmp" "$dest" ||
      { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
  done
  return 1
}

# download_payload <version> <dest-binary>
# Tries the GitHub mirror first, then the npm registry (sha512 verified).
download_payload() {
  local version="$1" dest="$2"
  local tmp pkg tarball url integrity expected actual
  if download_payload_from_mirror "$version" "$dest"; then
    return 0
  fi
  warn "GitHub mirror unavailable for ${version} — falling back to the npm registry"
  tmp="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/opencode-v2-dl.XXXXXX")"
  pkg="$(package_name_for "$version")"
  tarball="cli-linux-arm64-${version}.tgz"
  url="https://registry.npmjs.org/${pkg}/-/${tarball}"

  step "Downloading OpenCode V2 ${version} from the npm registry (~115 MB)"
  download_url "$url" "$tmp/$tarball" "" 1 \
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
  extract_payload_binary "$tmp" "$dest" || { rm -rf "$tmp"; die "Binary not found inside $tarball"; }
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
