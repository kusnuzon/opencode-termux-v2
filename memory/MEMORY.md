# MEMORY

Memori lintas sesi OpenCode. File ini dimuat otomatis setiap sesi lewat
`instructions` di `~/.config/opencode/opencode.jsonc`.

Aturan penulisan:
- satu fakta = satu baris, path absolut, tanpa basa-basi
- bagian `## Log` harus tetap di paling bawah, entri baru ditambahkan di akhir
- batas keras plugin `memory.js`: 24.000 byte (kalau lewat, `memory_save` gagal)
  → pangkas entri usang lebih dulu

> Ini file contoh/kosong. Isi dengan fakta milikmu: perangkat, path penting,
> preferensi, keputusan, dan hasil troubleshooting yang mungkin terulang.

## Environment
- (contoh) Sistem: Termux di Android aarch64, Python 3 di `$PREFIX/bin/python3`.

## Preferensi
- (contoh) Bahasa jawaban, tingkat detail, gaya kerja yang disukai.

## Log
- (contoh) [fact #tag] Satu fakta konkret beserta path absolutnya.
