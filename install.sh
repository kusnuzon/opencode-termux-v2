#!/usr/bin/env bash
# install.sh — pemasangan OpenCode V2 di Termux (Android arm64).
#
# Cara pakai (satu perintah):
#   curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/install.sh | bash
#
# Dari clone repo:
#   git clone https://github.com/kusnuzon/opencode-termux-v2 && cd opencode-termux-v2 && ./install.sh
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || printf '.')"

# Konstanta ini dipakai sebelum common.sh dimuat (script yang di-pipe tidak
# punya file di sampingnya), jadi didefinisikan ulang di sini.
REPO_SLUG="kusnuzon/opencode-termux-v2"
RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}"
DEFAULT_REF="main"

# fetch_remote <path-di-repo> <file-tujuan> [ref]
# Mengambil file dari GitHub. LEBIH DAHULU lewat API (header raw) karena
# raw.githubusercontent.com sering menyajikan versi lama dari cache proxy
# jaringan; API selalu segar. Kalau API gagal (rate limit), pakai raw.
fetch_remote() {
  local path="$1" dest="$2" ref="${3:-$DEFAULT_REF}"
  if curl -fsSL --max-time 60 \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${REPO_SLUG}/contents/${path}?ref=${ref}" \
    -o "$dest" 2>/dev/null; then
    return 0
  fi
  curl -fsSL --max-time 60 -o "$dest" "${RAW_BASE}/${ref}/${path}"
}

# Muat common.sh dari clone lokal; kalau dijalankan lewat pipe, unduh dari GitHub.
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh"
else
  REF="${OPENCODE_V2_REF:-$DEFAULT_REF}"
  TMPD="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/opencode-v2-inst.XXXXXX")"
  trap 'rm -rf "$TMPD"' EXIT
  mkdir -p "$TMPD/lib"
  fetch_remote "lib/common.sh" "$TMPD/lib/common.sh" "$REF" \
    || { echo "Gagal mengunduh lib/common.sh dari repo $REPO_SLUG ($REF)" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "$TMPD/lib/common.sh"
  SCRIPT_DIR="$TMPD"
fi

VERSION_ARG=""
DRY_RUN=0
NO_PLUGIN=0
CHECK_ONLY=0
UPGRADE=0
WITH_MEMORY=1
REF_PIN="${OPENCODE_V2_REF:-$DEFAULT_REF}"

usage() {
  cat <<'EOF'
Pemasangan OpenCode V2 untuk Termux (Android arm64).

Pemakaian:
  install.sh [opsi]

Opsi:
  --version <ver>   Pasang versi tertentu (default: versi terbaru)
  --upgrade         Setara upgrade.sh (pertahankan konfigurasi)
  --check           Hanya periksa status, tidak mengubah apa pun
  --dry-run         Tampilkan rencana tanpa memasang
  --no-plugin       Jangan pasang plugin bawaan (memory_save + judul sesi)
  --no-memory       Jangan pasang template memori/AGENTS/RECENT + hook ~/.bashrc
  --with-memory     (default) Pasang memori pribadi: MEMORY.md, AGENTS.md,
                    RECENT.md (ringkasan sesi otomatis) + hook ~/.bashrc
  --ref <ref>       Ambil skrip pendukung dari branch/tag lain
  -h, --help        Tampilkan bantuan ini

Contoh:
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
    --no-memory) WITH_MEMORY=0; shift ;;
    --with-memory) WITH_MEMORY=1; shift ;;
    --ref) REF_PIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Opsi tidak dikenal: $1"; usage; exit 1 ;;
  esac
done

printf '%s\n' "╭──────────────────────────────────────────────╮"
printf '%s\n' "│  OpenCode V2 installer — Termux / Android       │"
printf '%s\n' "╰──────────────────────────────────────────────╯"

require_termux
ensure_tools

CURRENT="$(installed_version)"
info "PREFIX      : $PREFIX"
info "Versi terpasang saat ini : ${CURRENT}"
info "Versi repository         : $(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || printf 'n/a')"
echo

if [ "$CHECK_ONLY" -eq 1 ]; then
  "$SCRIPT_DIR/doctor.sh" 2>/dev/null || {
    warn "doctor.sh tidak ditemukan di lokasi ini — lewati pemeriksaan detail"
  }
  exit 0
fi

# --- tentukan versi target --------------------------------------------------
TARGET="$VERSION_ARG"
if [ -z "$TARGET" ]; then
  step "Mengambil versi terbaru dari server resmi"
  META="$(latest_metadata)" || die "Gagal menghubungi server versi OpenCode"
  TARGET="$(json_field version "$META")"
  [ -n "$TARGET" ] || die "Tidak bisa membaca versi terbaru dari metadata resmi"
fi
info "Versi target : $TARGET"
echo

if [ "$DRY_RUN" -eq 1 ]; then
  step "Rencana (dry-run):"
  info "  1. Pastikan runtime glibc Termux (glibc-repo, glibc, termux-exec-glibc)"
  info "  2. Siapkan shim pustaka (libc.so -> libc.so.6) untuk loader glibc"
  info "  3. Unduh payload resmi @opencode/cli-linux-arm64 $TARGET (~100 MB)"
  info "  4. Verifikasi checksum sha512 dari registry npm"
  info "  5. Pasang payload ke $ROOT/opencode.real"
  info "  6. Pasang launcher ke $LAUNCHER (perintah: opencode-v2)"
  info "  7. Jalankan background service + smoke test"
  [ "$NO_PLUGIN" -eq 0 ] && info "  8. Pasang plugin bawaan (memory_save + judul sesi) ke ~/.config/opencode/plugins/"
  [ "$WITH_MEMORY" -eq 1 ] && info "  9. Pasang memori pribadi (MEMORY.md, AGENTS.md, RECENT.md) + hook ~/.bashrc"
  exit 0
fi

if [ -n "$CURRENT" ] && [ "$CURRENT" != "unknown" ] && [ "$CURRENT" = "$TARGET" ] && [ -x "$REAL" ] && [ "$UPGRADE" -eq 0 ]; then
  ok "Versi $TARGET sudah terpasang"
else
  # --- runtime glibc --------------------------------------------------------
  ensure_glibc

  # --- unduh payload --------------------------------------------------------
  BACKUP=""
  if [ -x "$REAL" ]; then
    BACKUP="$ROOT/opencode.real.bak"
    cp "$REAL" "$BACKUP"
  fi
  download_payload "$TARGET" "$REAL.new" || die "Instalasi payload gagal"
  mv "$REAL.new" "$REAL"
  printf '%s\n' "$TARGET" >"$VERSION_FILE"
  ok "Payload terpasang: $REAL (versi $TARGET)"
fi

# --- launcher ---------------------------------------------------------------
mkdir -p "$PREFIX/bin" "$ROOT"
LAUNCHER_SRC="$SCRIPT_DIR/opencode-v2-launcher"
if [ ! -f "$LAUNCHER_SRC" ]; then
  fetch_remote "opencode-v2-launcher" "$LAUNCHER_SRC" "$REF_PIN" \
    || die "Gagal mengunduh opencode-v2-launcher"
fi
sed "s|@PREFIX@|$PREFIX|g" "$LAUNCHER_SRC" >"$LAUNCHER.tmp"
mv "$LAUNCHER.tmp" "$LAUNCHER"
chmod 755 "$LAUNCHER"
ok "Launcher terpasang: $LAUNCHER (perintah: opencode-v2)"

# --- skrip pendukung ke $ROOT ----------------------------------------------
mkdir -p "$ROOT/lib"
for aux in lib/common.sh doctor.sh upgrade.sh uninstall.sh; do
  src="$SCRIPT_DIR/$aux"
  dst="$ROOT/${aux#lib/}"
  [ "$aux" = "lib/common.sh" ] && dst="$ROOT/lib/common.sh"
  if [ ! -f "$src" ]; then
    mkdir -p "$(dirname "$src")"
    fetch_remote "$aux" "$src" "$REF_PIN" || { warn "Gagal mengambil $aux"; continue; }
  fi
  cp "$src" "$dst"
  # /usr/bin/env tidak ada di Termux -> shebang diganti ke path bash Termux.
  sed -i "1s|^#!.*|#!$PREFIX/bin/bash|" "$dst"
  chmod 755 "$dst"
done
dim "Skrip pendukung: $ROOT (doctor, upgrade, uninstall)"

# --- shim pustaka loader -----------------------------------------------------
# Binary V2 (Bun) butuh "libc.so"; glibc Termux hanya punya GNU ld script
# (file teks) -> loader glibc error "invalid ELF header".
if ensure_compat_libs; then
  ok "Shim pustaka glibc: $COMPAT_LIB (libc.so -> libc.so.6)"
else
  die "Gagal membuat shim pustaka glibc di $COMPAT_LIB"
fi

# --- plugin bawaan (memory_save + judul sesi) -------------------------------
PLUGIN_DIR="$HOME/.config/opencode/plugins"
install_plugin() {
  local name="$1"
  local src="$SCRIPT_DIR/plugins/$name"
  local dst="$PLUGIN_DIR/$name"
  if [ ! -f "$src" ]; then
    mkdir -p "$SCRIPT_DIR/plugins"
    fetch_remote "plugins/$name" "$src" "$REF_PIN" \
      || { warn "Gagal mengunduh plugins/$name"; return 1; }
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
    dim "Plugin lama dicadangkan ke $backup"
  fi
  cp "$src" "$dst"
  ok "Plugin terpasang: $dst"
}
if [ "$NO_PLUGIN" -eq 1 ]; then
  dim "Plugin bawaan dilewati (--no-plugin)"
else
  mkdir -p "$PLUGIN_DIR"
  install_plugin memory.js || true
  install_plugin session-title.js || true
fi

# --- memori pribadi + ringkasan sesi otomatis -------------------------------
OC_DIR="$HOME/.config/opencode"
DIGEST_DIR="$OC_DIR/bin"
DIGEST_FILE="$DIGEST_DIR/session-digest.py"
if [ "$WITH_MEMORY" -eq 1 ]; then
  step "Memasang memori pribadi + ringkasan sesi"
  mkdir -p "$DIGEST_DIR"

  DIGEST_SRC="$SCRIPT_DIR/plugins/session-digest.py"
  if [ ! -f "$DIGEST_SRC" ]; then
    mkdir -p "$SCRIPT_DIR/plugins"
    fetch_remote "plugins/session-digest.py" "$DIGEST_SRC" "$REF_PIN" \
      || warn "Gagal mengunduh plugins/session-digest.py"
  fi
  if [ -f "$DIGEST_SRC" ]; then
    cp "$DIGEST_SRC" "$DIGEST_FILE"
    sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$DIGEST_FILE"
    chmod 755 "$DIGEST_FILE"
    ok "Generator ringkasan sesi: $DIGEST_FILE"
  fi

  # File template hanya DIPASANG kalau belum ada — memori yang sudah berisi
  # fakta milik user tidak boleh tertimpa.
  for f in MEMORY.md AGENTS.md opencode.jsonc; do
    if [ -f "$OC_DIR/$f" ]; then
      dim "sudah ada, dilewati: $OC_DIR/$f"
      continue
    fi
    src="$SCRIPT_DIR/memory/$f"
    if [ ! -f "$src" ]; then
      mkdir -p "$SCRIPT_DIR/memory"
      fetch_remote "memory/$f" "$src" "$REF_PIN" \
        || { warn "Gagal mengambil memory/$f"; continue; }
    fi
    cp "$src" "$OC_DIR/$f"
    if [ "$f" = "opencode.jsonc" ]; then
      sed -i "s|/data/data/com.termux/files/home|$HOME|g" "$OC_DIR/$f"
    fi
  done
  [ -f "$OC_DIR/RECENT.md" ] || printf '# RECENT\n\nBelum ada sesi tercatat.\n' >"$OC_DIR/RECENT.md"
  if [ -x "$DIGEST_FILE" ]; then
    python3 "$DIGEST_FILE" >/dev/null 2>&1 || true
  fi
  ok "Memori/template, aturan, dan instructions siap di $OC_DIR"

  if [ -f "$HOME/.bashrc" ] && ! grep -q "_oc_refresh_digest" "$HOME/.bashrc"; then
    cat >>"$HOME/.bashrc" <<'EOS'

# --- segarkan ringkasan sesi sebelum opencode dibuka (install.sh) ---
_oc_refresh_digest() {
  [ -x "$HOME/.config/opencode/bin/session-digest.py" ] || return 0
  python3 "$HOME/.config/opencode/bin/session-digest.py" >/dev/null 2>&1
}
opencode() { _oc_refresh_digest; command opencode "$@"; }
opencode-v2() { _oc_refresh_digest; command opencode-v2 "$@"; }
EOS
    ok "~/.bashrc: ringkasan sesi disegarkan otomatis"
  fi
fi

# --- konfigurasi V2 (pisah dari V1) ----------------------------------------
mkdir -p "$V2HOME" "$XDG_DATA_DIR" "$XDG_STATE_DIR" "$XDG_CACHE_DIR" "$LOG_DIR"
write_state
info "Data V2 (terpisah dari V1): $XDG_DATA_DIR"
info "State/log V2               : $XDG_STATE_DIR / $LOG_DIR"

# --- smoke test -------------------------------------------------------------
step "Uji coba: menyalakan background service"
if ! daemon_start; then
  err "Smoke test gagal. Lihat log: $SERVER_LOG"
  exit 1
fi

step "Uji coba: opencode-v2 --version"
VERSION_OUT="$("$LAUNCHER" --version 2>&1 || true)"
printf '%s\n' "$VERSION_OUT" | sed 's/^/    /'
case "$VERSION_OUT" in
  *"$TARGET"*) ok "opencode-v2 berjalan (versi $TARGET)" ;;
  *) warn "Output versi tidak sesuai, cek manual: $LAUNCHER --version" ;;
esac

echo
ok "Instalasi selesai"
info ""
info "Perintah      : opencode-v2"
info "Status        : opencode-v2 service status"
info "Periksa       : opencode-v2 doctor"
info "Log server    : $SERVER_LOG"
info ""
info "OpenCode V1 tetap utuh (perintah 'opencode'). Keduanya memakai plugin"
info "memory_save + judul sesi yang sama dan database yang terpisah."
