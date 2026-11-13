#!/data/data/com.termux/files/usr/bin/python3
"""kuota — estimate the remaining free-model quota from the local OpenCode databases.

OpenCode does not expose a usage endpoint for free models (every /usage call is
404, and direct API calls return 429 FreeUsageLimitError). What *is* local: the
number of assistant messages, i.e. one request per answer. This script counts
them per UTC day (the free quota resets at 00:00 UTC = 07:00 WIB) and compares
that with a daily limit.

    kuota                 today's usage + per model
    kuota --week          the last 7 days
    kuota --warn          one line, only when the warning threshold is reached
    kuota --json          machine-readable
    kuota --limit 150     different daily limit (env KUOTA_LIMIT)
    kuota --warn-at 90    warning threshold in percent (env KUOTA_WARN_AT)

Exit codes: 0 below the limit, 1 at/above the limit, 2 usage error.

Databases (both optional, missing = 0):
    V2 ~/.opencode-v2/data/opencode/opencode.db   (table session_message)
    V1 ~/.local/share/opencode/opencode.db        (table message)
"""

import json
import os
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

VERSION = "1.0"

HOME = os.path.expanduser("~")
V1_DB = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
V2_DB = os.path.join(HOME, ".opencode-v2", "data", "opencode", "opencode.db")

DEFAULT_LIMIT = 200
DEFAULT_WARN_AT = 80
BAR_WIDTH = 20


# --- data -------------------------------------------------------------------
def connect(path):
    if not os.path.exists(path):
        return None
    try:
        return sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=3)
    except sqlite3.Error:
        return None


def rows_v2(db):
    return db.execute(
        "SELECT json_extract(data,'$.model.providerID'), "
        "json_extract(data,'$.model.id'), json_extract(data,'$.time.created') "
        "FROM session_message WHERE type = 'assistant'"
    ).fetchall()


def rows_v1(db):
    return db.execute(
        "SELECT json_extract(data,'$.providerID'), json_extract(data,'$.modelID'), "
        "json_extract(data,'$.time.created') FROM message "
        "WHERE json_extract(data,'$.role') = 'assistant'"
    ).fetchall()


def collect():
    """[(utc_date, model_label)] for every assistant message we can find."""
    out = []
    for path, reader in ((V2_DB, rows_v2), (V1_DB, rows_v1)):
        db = connect(path)
        if not db:
            continue
        try:
            for provider, model, created in reader(db):
                if not created:
                    continue
                day = datetime.fromtimestamp(created / 1000.0, tz=timezone.utc).strftime("%Y-%m-%d")
                label = "%s/%s" % (provider or "?", model or "?")
                out.append((day, label))
        except sqlite3.Error:
            continue
        finally:
            db.close()
    return out


# --- helpers ----------------------------------------------------------------
def bar(used, limit):
    if limit <= 0:
        return ""
    frac = min(1.0, used / float(limit))
    filled = int(round(frac * BAR_WIDTH))
    return "[" + "\u2588" * filled + "\u2591" * (BAR_WIDTH - filled) + "]"


def env_int(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


def reset_hint():
    return "resets 07:00 WIB"


def today_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


# --- commands ---------------------------------------------------------------
def cmd_today(limit, warn_at, as_json):
    counts = collect()
    today = today_utc()
    day_rows = [(d, m) for d, m in counts if d == today]
    used = len(day_rows)
    per_model = Counter(m for _, m in day_rows)
    pct = int(round(used * 100.0 / limit)) if limit else 0
    remaining = max(0, limit - used)
    warn = pct >= warn_at

    if as_json:
        print(
            json.dumps(
                {
                    "date": today,
                    "limit": limit,
                    "used": used,
                    "remaining": remaining,
                    "percent": pct,
                    "warn": warn,
                    "warn_at": warn_at,
                    "by_model": dict(per_model.most_common()),
                },
                indent=2,
            )
        )
        return 0 if used < limit else 1

    print("kuota %s · %s (UTC, %s)" % (VERSION, today, reset_hint()))
    print()
    print("  used       %d / %d   %d%%   %s" % (used, limit, pct, bar(used, limit)))
    print("  remaining  %d" % remaining)
    print("  warn at    %d%% (%d)" % (warn_at, int(limit * warn_at / 100)))
    if per_model:
        print()
        print("  by model")
        for name, n in per_model.most_common():
            print("    %-44s %d" % (name[:44], n))
    return 0 if used < limit else 1


def cmd_week(limit, days, as_json):
    counts = collect()
    per_day = Counter(d for d, _ in counts)
    per_day_model = {}
    for d, m in counts:
        per_day_model.setdefault(d, Counter())[m] += 1

    today = datetime.now(timezone.utc).date()
    series = []
    for i in range(days - 1, -1, -1):
        d = (today - timedelta(days=i)).strftime("%Y-%m-%d")
        series.append({"date": d, "used": per_day.get(d, 0)})
    total = sum(row["used"] for row in series)
    average = round(total / float(days), 1) if days else 0.0

    if as_json:
        for row in series:
            row["by_model"] = dict(per_day_model.get(row["date"], {}).most_common())
        print(
            json.dumps(
                {
                    "days": days,
                    "limit": limit,
                    "total": total,
                    "average": average,
                    "series": series,
                },
                indent=2,
            )
        )
        return 0

    print("kuota %s · last %d days (UTC)" % (VERSION, days))
    print()
    for row in series:
        print(
            "  %s  %4d  %s"
            % (row["date"], row["used"], bar(row["used"], limit))
        )
    print()
    print("  total %d · average %.1f/day · limit %d/day" % (total, average, limit))
    return 0


def cmd_warn(limit, warn_at):
    counts = collect()
    today = today_utc()
    used = sum(1 for d, _ in counts if d == today)
    pct = int(round(used * 100.0 / limit)) if limit else 0
    if pct < warn_at:
        return 0
    mark = "\u26a0" if used < limit else "\u2716"
    print("%s kuota %d/%d (%d%%) · run: kuota" % (mark, used, limit, pct))
    return 0 if used < limit else 1


def usage(stream=sys.stdout):
    stream.write(
        "kuota %s — estimated free-model quota from the local databases\n\n"
        "usage: kuota [--week [--days N]] [--warn] [--json]\n"
        "             [--limit N] [--warn-at PERCENT]\n\n"
        "  (no option)   today's usage + breakdown per model\n"
        "  --week        the last 7 days (--days N for another window)\n"
        "  --warn        one line, only when the warning threshold is reached\n"
        "  --json        machine-readable output\n"
        "  --limit N     daily request limit (default 200, env KUOTA_LIMIT)\n"
        "  --warn-at N   warning threshold in percent (default 80, env KUOTA_WARN_AT)\n\n"
        "One assistant message = one request. The free quota resets at 00:00 UTC\n"
        "(07:00 WIB), so days are counted in UTC.\n" % VERSION
    )


def main(argv):
    limit = env_int("KUOTA_LIMIT", DEFAULT_LIMIT)
    warn_at = env_int("KUOTA_WARN_AT", DEFAULT_WARN_AT)
    days = 7
    mode = "today"
    as_json = False

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help", "help"):
            usage()
            return 0
        elif arg == "--json":
            as_json = True
        elif arg == "--week":
            mode = "week"
        elif arg == "--warn":
            mode = "warn"
        elif arg == "--days":
            i += 1
            days = int(argv[i]) if i < len(argv) else 7
        elif arg == "--limit":
            i += 1
            limit = int(argv[i]) if i < len(argv) else DEFAULT_LIMIT
        elif arg == "--warn-at":
            i += 1
            warn_at = int(argv[i]) if i < len(argv) else DEFAULT_WARN_AT
        elif arg in ("-v", "--version"):
            print("kuota %s" % VERSION)
            return 0
        else:
            sys.stderr.write("kuota: unknown option %s\n" % arg)
            usage(sys.stderr)
            return 2
        i += 1

    if limit <= 0:
        sys.stderr.write("kuota: --limit must be greater than 0\n")
        return 2
    if not 1 <= warn_at <= 100:
        sys.stderr.write("kuota: --warn-at must be between 1 and 100\n")
        return 2
    if days <= 0:
        sys.stderr.write("kuota: --days must be greater than 0\n")
        return 2

    try:
        if mode == "week":
            return cmd_week(limit, days, as_json)
        if mode == "warn":
            return cmd_warn(limit, warn_at)
        return cmd_today(limit, warn_at, as_json)
    except sqlite3.Error as exc:
        sys.stderr.write("kuota: database error: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
