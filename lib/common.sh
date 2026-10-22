#!/usr/bin/env bash
# common.sh — fungsi bersama untuk installer/upgrade/uninstall/doctor OpenCode V2 di Termux.
# sourced, bukan dieksekusi.

APP="opencode-v2"
REPO_SLUG="kusnuzon/opencode-termux-v2"
# shellcheck disable=SC2034  # dipakai oleh install.sh
DEFAULT_REF="main"
# shellcheck disable=SC2034  # dipakai oleh install.sh
RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}"

# --- path -------------------------------------------------------------------
: "${PREFIX:=/data/data/com.termux/files/usr}"
ROOT="$PREFIX/share/$APP"
REAL="$ROOT/opencode.real"
VERSION_FILE="$ROOT/VERSION"
# shellcheck disable=SC2034  # dipakai oleh doctor.sh/upgrade.sh/uninstall.sh
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

# --- environment checks -----------------------------------------------------
is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] || [ -d "$PREFIX/glibc" ] || [ "${PREFIX:-}" = "/data/data/com.termux/files/usr" ]
}

require_termux() {
  is_termux || die "Script ini hanya untuk Termux di Android. detected PREFIX=$PREFIX"
  local arch
  arch="$(uname -m)"
  [ "$arch" = "aarch64" ] || die "Hanya arm64 (aarch64) yang didukung. detected arch=$arch"
}

# --- runtime glibc ----------------------------------------------------------
ensure_glibc() {
  if [ -x "$LOADER" ] && [ -f "$GLIBC_LIB/libc.so.6" ]; then
    return 0
  fi
  step "Memasang runtime glibc (dibutuhkan untuk menjalankan binary Linux di Android)"
  have pkg || die "pkg tidak ditemukan — paket Termux tidak lengkap"
  pkg install -y glibc-repo >/dev/null 2>&1 || true
  pkg install -y glibc termux-exec-glibc >/dev/null 2>&1 || true
  [ -x "$LOADER" ] || die "Runtime glibc gagal dipasang. Jalankan manual: pkg install glibc-repo glibc termux-exec-glibc"
  ok "Runtime glibc siap"
}

# --- shim pustaka untuk loader glibc -----------------------------------------
# Binary V2 (Bun) punya entri DT_NEEDED "libc.so" (bukan libc.so.6). Di paket
# glibc Termux, libc.so adalah GNU ld script (file teks), sehingga loader
# glibc gagal membuka: "libc.so: invalid ELF header".
# Solusi: direktori shim berisi symlink libc.so -> libc.so.6 (dan libm.so ->
# libm.so.6), lalu direktori shim diletakkan DI AWAL --library-path.
# Pustaka glibc milik Termux sendiri tidak diubah, jadi ld script tetap utuh
# untuk toolchain linker.
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

# Library path untuk loader glibc: shim dulu, baru glibc Termux.
glibc_lib_path() {
  printf '%s:%s' "$COMPAT_LIB" "$GLIBC_LIB"
}

# --- sanitasi environment untuk loader glibc ---------------------------------
# Shell interaktif Termux menyetel LD_PRELOAD ke pustaka bionic
# (libtermux-exec-ld-preload.so). Loader glibc juga menghormati LD_PRELOAD,
# lalu mencoba memuat pustaka bionic itu ke dalam proses glibc dan gagal:
#   "version `LIBC' not found (required by .../libtermux-exec-ld-preload.so)"
# Simbol versi "LIBC" hanya ada di libc.so bionic, sedangkan glibc memakai
# GLIBC_2.x.
#
# Pola yang sama dipakai helper native OpenCode V1 (unset LD_PRELOAD sebelum
# exec loader) dan glibc-runner resmi Termux ("unset LD_PRELOAD" di baris
# pertama). Setelah dibuang, anak proses bionic tetap jalan normal: ia mewarisi
# LD_PRELOAD dari lingkup glibc, dan termux-exec milik bionic tidak dibutuhkan
# karena Termux sudah menyediakan /system/bin/sh serta linker64.
#
# Catatan: varian glibc dari libtermux-exec.so TIDAK boleh dipakai di sini.
# Pustaka itu meng-interpose execve, tetapi anak bionic tetap menerima
# LD_PRELOAD yang menunjuk ke pustaka glibc -> "CANNOT LINK EXECUTABLE ...
# library libc.so.6 not found".
sanitize_glibc_env() {
  unset LD_PRELOAD
  unset GLIBC_LD_PRELOAD
  unset LD_LIBRARY_PATH
  unset LD_AUDIT
  export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
}

ensure_tools() {
  local missing=()
  local tool
  for tool in curl tar sha512sum base64 od; do
    have "$tool" || missing+=("$tool")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    step "Memasang dependensi: ${missing[*]}"
    have pkg || die "pkg tidak ditemukan"
    pkg install -y "${missing[@]}" >/dev/null 2>&1 || die "Gagal memasang dependensi: ${missing[*]}"
  fi
}

# --- versi ------------------------------------------------------------------
# Metadata resmi: {"version":"2.1.2","package":"@opencode/cli", ...}
latest_metadata() {
  curl -fsSL --max-time 30 https://opencode.ai/update/api/latest/cli/npm
}

latest_version() {
  latest_metadata | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1
}

installed_version() {
  [ -f "$VERSION_FILE" ] && head -1 "$VERSION_FILE" || printf 'unknown'
}

# --- unduh & verifikasi payload --------------------------------------------
# Tarball diambil langsung dari registry npm (bukan lewat npm install, karena
# Node di Termux melaporkan process.platform=android sehingga tidak ada paket
# android/arm64). Checksum sha512 diambil dari metadata registry.
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
# Mengunduh tarball resmi, memverifikasi sha512, lalu mengekstrak binary.
download_payload() {
  local version="$1" dest="$2"
  local tmp pkg tarball url integrity expected actual
  tmp="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/opencode-v2-dl.XXXXXX")"
  pkg="$(package_name_for "$version")"
  tarball="cli-linux-arm64-${version}.tgz"
  url="https://registry.npmjs.org/${pkg}/-/${tarball}"

  step "Mengunduh OpenCode V2 ${version} (~100 MB)"
  curl -fL --retry 3 --max-time 900 -o "$tmp/$tarball" "$url" \
    || { rm -rf "$tmp"; die "Gagal mengunduh $url"; }

  integrity=$(curl -fsSL --max-time 60 "https://registry.npmjs.org/${pkg}/${version}" \
    | sed -n 's/.*"integrity":"sha512-\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$integrity" ]; then
    expected="$(base64_to_hex "$integrity")"
    actual="$(sha512_of_file "$tmp/$tarball")"
    if [ "$expected" != "$actual" ]; then
      rm -rf "$tmp"
      die "Checksum sha512 tidak cocok — file mungkin rusak. Ditolak."
    fi
    ok "Checksum sha512 terverifikasi"
  else
    warn "Metadata integritas tidak ditemukan, lewati verifikasi checksum"
  fi

  tar -xzf "$tmp/$tarball" -C "$tmp" || { rm -rf "$tmp"; die "Gagal mengekstrak $tarball"; }
  [ -f "$tmp/package/bin/opencode" ] || { rm -rf "$tmp"; die "Binary tidak ditemukan di dalam $tarball"; }
  mkdir -p "$(dirname "$dest")"
  cp "$tmp/package/bin/opencode" "$dest"
  chmod 755 "$dest"
  rm -rf "$tmp"
}

# --- daemon / background service --------------------------------------------
# V2 selalu menjalankan background service dengan cara spawn process.execPath.
# Di Termux process.execPath = path loader glibc, sehingga spawn anak selalu
# gagal ("serve: error while loading shared libraries"). Solusinya: daemon
# server dijalankan manual oleh launcher (lewat loader), lalu mendaftarkan
# dirinya di state/service.json. Klien kemudian menemukan daemon itu dan tidak
# pernah melakukan spawn -> tidak ada child process yang gagal.
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

# daemon_start — menjalankan `opencode serve --service` secara terdetach.
daemon_start() {
  ensure_glibc
  ensure_compat_libs || die "Gagal membuat shim pustaka glibc di $COMPAT_LIB"
  mkdir -p "$XDG_DATA_DIR" "$XDG_STATE_DIR" "$XDG_CACHE_DIR" "$LOG_DIR"
  daemon_stop
  step "Menyalakan background service OpenCode V2"
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
      ok "Background service hidup di $(daemon_url)"
      return 0
    fi
    sleep 0.5
  done
  err "Background service gagal start. 10 baris terakhir log:"
  tail -10 "$SERVER_LOG" >&2 2>/dev/null || true
  return 1
}

# daemon_ensure — pastikan ada daemon hidup dengan versi yang cocok.
daemon_ensure() {
  if daemon_healthy; then
    return 0
  fi
  if [ -f "$REGISTRATION" ]; then
    dim "Restarting background service (versi tidak cocok atau proses mati)"
  fi
  daemon_start
}

# --- client -----------------------------------------------------------------
# opencode_client <args...> — menjalankan klien V2 lewat loader glibc dengan
# environment yang terisolasi dari OpenCode V1 (DB & state terpisah).
opencode_client() {
  ensure_compat_libs || die "Gagal membuat shim pustaka glibc di $COMPAT_LIB"
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
  # json_field <key> <text> — sederhana, tanpa jq.
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
