# Catatan teknis: OpenCode V2 di Termux

Dokumen ini merekam semua jebakan yang ditemukan saat membuat OpenCode V2
berjalan di Termux (Android arm64), beserta solusinya. Berguna kalau ada
perubahan versi upstream yang memunculkan masalah serupa.

## 1. Binary glibc di Android

OpenCode V2 (sama seperti V1) adalah binary **glibc** yang di-bundle dengan
Bun. Android memakai **bionic**. Termux menyediakan glibc lewat paket terpisah:

```bash
pkg install glibc-repo glibc termux-exec-glibc
```

Hasilnya:

- Loader: `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`
- Library: `$PREFIX/glibc/lib`

Menjalankan binary:

```bash
$PREFIX/glibc/lib/ld-linux-aarch64.so.1 --library-path $PREFIX/glibc/lib ./opencode --version
```

### Jebakan: jangan export `LD_LIBRARY_PATH`

```bash
# JANGAN:
export LD_LIBRARY_PATH=$PREFIX/glibc/lib
```

Kalau variabel ini diekspor ke environment global, **semua** child process
bionic ikut mencari glibc dan gagal, contoh:

```
CANNOT LINK EXECUTABLE "tail": $PREFIX/glibc/lib/libc.so has bad ELF magic
```

Karena itu repo ini hanya memakai `--library-path` pada pemanggilan loader,
tanpa mengekspor `LD_LIBRARY_PATH`.

### Jebakan: `patchelf` merusak binary

`patchelf --set-interpreter` / `--set-rpath` pada binary Bun 209 MB
menghasilkan binary **rusak** (segfault saat dijalankan; file berubah ~185
juta byte). **Jangan pakai `patchelf`**.

### Jebakan: `LD_PRELOAD` bionic merusak proses glibc

Shell interaktif Termux menyetel:

```
LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so
```

Pustaka itu **bionic** (butuh `libc.so` + symbol versi `LIBC`). Loader glibc
juga menghormati `LD_PRELOAD`, jadi ia mencoba memuat pustaka bionic ke dalam
proses glibc dan gagal:

```
opencode.real: $PREFIX/glibc/lib/libc.so.6: version `LIBC' not found
  (required by $PREFIX/lib/libtermux-exec-ld-preload.so)
```

GLIBC_LD_PRELOAD punya masalah yang sama (loader Termux membacanya juga).

**Solusi**: buang `LD_PRELOAD` sebelum menjalankan binary glibc. Pola yang sama
dipakai helper native OpenCode V1 (`unsetenv("LD_PRELOAD")`) dan `glibc-runner`
resmi Termux (`unset LD_PRELOAD` di baris pertamanya). Fungsi
`sanitize_glibc_env()` di `lib/common.sh` melakukan ini, dan dipanggil di
launcher, `daemon_start`, serta `opencode_client`.

Varian **glibc** dari `libtermux-exec.so` (`$PREFIX/glibc/lib/libtermux-exec.so`)
**tidak boleh** dipakai sebagai pengganti: ia meng-interpose `execve`, tetapi
anak proses bionic tetap menerima `LD_PRELOAD` yang menunjuk pustaka glibc,
akibatnya:

```
CANNOT LINK EXECUTABLE "$PREFIX/bin/bash": library "libc.so.6" not found:
  needed by $PREFIX/glibc/lib/libtermux-exec.so in namespace (default)
```

Setelah `LD_PRELOAD` dibuang, anak proses bionic tetap normal: `exec` ke
binary bionic, script ber-shebang Termux, `git`, dan `/system/bin/sh` semuanya
berjalan (sudah diverifikasi).

## 2. `process.execPath` = path loader

V2 menjalankan background service dengan spawn `process.execPath`. Di Termux,
`process.execPath` bukan binary asli, melainkan:

```
/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
```

Akibatnya V2 selalu spawn:

```
execve(loader, ["serve", ...])
```

Yang membuat loader mencari shared library bernama `serve` → gagal:

```
serve: error while loading shared libraries: serve: cannot open shared object file
```

### Solusi: daemon dijalankan manual

Launcher di repo ini menjalankan daemon sendiri:

```bash
setsid "$LOADER" --library-path "$GLIBC_LIB" "$REAL" serve --service \
  >> "$SERVER_LOG" 2>&1 </dev/null &
```

Daemon mendaftarkan dirinya di `~/.opencode-v2/state/opencode/service.json`:

```json
{ "pid": 1234, "url": "http://127.0.0.1:PORT", "version": "2.1.2", ... }
```

Saat klien V2 dijalankan, ia mencari daemon terdaftar lebih dulu dan memakainya
→ **tidak ada spawn** → tidak ada anak process yang gagal.

### Jebakan: `service set disabled true`

Setting `disabled` memaksa V2 memakai mode *standalone* → memaksa spawn →
gagal. Pastikan:

```bash
opencode-v2 service set disabled false   # atau unset
```

Repo ini menjalankan daemon secara eksplisit sehingga mode ini tidak relevan.

## 3. Isolasi data V1 vs V2

V2 membaca lokasi data dari `XDG_DATA_HOME`, `XDG_STATE_HOME`,
`XDG_CACHE_HOME`. Variabel `OPENCODE_DB` hanya memengaruhi CLI (bukan server),
jadi tidak cukup untuk isolasi penuh.

Solusi di repo ini:

```bash
XDG_DATA_HOME=$HOME/.opencode-v2/data
XDG_STATE_HOME=$HOME/.opencode-v2/state
XDG_CACHE_HOME=$HOME/.opencode-v2/cache
```

Efeknya:

- Data V2 → `~/.opencode-v2/data/opencode/opencode.db`
- State V2 → `~/.opencode-v2/state/opencode/service.json`
- DB V1 → `~/.local/share/opencode/opencode.db` (tidak tersentuh)

Skema DB juga berbeda: V1 memakai tabel `session`, `part`, `message`; V2
memakai `session_v2`, `instruction_*`, `kv`. Karena itu **jangan pernah**
menyalin DB V1 ke V2.

## 4. Perbedaan API plugin

| | V1 | V2 |
|---|---|---|
| Entry point | `server()` pada default export | `setup(ctx)` pada default export |
| Registrasi tool | `tool: { nama: tool({...}) }` | `ctx.tool.transform(e => e.add({ name, description, input, execute }))` |
| Skema input | `tool.schema.string()` (Zod-like) | JSON Schema biasa |
| Hasil tool | `string` | `{ content: string }` |
| Hook compaction | `"experimental.session.compacting"` | `ctx.session.hook("compaction", ...)` → `event.system.push({ type: "text", text })` |

V2 memvalidasi hasil tool secara ketat: tool yang tidak mendeklarasikan skema
`output` **tidak boleh** mengembalikan `output` (crash dengan
`Tool result declared output without an output schema`). Selalu pakai
`content`.

## 5. Skill

`~/.agents/skills/<nama>/SKILL.md` tetap terdeteksi oleh V2 (auto-discovery),
sama seperti V1. Tidak perlu tindakan khusus.

## 6. Ukuran & disk

- Tarball npm `@opencode/cli-linux-arm64`: ±97 MB (kompresi).
- Binary hasil ekstrak: ±209 MB.
- Kebutuhan ruang: siapkan **≥ 400 MB** bebas selama instalasi.

Kalau disk mepet, hapus cache lama lebih dulu:

```bash
npm cache clean --force
pip cache purge
rm -rf $PREFIX/tmp/*
```

## 7. Diagnosa cepat

```bash
opencode-v2 doctor
cat ~/.opencode-v2/log/server.log
opencode-v2 service status
```

Kalau TUI tidak terbuka tetapi `opencode-v2 run "halo"` jalan, masalahnya ada di
lapisan tampilan (TERM/ICU), bukan di server.
