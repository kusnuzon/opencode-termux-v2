#!/usr/bin/env bash
# tests/download.sh — exercise download_url() without touching the system.
#
# download_url is the only place that can silently ship a corrupt payload, so
# these cases pin its contract:
#   * a clean download lands on <dest>
#   * a failed curl (HTTP error / partial body) is never accepted
#   * the wget fallback and the python fallback still work
#   * a total failure returns 1 and leaves no .part behind
#
# The fake tools live in a sandbox PATH; nothing outside $SANDBOX is written.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
BASH_BIN="$(command -v bash)"
SANDBOX="$BASE/opencode-termux-v2-download-$$"
rm -rf "$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/out"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- fake tools --------------------------------------------------------------
# Each fake reads SANDBOX/mode so a single script can behave differently per
# test. curl is emulated closely enough for the fallback logic:
#   MODE_OK      → write the payload, exit 0
#   MODE_PARTIAL → write a truncated payload, exit 28 (timeout), like a cut line
#   MODE_HTTP404 → exit 22, write nothing (curl -f)
#   MODE_CURL_OFF → exit 7 (could not connect, e.g. the glibc SSL breakage)
cat >"$SANDBOX/bin/curl" <<'EOS'
#!/usr/bin/env bash
mode="$(cat "$SANDBOX/mode" 2>/dev/null || echo OK)"
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--max-time|--range) shift 2 ;;
    -*)
      case "$1" in -fsSL|-fsL|-fL|-fsI|-f|--progress-bar|-s*) ;; esac
      shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$mode" in
  PARTIAL) [ -n "$out" ] && printf 'PART' >"$out"; exit 28 ;;
  HTTP404) exit 22 ;;
  DOWN) exit 7 ;;
  CURL_OFF|PY_OFF) exit 7 ;;
  *)
    if [ -n "$out" ]; then printf 'GOOD-%s' "$url" >"$out"; fi
    exit 0 ;;
esac
EOS

cat >"$SANDBOX/bin/wget" <<'EOS'
#!/usr/bin/env bash
mode="$(cat "$SANDBOX/mode" 2>/dev/null || echo OK)"
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    --timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
# wget is skipped when curl is down: the glibc SSL breakage takes both out.
case "$mode" in CURL_OFF|PY_OFF|WGET_OFF) exit 4 ;; esac
[ -n "$out" ] && printf 'WGET-%s' "$url" >"$out"
exit 0
EOS

cat >"$SANDBOX/bin/python" <<'EOS'
#!/usr/bin/env bash
# script comes in on stdin: download_url passes it as a heredoc, so the real
# interpreter would run it. Here we only need "the fallback wrote a file".
mode="$(cat "$SANDBOX/mode" 2>/dev/null || echo OK)"
[ "$mode" = "PY_OFF" ] && exit 9
# real call shape: python - <url> <dest> <accept>. Take the destination from
# the literal call, not by position: "python - $url $part $accept" puts the
# url at $1 and $dest at $2. The heredoc is stdin, so drain it first.
for a in "$@"; do
  case "$a" in *.part|*.bin) dest="$a" ;; esac
done
dest="${dest:-${2:-}}"
cat >/dev/null 2>&1 || true
[ -n "$dest" ] && printf 'PY' >"$dest"
exit 0
EOS

chmod 700 "$SANDBOX/bin/curl" "$SANDBOX/bin/wget" "$SANDBOX/bin/python"
for f in "$SANDBOX/bin/curl" "$SANDBOX/bin/wget" "$SANDBOX/bin/python"; do
  sed -i "1s|.*|#!$BASH_BIN|" "$f"
done

export SANDBOX
export PATH="$SANDBOX/bin:$PATH"

# Load only download_url from lib/common.sh plus the helpers it calls, so
# nothing else from the installer runs.
# shellcheck disable=SC2317
eval "$(sed -n '/^download_url()/,/^}/p' "$ROOT/lib/common.sh")"
eval "$(sed -n '/^have()/,/^}/p' "$ROOT/lib/common.sh")"
eval "$(sed -n '/^oc_api_url()/,/^}/p' "$ROOT/lib/common.sh")"
eval "$(sed -n '/^warn()/,/^}/p' "$ROOT/lib/common.sh")"
# warn() uses the palette, which lib/common.sh sets near the top. Predeclare
# them for shellcheck: they are read by the copied warn(), not by this file.
# shellcheck disable=SC2034
{ C_YLW=""; C_RED=""; C_OFF=""; C_BLU=""; C_DIM=""; }
eval "$(sed -n '/^oc_gh_token()/,/^}/p' "$ROOT/lib/common.sh")"
if ! declare -f download_url >/dev/null; then
  printf 'FAIL cannot load download_url from lib/common.sh\n'
  rm -rf "$SANDBOX"
  exit 1
fi

mode() { printf '%s' "$1" >"$SANDBOX/mode"; }
dest="$SANDBOX/out/payload.bin"

# =============================================================================
# 1. normal curl download
# =============================================================================
mode OK
rm -f "$dest"
if download_url "https://example.test/a" "$dest" && [ -s "$dest" ] &&
  grep -q 'GOOD-https://example.test/a' "$dest"; then
  ok "curl: payload written"
else
  bad "curl: payload missing"
fi
if [ ! -e "$dest.part" ]; then ok "curl: no .part left"; else bad "curl: .part left behind"; fi

# =============================================================================
# 2. HTTP error from curl → wget fallback takes over
# =============================================================================
mode HTTP404
rm -f "$dest"
if download_url "https://example.test/b" "$dest" && grep -q '^WGET-' "$dest"; then
  ok "curl 404 → wget fallback"
else
  bad "curl 404 → wget fallback"
fi

# =============================================================================
# 3. curl timeout (partial body) → the partial file must never be accepted.
#    This is the regression that shipped: curl wrote a few bytes and exit 28,
#    and the old code accepted any non-empty .part.
# =============================================================================
mode PARTIAL
rm -f "$dest"
if download_url "https://example.test/c" "$dest" && grep -q '^WGET-' "$dest"; then
  ok "partial curl rejected, wget used"
else
  bad "partial curl accepted or no fallback"
fi
if [ ! -e "$dest.part" ]; then ok "partial: no .part left"; else bad "partial: .part left behind"; fi

# =============================================================================
# 4. curl + wget both fail → python fallback
# =============================================================================
mode CURL_OFF
rm -f "$dest"
if download_url "https://example.test/d" "$dest" && grep -q '^PY' "$dest"; then
  ok "curl+wget fail → python fallback"
else
  bad "curl+wget fail → python fallback"
fi

# =============================================================================
# 5. everything fails → return 1, no dest, no .part
#    python is removed from PATH entirely, because download_url captures a
#    failing fallback with `|| true` and only checks the file.
# =============================================================================
mode PY_OFF
mv "$SANDBOX/bin/python" "$SANDBOX/python.off"
rm -f "$dest"
if download_url "https://example.test/e" "$dest"; then
  bad "total failure returned 0"
else
  ok "total failure returns 1"
fi
if [ ! -e "$dest" ] && [ ! -e "$dest.part" ]; then
  ok "total failure leaves no files"
else
  bad "total failure left files behind"
fi

# =============================================================================
# 6. unwritable destination → clean failure, no crash
# =============================================================================
mode OK
mkdir -p "$SANDBOX/ro"
chmod 500 "$SANDBOX/ro"
mv "$SANDBOX/python.off" "$SANDBOX/bin/python"
mode OK
if download_url "https://example.test/f" "$SANDBOX/ro/x" 2>/dev/null; then
  bad "unwritable dest returned 0"
else
  ok "unwritable dest fails cleanly"
fi
chmod 700 "$SANDBOX/ro"

# =============================================================================
# 7. an API url without a token must explain the 403 quota, not fail silently.
#    GITHUB_TOKEN/GH_TOKEN are pinned empty so a token on this machine cannot
#    hide the message.
# =============================================================================
# Run in a subshell, not as an env-prefixed if: bash does not guarantee that
# `if X=1 cmd` returns a status, so the branch would silently not run at all.
mode PY_OFF
( GITHUB_TOKEN='' GH_TOKEN='' OPENCODE_V2_GITHUB_TOKEN='' \
  PATH="$SANDBOX/bin:/usr/bin:/bin" \
  download_url "https://api.github.com/repos/o/r/contents/x" "$SANDBOX/out/api.bin" 2>"$SANDBOX/api.err" ) \
  && rc7=0 || rc7=$?
if [ "${rc7:-1}" -eq 0 ]; then
  bad "api url without token returned 0"
else
  ok "api url without token returns 1"
fi
if grep -q '60 requests/hour' "$SANDBOX/api.err"; then
  ok "api url without token prints the quota hint"
else
  bad "api url without token: hint missing"
fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
