# Migrasi dari OpenCode V1 ke V2 (di Termux)

Dokumen ini menjelaskan apa yang berubah, apa yang tetap sama, dan bagaimana
menjalankan V1 dan V2 berdampingan dengan aman.

## Ringkasan

| Aspek | V1 (`opencode`) | V2 (`opencode-v2`) |
|---|---|---|
| Versi | 1.19.x | 2.x |
| Format binary | glibc ELF (Bun) | glibc ELF (Bun) |
| Paket npm | `opencode-ai` | `@opencode/cli` + `@opencode/cli-linux-arm64` |
| Plugin API | `server()` | `setup()` |
| Tool result | `string` | `{ content: string }` |
| Hook compaction | `experimental.session.compacting` | `session.hook("compaction", ...)` |
| Skema DB | `session`, `part`, `message` | `session_v2`, `instruction_*`, `kv` |

Kedua versi **tidak boleh berbagi database**. Repo ini otomatis mengarahkan V2
ke `~/.opencode-v2/` sehingga DB V1 (`~/.local/share/opencode/opencode.db`)
tidak pernah disentuh.

## Yang tetap dipakai bersama

- `~/.config/opencode/opencode.jsonc` — konfigurasi global (model, provider,
  izin, `instructions`).
- `~/.config/opencode/MEMORY.md` — memori lintas sesi.
- `~/.config/opencode/plugins/` — plugin.
- `~/.agents/skills/` — skill.
- `~/.local/share/opencode/auth.json` — kredensial provider (dipakai V2 juga,
  karena direktori config & auth masih milik global OpenCode).

## Plugin `memory.js` yang sekarang dual-compatible

Dulu plugin ini hanya jalan di V1:

```js
import { tool } from "@opencode-ai/plugin"
export const MemoryPlugin = async () => ({ tool: { memory_save: tool({...}) } })
```

Sekarang satu file dipakai V1 **dan** V2:

```js
export default {
  id: "memory",
  async setup(ctx) {           // dipanggil V2
    await ctx.tool.transform((editor) => {
      editor.add({ name: "memory_save", description, input, async execute(input) {
        return { content: simpan(input) }   // V2: content, bukan output
      }})
    })
    await ctx.session.hook("compaction", async (event) => {
      event.system.push({ type: "text", text: PETUNJUK_COMPACT })
    })
  },
  async server() {             // dipanggil V1
    const { tool } = await import("@opencode-ai/plugin")
    return { tool: { memory_save: tool({...}) }, "experimental.session.compacting": ... }
  },
}
```

Kenapa bisa berdua:

- V1 (>= 1.18.29) membaca **default export**; kalau objeknya punya `server()`,
  V1 memanggil `server()` dan mengabaikan export lain.
- V2 membaca **default export**; yang dipakai field `id` + `setup()`. Field
  `server()` diabaikan oleh V2.
- Helper `tool` milik V1 hanya diimpor secara **dinamis** di dalam `server()`,
  sehingga tidak pernah dipecah saat V2 memuat modul.

Kalau plugin lama (V1-only) dibiarkan di folder plugin, V2 akan memuatnya juga
dan gagal: V2 mencari `setup()`, tidak menemukan → plugin diabaikan/error.
Karena itu file tunggal dual-compatible adalah pilihan paling aman.

### Perbedaan penting hasil tool di V2

V2 memvalidasi hasil tool:

- Tool **tanpa** skema `output` → hasil **harus** pakai `content`
  (string atau array `{ type: "text", text }`).
- Mengembalikan `output` tanpa skema output → error
  `Tool result declared output without an output schema` (proses *crash*, bukan
  error biasa).

Jadi `execute` di V2 mengembalikan:

```js
return { content: "Tersimpan di MEMORY.md (...)" }
```

## Perbedaan konfigurasi V2

- `tui.json` → `cli.json`.
- `experimental.todo` mati secara default di V2 → aktifkan bila dipakai:

  ```jsonc
  { "experimental": { "todo": true } }
  ```

- LSP **tidak didukung** di V2 (fitur V1).
- `external_directory` default-nya *allowed* di V2 (lebih longgar dari V1).

## Persiapan sebelum memasang V2

1. Pastikan disk lega: binary V2 ±209 MB + tarball sementara ±100 MB
   → siapkan **≥ 400 MB** bebas.
2. Pastikan runtime glibc siap (installer juga melakukan ini otomatis):

   ```bash
   pkg install glibc-repo glibc termux-exec-glibc
   ```

3. Catat versi V1 yang dipakai:

   ```bash
   opencode --version
   ```

## Urutan yang aman

```bash
# 1. pasang V2 (V1 tidak disentuh)
curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/install.sh | bash

# 2. cek
opencode-v2 doctor
opencode-v2 --version

# 3. pakai
opencode-v2
```

## Rollback

Kalau V2 bermasalah, V1 tetap bisa dipakai karena database, state, dan
perintahnya terpisah:

```bash
opencode          # V1 normal
```

Menghapus V2 sepenuhnya:

```bash
opencode-v2 uninstall            # atau: uninstall.sh
opencode-v2 uninstall --purge    # sekalian data/sesi/log
```
