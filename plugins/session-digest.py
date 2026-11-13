#!/data/data/com.termux/files/usr/bin/python3
"""session-digest.py — automatic summary of recent OpenCode sessions.

Reads the OpenCode V1 database (~/.local/share/opencode/opencode.db) and the V2
database (~/.opencode-v2/data/opencode/opencode.db), then writes
~/.config/opencode/RECENT.md, which is loaded in every session through
`instructions` in opencode.jsonc. The goal: a new session immediately knows what
was discussed / requested in previous sessions without the user asking.

Two sections are written:

  1. "Open items" — work that was left hanging (a question waiting for an answer,
     an explicit next step, a session whose last message is the user's). This is
     what a new session needs first: what is *unfinished*, not what is finished.
  2. "Recent sessions" — the existing per-session summary (user commands + last
     substantial assistant reply).

Used by:
  - ~/.bashrc (launcher menu, before opencode starts)
  - the memory.js plugin (on every memory_save + before compaction)

The MAX_BYTES cap keeps it cheap to load in every session.
"""

import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
OUT = os.path.join(HOME, ".config", "opencode", "RECENT.md")
V1_DB = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
V2_DB = os.path.join(HOME, ".opencode-v2", "data", "opencode", "opencode.db")

MAX_SESSIONS = 8          # newest sessions to summarize
MAX_AGE_DAYS = 21         # sessions older than this are skipped
MAX_BYTES = 9000          # output file size cap
MAX_USER_PROMPTS = 4      # per session
TRUNC_USER = 180
TRUNC_ASSIST = 420

# --- open items -------------------------------------------------------------
MAX_OPEN_ITEMS = 6        # bullets in the "Open items" section
TRUNC_ITEM = 150
MAX_BYTES_ITEMS = 1100

PLACEHOLDER_TITLES = ("new session", "untitled")

# "Next: …" style lines. Matched case-insensitively at the start of a line,
# optionally behind a bullet, a number, or bold markers.
NEXT_INLINE = re.compile(
    r"^\s{0,3}(?:[-*\u2022]\s*|\d+[.)]\s*)?(?:\*\*)?"
    r"(next(?:\s+(?:step|move|up))?|selanjutnya|berikutnya|lanjut(?:kan)?|todo|"
    r"sisa(?:\s+pekerjaan)?|rencana|langkah\s+berikut\w*|follow[-\s]?up|"
    r"remaining|belum\s+dikerjakan|open\s+items?)"
    r"(?:\*\*)?\s*[:\uff1a]\s*(\S.{0,300})",
    re.IGNORECASE,
)

# "## Next" style heading — the items below it count as open items.
NEXT_HEADING = re.compile(
    r"^\s{0,3}#{1,6}\s*(?:\*\*)?"
    r"(next(?:\s+(?:step|move|up)s?)?|selanjutnya|berikutnya|lanjut(?:kan)?|todo|"
    r"sisa(?:\s+pekerjaan)?|rencana|langkah\s+berikut\w*|follow[-\s]?up|"
    r"remaining|open\s+items?)(?:\*\*)?\s*$",
    re.IGNORECASE,
)

BULLET = re.compile(r"^\s{0,3}(?:[-*\u2022]\s*|\d+[.)]\s*)")


def connect(path):
    if not os.path.exists(path):
        return None
    try:
        # read-only + immutable so it never locks / corrupts the WAL
        return sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=3)
    except sqlite3.Error:
        return None


def clean(text, limit):
    if not text:
        return ""
    text = " ".join(str(text).split())
    return text[:limit] + ("…" if len(text) > limit else "")


# --- V1 helpers -------------------------------------------------------------
def v1_last_assistant(db, sid):
    for (t,) in db.execute(
        "SELECT p.data FROM message m JOIN part p ON p.message_id = m.id "
        "WHERE m.session_id = ? AND json_extract(m.data,'$.role') = 'assistant' "
        "AND json_extract(p.data,'$.type') = 'text' "
        "ORDER BY m.time_created DESC, p.time_created DESC LIMIT 6",
        (sid,),
    ):
        try:
            txt = json.loads(t).get("text") if t else ""
        except (ValueError, TypeError):
            continue
        if txt and len(txt) > 60:
            return txt
    return ""


def v1_last_role(db, sid):
    for (t,) in db.execute(
        "SELECT json_extract(m.data,'$.role') FROM message m "
        "WHERE m.session_id = ? ORDER BY m.time_created DESC, m.rowid DESC LIMIT 1",
        (sid,),
    ):
        if t in ("user", "assistant"):
            return t
    return ""


def v1_sessions(db):
    rows = db.execute(
        "SELECT id, title, time_created, time_updated FROM session "
        "WHERE parent_id IS NULL OR parent_id = '' "
        "ORDER BY time_updated DESC LIMIT ?",
        (MAX_SESSIONS * 3,),
    ).fetchall()
    out = []
    for sid, title, created, updated in rows:
        prompts = [
            clean(json.loads(t).get("text"), TRUNC_USER)
            for (t,) in db.execute(
                "SELECT p.data FROM message m JOIN part p ON p.message_id = m.id "
                "WHERE m.session_id = ? AND json_extract(m.data,'$.role') = 'user' "
                "AND json_extract(p.data,'$.type') = 'text' "
                "ORDER BY m.time_created, p.time_created LIMIT ?",
                (sid, MAX_USER_PROMPTS),
            )
            if t and json.loads(t).get("text")
        ]
        result = ""
        for (t,) in db.execute(
            "SELECT p.data FROM message m JOIN part p ON p.message_id = m.id "
            "WHERE m.session_id = ? AND json_extract(m.data,'$.role') = 'assistant' "
            "AND json_extract(p.data,'$.type') = 'text' "
            "ORDER BY m.time_created DESC, p.time_created DESC LIMIT 3",
            (sid,),
        ):
            txt = clean(json.loads(t).get("text") if t else "", TRUNC_ASSIST)
            if len(txt) > 60:
                result = txt
                break
        last_text = v1_last_assistant(db, sid)
        out.append(
            {
                "source": "V1",
                "id": sid,
                "title": clean(title, 90),
                "ts": (updated or created or 0) / 1000.0,
                "prompts": prompts,
                "result": result,
                "last_text": last_text,
                "last_role": v1_last_role(db, sid),
            }
        )
    return out


# --- V2 helpers -------------------------------------------------------------
def v2_message_text(data):
    """Join every text part of one V2 message row (data is the JSON column)."""
    try:
        obj = json.loads(data) if data else {}
    except (ValueError, TypeError):
        return ""
    parts = obj.get("content") or []
    texts = []
    for part in parts:
        if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
            texts.append(part["text"])
    return "\n".join(texts)


def v2_last_assistant(db, sid):
    for (t,) in db.execute(
        "SELECT data FROM session_message WHERE session_id = ? AND type = 'assistant' "
        "ORDER BY seq DESC LIMIT 2",
        (sid,),
    ):
        txt = v2_message_text(t)
        if txt and len(txt) > 60:
            return txt
    return ""


def v2_last_role(db, sid):
    for (t,) in db.execute(
        "SELECT type FROM session_message WHERE session_id = ? "
        "AND type IN ('user','assistant') ORDER BY seq DESC LIMIT 1",
        (sid,),
    ):
        if t in ("user", "assistant"):
            return t
    return ""


def v2_sessions(db):
    rows = db.execute(
        "SELECT id, title, time_created, time_updated FROM session_v2 "
        "WHERE parent_id IS NULL OR parent_id = '' "
        "ORDER BY time_updated DESC LIMIT ?",
        (MAX_SESSIONS * 3,),
    ).fetchall()
    out = []
    for sid, title, created, updated in rows:
        prompts = []
        for (t,) in db.execute(
            "SELECT data FROM session_message WHERE session_id = ? AND type = 'user' "
            "ORDER BY seq LIMIT ?",
            (sid, MAX_USER_PROMPTS),
        ):
            try:
                txt = json.loads(t).get("text") if t else ""
            except (ValueError, TypeError):
                txt = ""
            if txt:
                prompts.append(clean(txt, TRUNC_USER))
        result = ""
        for (t,) in db.execute(
            "SELECT c.value FROM session_message m, "
            "json_each(json_extract(m.data,'$.content')) c "
            "WHERE m.session_id = ? AND m.type = 'assistant' "
            "AND json_extract(c.value,'$.type') = 'text' "
            "ORDER BY m.seq DESC LIMIT 6",
            (sid,),
        ):
            try:
                txt = clean(json.loads(t).get("text") if t else "", TRUNC_ASSIST)
            except (ValueError, TypeError):
                continue
            if len(txt) > 60:
                result = txt
                break
        last_text = v2_last_assistant(db, sid)
        out.append(
            {
                "source": "V2",
                "id": sid,
                "title": clean(title, 90),
                "ts": (updated or created or 0) / 1000.0,
                "prompts": prompts,
                "result": result,
                "last_text": last_text,
                "last_role": v2_last_role(db, sid),
            }
        )
    return out


# --- open items -------------------------------------------------------------
def next_steps(text):
    """Pull explicit 'next step' lines out of one assistant message."""
    found = []
    if not text:
        return found
    lines = text.splitlines()
    grab_after = 0
    for line in lines:
        if grab_after > 0:
            if not line.strip():
                grab_after = 0
                continue
            if line.lstrip().startswith("#"):
                grab_after = 0
                continue
            item = BULLET.sub("", line).strip()
            if item and not item.endswith(":"):
                found.append(clean(item, TRUNC_ITEM))
                grab_after -= 1
                continue
            grab_after = 0
        if NEXT_HEADING.match(line):
            grab_after = 2
            continue
        m = NEXT_INLINE.match(line)
        if m:
            item = m.group(2).strip().strip("*")
            if item:
                found.append(clean(item, TRUNC_ITEM))
    return found


def last_question(text):
    """The last question sentence in the final part of a message."""
    if not text:
        return ""
    tail = " ".join(text[-900:].split())
    if "?" not in tail:
        return ""
    found = ""
    for m in re.finditer(r"[^\n.!?]{8,200}\?", tail):
        found = m.group(0)
    if not found:
        return ""
    sentence = BULLET.sub("", found).lstrip("#*_> ").strip()
    if len(sentence) < 12:
        return ""
    return clean(sentence, TRUNC_ITEM)


def open_items(sessions):
    """One bullet per piece of unfinished work, newest session first."""
    items = []
    for s in sessions:
        stamp = datetime.fromtimestamp(s["ts"]).strftime("%d %b") if s["ts"] else "?"
        tag = "[%s · %s]" % (stamp, s["source"])
        added = 0

        if s["last_role"] == "user":
            pending = s["prompts"][-1] if s["prompts"] else ""
            if pending:
                items.append("%s waiting for a reply to: \"%s\"" % (tag, pending))
                added += 1

        for step in next_steps(s["last_text"])[:2]:
            items.append("%s next: %s" % (tag, step))
            added += 1

        question = last_question(s["last_text"])
        if question and s["last_role"] != "user":
            items.append("%s asked: \"%s\"" % (tag, question))
            added += 1

        if added and len(items) >= MAX_OPEN_ITEMS:
            break

    seen = set()
    unique = []
    for item in items:
        key = item.lower()
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
    return unique[:MAX_OPEN_ITEMS]


def render_items(items):
    if not items:
        return []
    lines = [
        "## Open items (unfinished work from previous sessions)",
        "",
        "> Extracted automatically from the last message of each session. Treat it as",
        "> the starting point: confirm with the user before continuing any of these.",
        "",
    ]
    size = 0
    for item in items:
        line = "- " + item
        if size + len(line) > MAX_BYTES_ITEMS:
            break
        lines.append(line)
        size += len(line) + 1
    lines.append("")
    return lines


# --- rendering --------------------------------------------------------------
def label(s):
    title = s["title"] or ""
    if any(p in title.lower() for p in PLACEHOLDER_TITLES):
        if s["prompts"]:
            title = clean(s["prompts"][0], 60)
        else:
            title = clean(s["id"], 20)
    stamp = datetime.fromtimestamp(s["ts"]).strftime("%d %b %H:%M") if s["ts"] else "?"
    return "%s · %s · %s" % (stamp, s["source"], title)


def render(sessions, items):
    head = [
        "# RECENT — summary of previous sessions (auto-generated)",
        "",
        "> Generated automatically by `~/.config/opencode/bin/session-digest.py`.",
        "> Do not edit manually; this file is overwritten every time opencode starts",
        "> or after `memory_save`. Source: OpenCode V1 + V2 databases.",
        "> Purpose: a new session immediately knows what was discussed/requested",
        "> before, without the user having to remind it.",
        "",
    ]
    head += render_items(items)
    body = []
    size = len("\n".join(head))
    for s in sessions:
        if not s["prompts"] and not s["result"]:
            continue
        block = ["## " + label(s)]
        for p in s["prompts"]:
            block.append("- User: " + p)
        if s["result"]:
            block.append("- Result: " + s["result"])
        block.append("")
        chunk = "\n".join(block)
        if size + len(chunk) > MAX_BYTES:
            break
        body.append(chunk)
        size += len(chunk)
    if not body:
        body = ["_(no sessions recorded yet)_", ""]
    return "\n".join(head + body).rstrip() + "\n"


def main():
    sessions = []
    for path, reader in ((V1_DB, v1_sessions), (V2_DB, v2_sessions)):
        db = connect(path)
        if not db:
            continue
        try:
            sessions.extend(reader(db))
        except sqlite3.Error as exc:
            print("skipping %s: %s" % (path, exc), file=sys.stderr)
        finally:
            db.close()

    # `--utc` is only used by tests
    now = datetime.now(timezone.utc) if "--utc" in sys.argv else datetime.now()
    cutoff = now.timestamp() - MAX_AGE_DAYS * 86400
    sessions = [s for s in sessions if (s["ts"] or 0) >= cutoff]
    sessions.sort(key=lambda s: s["ts"], reverse=True)
    sessions = sessions[:MAX_SESSIONS]

    text = render(sessions, open_items(sessions))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, OUT)
    print("%s (%d bytes, %d sessions)" % (OUT, len(text.encode()), len(sessions)))


if __name__ == "__main__":
    main()
