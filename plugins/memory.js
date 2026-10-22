// memory.js — shared memory lintas sesi untuk OpenCode.
//
// Dua tanggung jawab:
//   1. tool `memory_save`  → menulis fakta/keputusan ke MEMORY.md (selalu jadi
//      instructions di opencode.jsonc, jadi terbaca di sesi berikutnya).
//   2. hook compaction     → menyuruh model memindahkan state penting ke
//      MEMORY.md sebelum context dikompres, supaya compaction tidak
//      menghilangkan hasil kerja sesi itu.
//
// File ini DUAL-COMPATIBLE (OpenCode V1 dan V2 memakai file yang sama):
//   - V2 (>= 2.x) memanggil `setup(ctx)` — API plugin V2.
//   - V1 (>= 1.18.29) membaca default export dan memanggil `server()` — API V1.
// Keduanya mendaftarkan tool dengan nama yang sama, jadi tool tidak bentrok.
//
// Format MEMORY.md: judul "# MEMORY" di baris pertama, lalu section "## Log"
// sebagai section terakhir. Entri baru selalu menempel di akhir file (bagian
// Log). Batas keras MAX_BYTES supaya file tidak membengkak dan memakan context.

import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

const MEMORY = join(homedir(), ".config", "opencode", "MEMORY.md")
const MAX_BYTES = 24000

// Ringkasan sesi terakhir (RECENT.md) dibuat ulang lewat script ini setiap
// memory_save / sebelum compaction / saat opencode dibuka dari ~/.bashrc.
const DIGEST_SCRIPT = join(homedir(), ".config", "opencode", "bin", "session-digest.py")

async function refreshDigest() {
  if (!existsSync(DIGEST_SCRIPT)) return
  try {
    const { spawn } = await import("node:child_process")
    const child = spawn("python3", [DIGEST_SCRIPT], { detached: true, stdio: "ignore" })
    child.on("error", () => {})
    child.unref()
  } catch (error) {
    console.error("[memory] gagal segarkan RECENT.md:", error?.message ?? error)
  }
}

const TOOL_DESCRIPTION =
  "Simpan satu fakta ke memori permanen lintas sesi (MEMORY.md). Dipanggil setelah kamu menyelesaikan sesuatu yang perlu diingat di chat berikutnya: keputusan, preferensi user, lokasi file, hasil troubleshooting, atau konfigurasi yang diubah. Jangan dipakai untuk isi transient percakapan."

const ENTRY_DESC = "Satu fakta atau keputusan, konkret dan singkat. Path absolut dan angka ikut ditulis."
const KIND_DESC = "Jenis memori, default: fact"
const TAGS_DESC = "Label pendek untuk cari nanti, mis. setup, vault, termux"
const KINDS = ["fact", "decision", "preference", "gotcha", "config"]

const COMPACT_PROMPT = [
  "## Persistensi memori (wajib sebelum context dikompres)",
  "",
  "Panggil tool `memory_save` untuk hal-hal yang harus bertahan setelah compaction:",
  "- keputusan yang baru diambil dan alasannya",
  "- file/konfigurasi yang diubah (path absolut)",
  "- hasil troubleshooting yang mungkin terulang",
  "- pekerjaan yang belum selesai dan langkah berikutnya",
  "",
  "Maksimal 3 entri, hanya yang tidak akan terderivasi ulang dari isi file.",
].join("\n")

// --- inti (dipakai V1 dan V2) ----------------------------------------------
function readMemory() {
  if (!existsSync(MEMORY)) return ""
  return readFileSync(MEMORY, "utf8")
}

function writeMemory(text) {
  mkdirSync(dirname(MEMORY), { recursive: true })
  writeFileSync(MEMORY, text.endsWith("\n") ? text : text + "\n")
}

function appendLog(body) {
  let text = readMemory()
  if (!text.trim()) {
    writeMemory("# MEMORY\n\n## Log\n\n" + body)
    return
  }
  if (!text.startsWith("# MEMORY")) text = "# MEMORY\n\n" + text
  if (!text.includes("## Log")) text = text.trimEnd() + "\n\n## Log\n\n"
  text = text.trimEnd() + "\n" + body
  writeMemory(text)
}

// saveEntry — dipakai kedua API. Melempar Error kalau gagal.
function saveEntry(args) {
  const entry = String(args?.entry ?? "").trim()
  if (!entry) throw new Error("entry kosong")

  const current = readMemory()
  if (current.includes(entry)) return "Sudah tercatat di MEMORY.md, duplikat dilewati: " + entry

  if (current && statSync(MEMORY).size + entry.length > MAX_BYTES)
    throw new Error(
      `MEMORY.md sudah ${statSync(MEMORY).size} byte (batas ${MAX_BYTES}). Pangkas entri usang lebih dulu agar file tetap murah dimuat setiap sesi.`,
    )

  const date = new Date().toISOString().slice(0, 10)
  const tags = (args?.tags ?? []).filter(Boolean).map((t) => " #" + t)
  const kind = KINDS.includes(args?.kind) ? args.kind : "fact"
  appendLog(`- (${date}) [${kind}${tags.join("")}] ${entry}`)
  void refreshDigest()

  const lines = readMemory().split("\n").length
  return `Tersimpan di MEMORY.md (${lines} baris, ${statSync(MEMORY).size} byte): ${entry}`
}

// --- API V2 -----------------------------------------------------------------
const V2_INPUT = {
  type: "object",
  properties: {
    entry: { type: "string", description: ENTRY_DESC },
    kind: { type: "string", enum: KINDS, description: KIND_DESC },
    tags: { type: "array", items: { type: "string" }, description: TAGS_DESC },
  },
  required: ["entry"],
  additionalProperties: false,
}

// --- API V1 -----------------------------------------------------------------
// helper `tool` hanya ada di paket V1 ("@opencode-ai/plugin"), jadi diimpor
// dinamis di dalam server() — V2 tidak pernah memanggil bagian ini.
async function v1Hooks() {
  const mod = await import("@opencode-ai/plugin").catch(() => null)
  const tool = mod?.tool
  if (!tool) return {}
  return {
    tool: {
      memory_save: tool({
        description: TOOL_DESCRIPTION,
        args: {
          entry: tool.schema.string().describe(ENTRY_DESC),
          kind: tool.schema.enum(KINDS).optional().describe(KIND_DESC),
          tags: tool.schema.array(tool.schema.string()).optional().describe(TAGS_DESC),
        },
        async execute(args) {
          return saveEntry(args)
        },
      }),
    },
    "experimental.session.compacting": async (_input, output) => {
      output.context.push(COMPACT_PROMPT)
      void refreshDigest()
    },
  }
}

// --- default export (dipakai V1 & V2) --------------------------------------
export default {
  id: "memory",

  // V2: dipanggil oleh plugin host V2.
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      editor.add({
        name: "memory_save",
        description: TOOL_DESCRIPTION,
        input: V2_INPUT,
        async execute(input) {
          // V2: tool wajib mengembalikan { content } (bukan { output }) kalau
          // tool tidak mendeklarasikan skema output.
          return { content: saveEntry(input) }
        },
      })
    })

    try {
      await ctx.session.hook("compaction", async (event) => {
        if (Array.isArray(event?.system)) event.system.push({ type: "text", text: COMPACT_PROMPT })
        void refreshDigest()
      })
    } catch (error) {
      console.error("[memory] hook compaction gagal:", error?.message ?? error)
    }
  },

  // V1: dipanggil oleh plugin host V1.
  async server() {
    return await v1Hooks()
  },
}
