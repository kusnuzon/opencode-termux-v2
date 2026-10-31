// session-title.js — judul sesi otomatis TANPA memanggil model.
//
// Kenapa ada: di OpenCode V2 (2.1.3 ke atas) permintaan judul otomatis dikirim
// ke provider dengan bentuk "maintenance request", dan free tier menolaknya
// (403 FreeTierError / "Free usage limit reached"). Errornya dibuang diam-diam
// sehingga sesi tetap tanpa judul. Bukti di DB: 2.1.2 = semua sesi berjudul,
// 2.1.3/2.1.4 = 0 berjudul. Issue upstream: anomalyco/opencode#58176.
//
// Plugin ini memakai hook V2 `session.hook("title", ...)`: kalau hook mengisi
// `event.result`, OpenCode memakai string itu sebagai judul dan TIDAK mengirim
// request ke model sama sekali. Jadi judul diambil dari pesan pertama user.
//
// Kalau upstream sudah memperbaiki bug-nya dan ingin judul versi AI lagi,
// cukup hapus/rename file ini.

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

// Buang bagian yang tidak informatif untuk judul.
function clean(text) {
  let t = String(text ?? "")
  t = t.replace(/```[\s\S]*?```/g, "\n") // blok kode berpagar
  t = t.replace(/~~~[\s\S]*?~~~/g, "\n")
  t = t.replace(/<[^>]{1,500}>/g, " ") // tag HTML
  t = t.replace(/https?:\/\/\S+/g, " ") // URL
  t = t.replace(/`([^`]*)`/g, "$1") // inline code → isinya
  t = t.replace(/\s+/g, " ") // rapikan spasi
  return t
}

// Hook V2 mengirim prompt judul yang sudah dirender, isinya:
//   Here is the first message of the conversation:
//   <message>"pesan user"</message>
//   Reply with only the title.
// Ambil isi <message> pertama (permintaan asli), bukan instruksi wrapper-nya.
function messageBlocks(text) {
  const blocks = []
  const re = /<message>([\s\S]*?)<\/message>/g
  let match
  while ((match = re.exec(String(text ?? ""))) !== null) blocks.push(match[1])
  return blocks
}

// Cadangan: kalau tidak ada <message>, ambil bagian teks dari `messages`.
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
  // buang tanda kutip pembungkus (prompt judul membungkus pesan dengan kutip)
  t = t.replace(/^["'“”‘’]+/, "").replace(/["'“”‘’]+$/, "").trim()
  // buang tanda baca penutup berlebihan
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
  if (!list.length) return "Sesi baru"

  // lewati sapaan pembuka ("halo", "pagi") kalau masih ada baris lain
  const useful = list.filter((line) => !GREETINGS.has(line.toLowerCase().replace(/[^a-z ]/g, "").trim()))
  const line = useful[0] ?? list[0]
  return trimTitle(line) || "Sesi baru"
}

export default {
  id: "session-title",

  // V1 mewajibkan default export punya server(); V1 sudah membuat judul
  // sendiri, jadi tidak ada hook yang perlu dipasang.
  async server() {
    return {}
  },

  // V2 saja: API plugin V1 tidak punya ctx.session.hook.
  async setup(ctx) {
    if (typeof ctx?.session?.hook !== "function") return
    try {
      await ctx.session.hook("title", async (event) => {
        try {
          if (!event) return
          if (typeof event.result === "string" && event.result.trim()) return
          // Di hook V2 `event.text` kosong; teks prompt ada di `event.messages`.
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
          console.error("[session-title] gagal membuat judul:", error?.message ?? error)
        }
      })
    } catch (error) {
      console.error("[session-title] hook title gagal dipasang:", error?.message ?? error)
    }
  },
}
