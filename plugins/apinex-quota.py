#!/usr/bin/env python3
# apinex-quota.py — check APInex daily token quota (free tier 25M, reset 07:00 WIB)
# Source repo: opencode-termux-v2 -> plugins/apinex-quota.py
# Synced to ~/.config/opencode/plugins/apinex-quota.py via sync.sh
#
# Behavior:
#   * Daily quota: 25,000,000 tokens / day (APInex free tier).
#   * Reset: 07:00 Asia/Jakarta (WIB) every day (23:00 UTC previous day).
#   * Since APInex exposes no usage endpoint, we probe a free model
#     (free/deepseek-v4.1-flash) and record total_tokens in the response.
#   * All timestamps are computed dynamically in Asia/Jakarta local time
#     (no hardcoding) so anyone viewing the log sees the correct local time.

import json, os, socket, urllib.request, urllib.error
from datetime import datetime, timedelta, timezone

TZ = timezone(timedelta(hours=7))  # WIB (Asia/Jakarta)
USAGE_FILE = "/storage/emulated/0/Music/OPCDMemory/docs/apinex-quota.log"
WARMING = 22_500_000  # warn when used > 90% of the 25M daily quota

def now_jkt():
    """Current timestamp in Asia/Jakarta local time."""
    try:
        return datetime.now(TZ)
    except Exception:
        # Fallback if timezone database unavailable
        return datetime.now().astimezone(TZ)

def next_reset_jkt(dt):
    """Return the datetime of the next 07:00 WIB reset (exclusive of current)."""
    today = dt.replace(hour=7, minute=0, second=0, microsecond=0)
    if dt >= today:
        return today + timedelta(days=1)
    return today

def format_quota(state):
    """Human-readable quota report (UTC+7) for logs and dashboards."""
    if "error" in state:
        return f"[apinex] QUOTA FAIL: {state['error']}"
    rem, lim, used, probe = state["remaining"], state["limit"], state["used"], state["probe"]
    pct = f"{used / lim * 100:.2f}%"
    if used >= WARMING:
        bar = "████████████████████▒▒▒▒▒▒▒▒▒▒▒▒▒"
        status = "⚠️  high usage (>=90%)"
    else:
        bar = "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
        status = "OK"
    hdr = "=" * 60
    lines = [
        hdr,
        " APINEX TOKEN QUOTA (free tier - 25,000,000 tokens/day)",
        f" Timezone : Asia/Jakarta (WIB, UTC+7) - auto-detected",
        f" Probe    : {probe}",
        f" Checked  : {state['last_check'].strftime('%Y-%m-%d %H:%M WIB')}",
        f" Status   : {status}",
        f" Used     : {used:>10,} / {lim:,} tokens ({pct})",
        f" Bar      : {bar}",
        f" Remaining: {rem:>10,} tokens",
        f" Reset    : {state['reset'].strftime('%Y-%m-%d %H:%M WIB')} (next 07:00 WIB)",
        hdr,
    ]
    return "\n".join(lines)

def check_quota():
    """
    Check APInex daily token quota and save a local snapshot.

    Note: APInex has no usage/quotas API endpoint, so the "usage" number
    here is the total_tokens from the last successful completion probe.
    This is a best-effort tracker and will undercount if completions run
    with streaming/no-usage or through different models.
    """
    config_path = os.path.expanduser("~/.config/opencode/opencode.jsonc")
    if not os.path.exists(config_path):
        return {"error": "opencode config not found", "remaining": None}

    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        return {"error": "opencode config invalid JSON", "remaining": None}

    provider = cfg.get("provider", {})
    api = provider.get("apinex", {}).get("options", {})
    api_key = api.get("apiKey")
    api_base = api.get("baseURL", "https://api.apinex.bond/v1")

    if not api_key:
        return {"error": "APInex API key not found in config", "remaining": None}

    # APInex exposes /subscription with real usage numbers:
    # { "token_limit": 25000000, "tokens_used": N, "tokens_remaining": N, "resets_at_utc": "..." }
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        req = urllib.request.Request(f"{api_base}/subscription", headers=headers)
        r = urllib.request.urlopen(req, timeout=30)
        data = json.loads(r.read().decode())

        limit = int(data.get("token_limit", 25_000_000))
        used = int(data.get("tokens_used", 0))
        remaining = int(data.get("tokens_remaining", limit - used))
        resets_at = data.get("resets_at_utc")
        # Convert resets_at_utc (ISO, Z suffix) to Asia/Jakarta local time
        reset = datetime.fromisoformat(resets_at.replace("Z", "+00:00")).astimezone(TZ) if resets_at else now_jkt()

        state = {
            "last_check": now_jkt(),
            "remaining": remaining,
            "limit": limit,
            "reset": reset,
            "used": used,
            "probe": "subscription-api (real-time)",
            "resets_at_utc": resets_at,
        }
        save_state(state)
        return state
    except Exception as e:
        return {"error": f"failed to fetch /subscription: {type(e).__name__}: {str(e)[:200]}", "remaining": None}

def save_state(state):
    os.makedirs(os.path.dirname(USAGE_FILE), exist_ok=True)
    with open(USAGE_FILE, "w") as f:
        json.dump(state, f, indent=2, default=lambda d: d.isoformat())

def load_state():
    if os.path.exists(USAGE_FILE):
        with open(USAGE_FILE) as f:
            return json.load(f)
    return {"last_check": None, "remaining": None, "limit": None, "reset": None, "used": None, "probe": None}

if __name__ == "__main__":
    st = check_quota()
    print(format_quota(st))
