// update-notice.js — surface `codemux update-check` results inside a session.
//
// The startup menu already prints an update line, but a long session (or one
// started from `opencode-v2 run`) never sees it. This plugin reads the cache
// that codemux writes (~/.config/codemux/update-cache.tsv) and injects a short
// notice into the system instructions of every model call, so the assistant can
// tell the user — in one line — that an update is waiting.
//
// DUAL COMPATIBLE (same file for V1 and V2):
//   - V2 registers the `context` session hook (runs before every model call).
//   - V1 registers `experimental.chat.system.transform`.
//
// Design rules:
//   - never throw / never block: any error means "no notice"
//   - the cache is re-read at most once a minute (cheap on a phone)
//   - a cache older than 48 hours is ignored (codemux refreshes it itself)
//   - nothing is downloaded here; the update stays an explicit `codemux upgrade`

import { readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const CACHE = join(homedir(), ".config", "codemux", "update-cache.tsv")
const TTL_MS = 60_000
const MAX_AGE_S = 48 * 3600

const LABELS = {
  codemux: "codemux",
  "opencode-v1": "OpenCode V1",
  "opencode-v2": "OpenCode V2",
  apt: "apt packages",
}

let memo = { at: 0, text: "" }

function buildNotice() {
  const age = Math.floor(Date.now() / 1000) - Math.floor(statSync(CACHE).mtimeMs / 1000)
  if (age > MAX_AGE_S) return ""

  const parts = []
  for (const line of readFileSync(CACHE, "utf8").split("\n")) {
    if (!line.trim() || line.startsWith("#")) continue
    const [component, local, latest, status] = line.split("\t")
    if (!component || status !== "update") continue
    const label = LABELS[component] ?? component
    if (component === "apt") parts.push(`${local ?? "?"} ${label}`)
    else parts.push(`${label} ${local || "?"} → ${latest || "?"}`)
  }
  if (!parts.length) return ""

  return [
    "[codemux] update available: " + parts.join(" · "),
    'Mention this once to the user in one short line (never repeat it in later replies) and say they can run `codemux upgrade` to install it. Nothing is downloaded automatically.',
  ].join("\n")
}

function notice() {
  const now = Date.now()
  if (now - memo.at < TTL_MS) return memo.text
  let text = ""
  try {
    text = buildNotice()
  } catch {
    text = ""
  }
  memo = { at: now, text }
  return text
}

export default {
  id: "update-notice",

  // V2: hook that runs before each model call of the agent loop.
  async setup(ctx) {
    if (typeof ctx?.session?.hook !== "function") return
    try {
      await ctx.session.hook("context", (event) => {
        const text = notice()
        if (text && Array.isArray(event?.system)) event.system.push({ type: "text", text })
      })
    } catch (error) {
      console.error("[update-notice] hook registration failed:", error?.message ?? error)
    }
  },

  // V1: same job through the classic hook table.
  async server() {
    return {
      "experimental.chat.system.transform": async (_input, output) => {
        const text = notice()
        if (text && Array.isArray(output?.system)) output.system.push(text)
      },
    }
  },
}
