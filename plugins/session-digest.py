#!/data/data/com.termux/files/usr/bin/python3
"""session-digest.py — ringkasan otomatis sesi OpenCode terakhir.

Membaca DB OpenCode V1 (~/.local/share/opencode/opencode.db) dan V2
(~/.opencode-v2/data/opencode/opencode.db), lalu menulis
~/.config/opencode/RECENT.md yang dimuat tiap sesi lewat `instructions`
di opencode.jsonc. Tujuannya: sesi baru langsung tahu apa yang dibahas /
diperintahkan di sesi sebelumnya tanpa perlu disuruh user.

Dipakai oleh:
  - ~/.bashrc (menu launcher, sebelum opencode dibuka)
  - plugin memory.js (setiap memory_save + sebelum compaction)

Batas ukuran MAX_BYTES supaya murah dimuat tiap sesi.
"""

import json
import os
import sqlite3
import sys
from datetime import datetime

HOME = os.path.expanduser("~")
OUT = os.path.join(HOME, ".config", "opencode", "RECENT.md")
V1_DB = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
V2_DB = os.path.join(HOME, ".opencode-v2", "data", "opencode", "opencode.db")

MAX_SESSIONS = 8          # sesi terbaru yang diringkas
MAX_AGE_DAYS = 21         # sesi lebih tua dari ini dilewati
MAX_BYTES = 9000          # batas file hasil
MAX_USER_PROMPTS = 4      # per sesi
TRUNC_USER = 180
TRUNC_ASSIST = 420

PLACEHOLDER_TITLES = ("new session", "untitled")


def connect(path):
    if not os.path.exists(path):
        return None
    try:
        # read-only + immutable supaya tidak pernah mengunci / merusak WAL
        return sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=3)
    except sqlite3.Error:
        return None


def clean(text, limit):
    if not text:
        return ""
    text = " ".join(str(text).split())
    return text[:limit] + ("…" if len(text) > limit else "")


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
        out.append(
            {
                "source": "V1",
                "id": sid,
                "title": clean(title, 90),
                "ts": (updated or created or 0) / 1000.0,
                "prompts": prompts,
                "result": result,
            }
        )
    return out


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
        out.append(
            {
                "source": "V2",
                "id": sid,
                "title": clean(title, 90),
                "ts": (updated or created or 0) / 1000.0,
                "prompts": prompts,
                "result": result,
            }
        )
    return out


def label(s):
    title = s["title"] or ""
    if any(p in title.lower() for p in PLACEHOLDER_TITLES):
        if s["prompts"]:
            title = clean(s["prompts"][0], 60)
        else:
            title = clean(s["id"], 20)
    stamp = datetime.fromtimestamp(s["ts"]).strftime("%d %b %H:%M") if s["ts"] else "?"
    return "%s · %s · %s" % (stamp, s["source"], title)


def render(sessions):
    head = [
        "# RECENT — ringkasan sesi sebelumnya (auto-generate)",
        "",
        "> Dibuat otomatis oleh `~/.config/opencode/bin/session-digest.py`.",
        "> Jangan diedit manual; file ini ditimpa setiap kali opencode dibuka",
        "> atau setelah `memory_save`. Sumber: DB OpenCode V1 + V2.",
        "> Gunanya: sesi baru langsung tahu apa yang dibahas/diperintahkan",
        "> sebelumnya tanpa harus disuruh user mengingatkan.",
        "",
    ]
    body = []
    size = len("\n".join(head))
    for s in sessions:
        if not s["prompts"] and not s["result"]:
            continue
        block = ["## " + label(s)]
        for p in s["prompts"]:
            block.append("- User: " + p)
        if s["result"]:
            block.append("- Hasil: " + s["result"])
        block.append("")
        chunk = "\n".join(block)
        if size + len(chunk) > MAX_BYTES:
            break
        body.append(chunk)
        size += len(chunk)
    if not body:
        body = ["_(belum ada sesi tercatat)_", ""]
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
            print("lewati %s: %s" % (path, exc), file=sys.stderr)
        finally:
            db.close()

    cutoff = datetime.now().timestamp() - MAX_AGE_DAYS * 86400
    sessions = [s for s in sessions if (s["ts"] or 0) >= cutoff]
    sessions.sort(key=lambda s: s["ts"], reverse=True)
    sessions = sessions[:MAX_SESSIONS]

    text = render(sessions)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, OUT)
    print("%s (%d byte, %d sesi)" % (OUT, len(text.encode()), len(sessions)))


if __name__ == "__main__":
    main()
