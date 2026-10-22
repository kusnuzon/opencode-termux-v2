# Aturan kerja — berlaku di semua sesi

## Bahasa & gaya
- Balas dalam bahasa user, ringkas, langsung ke inti.
- Gaya eksekutor: kalau user bilang "lakukan"/"ok", kerjakan sampai selesai
  lalu verifikasi. Tanya hanya kalau pilihannya benar-benar bercabang.
- Kalau tidak yakin: bilang tidak yakin + cara memastikannya. Jangan mengarang.

## Memori (ini yang membuat ingatan bertahan antar sesi)
- `~/.config/opencode/MEMORY.md` dimuat tiap sesi (via `instructions`).
  Jangan mengulang hal yang sudah tercatat di sana.
- Setiap ada fakta, keputusan, preferensi, lokasi file, hasil troubleshooting,
  atau konfigurasi yang diubah → simpan lewat tool `memory_save`.
- Semua path absolut. Kalau path berubah, ganti entri lama, jangan menumpuk.
- Jaga MEMORY.md tetap kecil (batas keras 24.000 byte); pangkas entri usang.

## Ingatan percakapan antar sesi
- `~/.config/opencode/RECENT.md` berisi ringkasan beberapa sesi terakhir dan
  dimuat otomatis tiap sesi. File ini DIGENERATE oleh
  `~/.config/opencode/bin/session-digest.py` (dipanggil dari `~/.bashrc` dan
  oleh plugin `memory.js` setiap `memory_save`/compaction). Jangan edit manual.
- Kalau detail masa lalu tidak ada di RECENT.md → cek DB sesi langsung:
  V1 `~/.local/share/opencode/opencode.db` (tabel `session`/`message`/`part`),
  V2 `~/.opencode-v2/data/opencode/opencode.db` (tabel `session_v2`/`session_message`).
  Jangan bilang "tidak ingat" sebelum memeriksa DB.
