#!/usr/bin/env bash
# tests/install-static.sh — structural assertions for install.sh / lib/common.sh.
#
# These bugs were found by audit and none of them is visible to a dry run:
#   * fetch_remote downloaded straight to the destination, so a cut connection
#     could leave a truncated common.sh / plugin that was installed as whole
#   * the ~/.bashrc hook repaired the terminal only when opencode exited with an
#     error, while a clean TUI exit can leave the alt-screen up (frozen screen),
#     and its header word ("digest") hid it from codemux's legacy-block cleanup
#   * daemon_start needs setsid, but util-linux was not in BASE_PKGS
#   * quota.py crashed with a traceback on a non-numeric --days/--limit/--warn-at
#   * a stale plugins/kuota.py from the pre-rename era was still in the repo
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# 1. fetch_remote must stage through a .part file and only move complete files.
if grep -qF 'part="$2.part"' install.sh &&
  grep -qF 'mv -f "$part" "$dest"' install.sh &&
  [ "$(grep -cF -- '-o "$dest" 2>/dev/null' install.sh)" = "0" ]; then
  ok "fetch_remote stages through a .part file"
else
  bad "fetch_remote can still leave a truncated download at the destination"
fi

# 2. the bashrc hook: header word, unconditional repair, full mode reset.
hook="$(sed -n '/^# --- refresh the session summary before opencode starts/,/^EOS$/p' install.sh)"
[ -n "$hook" ] && ok "hook header uses the word codemux cleans up" ||
  bad "hook header no longer matches codemux's legacy-block cleanup"
if printf '%s' "$hook" | grep -qF '[ "$rc" -ne 0 ] && _oc_tty_repair'; then
  bad "repair is still gated on a non-zero exit code"
else
  ok "repair runs after every opencode exit"
fi
if printf '%s' "$hook" | grep -qF '\033[?1049l'; then
  ok "hook resets the alt-screen"
else
  bad "hook does not leave the alt-screen"
fi
if printf '%s' "$hook" | grep -qF '\033[?1000l'; then
  ok "hook resets the mouse modes"
else
  bad "hook does not reset the mouse modes"
fi

# 3. setsid must be guaranteed: util-linux in BASE_PKGS.
if grep -qF 'util-linux' lib/common.sh; then
  ok "util-linux (setsid) is in BASE_PKGS"
else
  bad "daemon_start uses setsid but BASE_PKGS does not install it"
fi

# 4. quota.py: bad numbers are a usage error (exit 2), not a traceback.
if grep -qF 'expects a number' plugins/quota.py; then
  ok "quota.py rejects non-numeric values cleanly"
else
  bad "quota.py still crashes with a traceback on bad values"
fi

# 5. the stale pre-rename plugin is gone; the quota command is installed.
[ -f plugins/quota.py ] && ok "plugins/quota.py exists" || bad "plugins/quota.py missing"
[ -f plugins/kuota.py ] && bad "stale plugins/kuota.py still in the repo" || ok "no stale plugins/kuota.py"
grep -qF 'ln -sf "$QUOTA_FILE" "$PREFIX/bin/quota"' install.sh &&
  ok "quota symlink installed" ||
  bad "quota symlink missing"

# 6. the banner box must be aligned: every │ line has the same display width.
bad_width=0
while IFS= read -r line; do
  inner="${line#│}"; inner="${inner%│}"
  [ "${#inner}" = "46" ] || bad_width=1
done < <(grep '^│' install.sh)
[ "$bad_width" = "0" ] && ok "banner box is aligned (46 columns)" ||
  bad "banner box lines have different widths"

# 7. --version / --ref without a value must be rejected.
grep -qF '"--version needs a value' install.sh &&
  ok "--version without a value is rejected" ||
  bad "--version without a value is silently ignored"
grep -qF '"--ref needs a' install.sh &&
  ok "--ref without a value is rejected" ||
  bad "--ref without a value is silently ignored"

# 8. the python download fallbacks must stream to disk, never read a whole
#    download into RAM (download_url also serves the ~115 MB payload).
du_common="$(sed -n '/^download_url()/,/^}/p' lib/common.sh)"
if printf '%s' "$du_common" | grep -q 'shutil.copyfileobj' &&
   ! printf '%s' "$du_common" | grep -q 'urlopen(req, timeout=60).read()'; then
  ok "download_url python fallback streams to disk"
else
  bad "download_url python fallback reads the whole payload into RAM"
fi
fr_install="$(sed -n '/^fetch_remote()/,/^}/p' install.sh)"
if printf '%s' "$fr_install" | grep -q 'shutil.copyfileobj' &&
   ! printf '%s' "$fr_install" | grep -q 'urlopen(req, timeout=60).read()'; then
  ok "fetch_remote python fallback streams to disk"
else
  bad "fetch_remote python fallback reads the whole file into RAM"
fi

# 9. staged sources are checked with -s: a 0-byte leftover from an interrupted
#    older fetch must never be installed as the real plugin/script/template.
if [ "$(grep -cF -- '[ ! -f "$src" ]' install.sh)" = "0" ] &&
   grep -qF -- '[ ! -s "$src" ]' install.sh; then
  ok "staged sources are size-checked (-s)"
else
  bad "a 0-byte staged source can still be installed"
fi

# 10. install.sh must not make its own payload backup: download_payload writes
#     to $REAL.new and moves it only after success, and upgrade.sh owns the
#     rollback copy — the old cp wasted ~115 MB on every install.
if grep -qF 'cp "$REAL" "$BACKUP"' install.sh; then
  bad "install.sh still makes a dead ~115 MB backup copy"
else
  ok "no dead payload backup in install.sh (upgrade.sh owns rollback)"
fi

# 11. uninstall.sh must restore the newest memory.js V1 backup, including the
#     timestamped .v1.<ts>.bak names created by the second and later installs.
mem_restore="$(sed -n '/^PLUGIN=.*memory.js/,/restored to the V1 version/p' uninstall.sh)"
if printf '%s' "$mem_restore" | grep -q 'ls -1t' &&
   printf '%s' "$mem_restore" | grep -q '\.v1\.\*\.bak'; then
  ok "uninstall restores the newest .v1* backup of memory.js"
else
  bad "uninstall only restores the fixed .v1.bak name (2nd install loses the V1 plugin)"
fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
