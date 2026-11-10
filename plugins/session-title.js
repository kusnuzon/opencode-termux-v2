// session-title.js — automatic session titles WITHOUT calling a model.
//
// Why this exists: in OpenCode V2 (2.1.3 and above) the automatic title request
// is sent to the provider as a "maintenance request", and the free tier rejects
// it (403 FreeTierError / "Free usage limit reached"). The error is swallowed
// silently, so sessions end up without a title. Evidence from the DB: 2.1.2 =
// every session titled, 2.1.3/2.1.4 = 0 titled. Upstream issue:
// anomalyco/opencode#58176.
//
// This plugin uses the V2 hook `session.hook("title", ...)`: when the hook fills
// in `event.result`, OpenCode uses that string as the title and does NOT send a
// request to the model at all. So the title comes from the user's first message.
//
// If upstream fixes the bug and you want AI-generated titles again, just
// delete/rename this file.

const MAX_CHARS = 48
const GREETINGS = new Set([
  "halo",
  "hallo",
  "hai",
  "hi",
  "hey",
  "hello",
  "pagi",
  "siang",
  "sore",
  "malam",
  "ping",
  "tes",
  "test",
  "ok",
  "oke",
])

// Remove parts that are not useful for a title.
function clean(text) {
  let t = String(text ?? "")
  t = t.replace(/```[\s\S]*?```/g, "\n") // fenced code blocks
  t = t.replace(/~~~[\s\S]*?~~~/g, "\n")
  t = t.replace(/<[^>]{1,500}>/g, " ") // HTML tags
  t = t.replace(/https?:\/\/\S+/g, " ") // URLs
  t = t.replace(/`([^`]*)`/g, "$1") // inline code → its content
  t = t.replace(/\s+/g, " ") // collapse whitespace
  return t
}

// The V2 hook sends a rendered title prompt, which looks like:
//   Here is the first message of the conversation:
//   <message>"user message"</message>
//   Reply with only the title.
// Take the content of the first <message> (the real request), not the wrapper's
// instructions.
function messageBlocks(text) {
  const blocks = []
  const re = /<message>([\s\S]*?)<\/message>/g
  let match
  while ((match = re.exec(String(text ?? ""))) !== null) blocks.push(match[1])
  return blocks
}

// Fallback: when there is no <message>, take the text parts from `messages`.
function textFromMessages(messages) {
  const out = []
  for (const message of Array.isArray(messages) ? messages : []) {
    const content = message?.content ?? message?.parts
    if (typeof content === "string") out.push(content)
    else if (Array.isArray(content))
      for (const part of content) if (typeof part?.text === "string") out.push(part.text)
    if (!content && typeof message?.text === "string") out.push(message.text)
  }
  return out.join("\n")
}

function stripLead(line) {
  let t = String(line ?? "").trim()
  t = t.replace(/^["'“”‘’]+/, "")
  t = t.replace(/^[>*#\-–—•]+\s*/, "")
  t = t.replace(/^\d+[.)]\s+/, "")
  t = t.replace(/^["'“”‘’]+/, "").trim()
  return t
}

function candidates(text) {
  const raw = String(text ?? "")
  const lines = raw
    .split(/\r?\n/)
    .map((line) => stripLead(clean(line)))
    .filter((line) => line.length >= 2)
  const firstLine = stripLead(clean(raw))
  if (firstLine) lines.unshift(firstLine)
  return lines
}

function trimTitle(line) {
  let t = line.replace(/\s+/g, " ").trim()
  if (!t) return ""
  // drop wrapping quotes (the title prompt wraps the message in quotes)
  t = t.replace(/^["'“”‘’]+/, "").replace(/["'“”‘’]+$/, "").trim()
  // drop trailing punctuation that carries no meaning
  t = t.replace(/[.,;:!?]+$/, "")
  if (t.length > MAX_CHARS) {
    const cut = t.slice(0, MAX_CHARS)
    const space = cut.lastIndexOf(" ")
    t = (space > 20 ? cut.slice(0, space) : cut).trim() + "…"
  }
  return t.charAt(0).toUpperCase() + t.slice(1)
}

function makeTitle(text) {
  const list = candidates(text)
  if (!list.length) return "New session"

  // skip an opening greeting ("halo", "pagi") while another line is available
  const useful = list.filter((line) => !GREETINGS.has(line.toLowerCase().replace(/[^a-z ]/g, "").trim()))
  const line = useful[0] ?? list[0]
  return trimTitle(line) || "New session"
}

export default {
  id: "session-title",

  // V1 requires the default export to have server(); V1 already creates titles
  // itself, so there is no hook to install.
  async server() {
    return {}
  },

  // V2 only: the V1 plugin API has no ctx.session.hook.
  async setup(ctx) {
    if (typeof ctx?.session?.hook !== "function") return
    try {
      await ctx.session.hook("title", async (event) => {
        try {
          if (!event) return
          if (typeof event.result === "string" && event.result.trim()) return
          // In the V2 hook `event.text` is empty; the prompt text is in `event.messages`.
          const raw = event.text ?? textFromMessages(event.messages)
          const blocks = messageBlocks(raw)
          const source = blocks.length ? blocks[0] : raw
          if (process.env.OPENCODE_TITLE_DEBUG)
            console.error(
              "[session-title] keys=" +
                Object.keys(event).join(",") +
                " blocks=" +
                blocks.length +
                " hasTag=" +
                String(raw).includes("<message>") +
                " source=" +
                JSON.stringify(String(source).slice(0, 120)),
            )
          const title = makeTitle(source)
          if (title) event.result = title
        } catch (error) {
          console.error("[session-title] failed to build the title:", error?.message ?? error)
        }
      })
    } catch (error) {
      console.error("[session-title] failed to install the title hook:", error?.message ?? error)
    }
  },
}
