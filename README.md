# Upscale · Finance Monitoring

Sistem revenue management internal Upscale House Project (PT Upscale Digital Indonesia): faktur penjualan, penerimaan & PPh, proyeksi revenue (basis faktur & akrual), proyeksi cash in, penagihan piutang, komisi BD/AM, buku bank, laporan yang bisa dikustom, log aktivitas.

**Stack:** satu aplikasi web statis (`index.html`, vanilla JS) + Supabase (Auth, Postgres + RLS, Realtime, Edge Function). Di-host lewat GitHub Pages.

## Struktur
- `index.html` — aplikasi (UI, logika bisnis, lapisan sinkronisasi Supabase di bagian bawah file)
- `supabase/migrations/0001_init.sql` — skema: tabel dokumen per koleksi (`id` + `data jsonb` + kolom turunan), `settings`, `profiles`, `activity_log`, RLS per peran
- `supabase/migrations/0002_realtime.sql` — publikasi realtime
- `supabase/functions/admin-users` — Edge Function untuk Master kelola akun (buat, ganti sandi, aktif/nonaktif, peran, hapus)

## Peran
| Peran | Hak |
|---|---|
| Master | semua + pengaturan & akun |
| Finance | semua transaksi & laporan |
| Accounting | hanya lihat |

Login memakai nama pengguna + kata sandi (internal dipetakan ke `username@upscale.local` di Supabase Auth). Tidak ada pendaftaran mandiri.

## Cara kerja data
Aplikasi memuat semua koleksi saat masuk, menyimpan perubahan lewat *diff-upsert* (hanya dokumen yang berubah), dan menerima perubahan dari pengguna lain lewat Realtime. Log aktivitas append-only di server. Semua pembatalan bersifat *soft* (status `void` / `cancelled` / `pcancel`) dan bisa diaktifkan kembali; dokumen menyimpan versi sebelumnya.

## Pengembangan
Buka `index.html` lewat server statis apa pun (mis. `python3 -m http.server`). Tes logika: jalankan `runTests()` di konsol browser setelah masuk.

## Deploy
Repo privat (GitHub Pages tidak tersedia di plan gratis untuk repo privat), jadi aplikasi disajikan dari Supabase sendiri:
- `index.html` diunggah ke Storage bucket `app` (hanya Master yang boleh unggah) — `./deploy.sh <username-master> <sandi>`
- Edge Function `app` menyajikannya sebagai `text/html` → **https://vfffkwayrjepacmbasmo.supabase.co/functions/v1/app**
- Proyek Supabase: `upscale-finance-monitoring` (ap-southeast-1). Skema di `supabase/migrations`, fungsi di `supabase/functions`.
