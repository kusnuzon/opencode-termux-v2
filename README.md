# OpenCode V2 untuk Termux (Android arm64)

Installer satu-perintah untuk **OpenCode V2** — versi 2.x dari
[anomalyco/opencode](https://github.com/anomalyco/opencode) — di Termux di
Android (aarch64/arm64).

OpenCode V2 adalah CLI AI open-source untuk terminal: agent yang bisa membaca
& menulis file, menjalankan perintah, mencari di web, memakai MCP server, dan
bekerja lewat sesi. Repo ini membuat V2 **bisa dipakai di Termux**, di mana
Android tidak punya glibc secara default.

> Repo ini tidak berafiliasi dengan proyek opencode resmi. Yang diambil hanya
> payload binary resmi dari registry npm (`@opencode/cli-linux-arm64`).

---

## Pasang (satu perintah)

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh | bash
```

Selesai. Perintah `opencode-v2` langsung bisa dipakai.

> Kenapa lewat API GitHub, bukan `raw.githubusercontent.com`? Beberapa jaringan
> (terutama seluler) menyimpan `raw.githubusercontent.com` di cache proxy
> berjam-jam — file yang diunduh bisa versi lama. API GitHub selalu segar.
> Alternatif raw (bisa terlambat beberapa menit):
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/install.sh | bash
> ```

Atau dari clone repo:

```bash
git clone https://github.com/kusnuzon/opencode-termux-v2
cd opencode-termux-v2
./install.sh
```

## Perintah yang tersedia

| Perintah | Fungsi |
|---|---|
| `opencode-v2` | Mode interaktif (TUI) |
| `opencode-v2 run "prompt"` | Sekali jalan, tanpa TUI |
| `opencode-v2 service status` | Status background service |
| `opencode-v2 service start\|stop\|restart` | Kelola background service |
| `opencode-v2 doctor` | Diagnosis lengkap (layanan, plugin, disk, versi) |
| `opencode-v2 upgrade` | Perbarui ke versi terbaru |
| `opencode-v2 --version` | Cek versi terpasang |

## Yang dikerjakan installer

1. Memastikan runtime glibc Termux (`glibc-repo`, `glibc`, `termux-exec-glibc`).
2. Mengunduh payload resmi `@opencode/cli-linux-arm64` (~100 MB) dari registry
   npm, **memverifikasi checksum sha512** dari metadata registry.
3. Mengekstrak binary ke `$PREFIX/share/opencode-v2/opencode.real`.
4. Memasang launcher `$PREFIX/bin/opencode-v2`.
5. Memasang plugin `memory_save` ke `~/.config/opencode/plugins/memory.js`
   (file yang sama dipakai V1 — dual-compatible).
6. Menyalakan background service + smoke test, dengan rollback otomatis bila
   ada langkah yang gagal.

## Memori antar sesi (`--with-memory`)

Repository ini **tidak menyimpan** memori pribadi siapa pun. Yang ada hanya
mekanismenya; isi memori tetap di perangkatmu.

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh | bash -s -- --with-memory
```

Yang dipasang (file yang **sudah ada tidak ditimpa**):

| File | Isi |
|---|---|
| `memory/MEMORY.md` → `~/.config/opencode/MEMORY.md` | template kosong, diisi lewat tool `memory_save` |
| `memory/AGENTS.md` → `~/.config/opencode/AGENTS.md` | template aturan kerja |
| `memory/opencode.jsonc` → `~/.config/opencode/opencode.jsonc` | `instructions`: MEMORY.md + RECENT.md |
| `plugins/session-digest.py` → `~/.config/opencode/bin/` | pembuat `RECENT.md` dari DB sesi V1 + V2 |
| hook `~/.bashrc` | menyegarkan `RECENT.md` tiap `opencode`/`opencode-v2` dibuka |

Hasilnya: `MEMORY.md` menyimpan fakta jangka panjang, `RECENT.md` menyimpan
ringkasan beberapa sesi terakhir, dan keduanya dimuat otomatis di awal sesi
baru — tanpa data pribadi ikut ke GitHub.

> Memori lama di perangkat tidak hilang: installer melewati file yang sudah ada.
> Untuk backup, simpan `~/.config/opencode/` sendiri (mis. di repo privat).

## Kenapa butuh hacks?

V2 adalah binary **glibc** (Bun). Android memakai **bionic**. Termux menyediakan
glibc lewat paket `glibc-repo`, jadi binary cukup dijalankan lewat loader:

```bash
$PREFIX/glibc/lib/ld-linux-aarch64.so.1 --library-path $PREFIX/glibc/lib ./opencode
```

Masalah kedua lebih halus: **V2 selalu menjalankan background service dengan
cara spawn `process.execPath`**. Di Termux, `process.execPath` adalah *path
loader*, bukan binary asli, sehingga proses anak selalu gagal:

```
serve: error while loading shared libraries: serve: cannot open shared object file
```

Solusi di repo ini: **launcher menyalakan daemon `opencode serve --service`
sendiri** (lewat loader), lalu daemon mendaftarkan diri di
`~/.opencode-v2/state/opencode/service.json`. Klien V2 menemukan daemon
terdaftar itu dan **tidak pernah melakukan spawn** → tidak ada anak yang gagal.

## Isolasi dari OpenCode V1

V1 dan V2 boleh berdampingan. `opencode-v2` memakai direktori sendiri:

| | OpenCode V1 | OpenCode V2 |
|---|---|---|
| Perintah | `opencode` | `opencode-v2` |
| Database | `~/.local/share/opencode/` | `~/.opencode-v2/data/opencode/` |
| State | `~/.local/state/opencode/` | `~/.opencode-v2/state/opencode/` |
| Cache | `~/.cache/opencode/` | `~/.opencode-v2/cache/opencode/` |
| Log | `~/.local/share/opencode/log/` | `~/.opencode-v2/log/server.log` |

Konfigurasi global (`~/.config/opencode/opencode.jsonc`), skill
(`~/.agents/skills`), dan plugin **dipakai bersama** — jadi provider, model,
izin (permission), dan memori tetap sama untuk keduanya.

## Plugin memory (memori lintas sesi)

`~/.config/opencode/plugins/memory.js` sekarang **dual-compatible**: V1
memanggil `server()`, V2 memanggil `setup()`. Satu file, dua versi, tool
`memory_save` tetap ada di keduanya.

Plugin ini menulis ke `~/.config/opencode/MEMORY.md` (file yang sudah jadi
`instructions` di config), dan memasang hook *compaction* supaya model
memindahkan nilai penting ke memori sebelum context dikompres.

Dokumentasi lengkap: [`docs/MIGRATION-V1.md`](docs/MIGRATION-V1.md).

## Pemecahan masalah

```bash
opencode-v2 doctor        # cek semuanya
cat ~/.opencode-v2/log/server.log
```

Masalah yang sering muncul:

| Gejala | Penyebab & solusi |
|---|---|
| `error while loading shared libraries` | Runtime glibc belum ada: `pkg install glibc-repo glibc termux-exec-glibc` |
| `version 'LIBC' not found (required by .../libtermux-exec-ld-preload.so)` | Shell Termux menyetel `LD_PRELOAD` ke pustaka bionic; loader glibc ikut memuatnya dan gagal. Launcher versi ini membuang `LD_PRELOAD` otomatis — `opencode-v2 upgrade` |
| `libc.so: invalid ELF header` | Shim pustaka hilang — `opencode-v2 upgrade` (atau `install.sh`) membuat symlink `libc.so -> libc.so.6` di `$PREFIX/share/opencode-v2/lib/compat` |
| `serve: error while loading shared libraries` | Daemon belum terdaftar — `opencode-v2 service restart` |
| `Tool result declared output without an output schema` | Plugin tool mengembalikan `output` tanpa skema output — di V2 balik `content` |
| TUI tidak bisa dibuka | `opencode-v2 run "halo"` untuk memastikan server sehat |

Detail arsitektur & catatan teknis: [`docs/TERMUX.md`](docs/TERMUX.md).

## Uninstall

```bash
bash <(curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/uninstall.sh)
```

Tambahkan `--purge` untuk ikut menghapus data/sesi/log V2. OpenCode V1 tidak
disentuh. Jika V2 sudah terpasang, lebih mudah: `opencode-v2 uninstall`.

## Lisensi

MIT — lihat [LICENSE](LICENSE).
