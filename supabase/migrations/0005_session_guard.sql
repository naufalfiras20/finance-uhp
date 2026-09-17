-- Satu sesi aktif per akun: session_id ditulis ulang tiap login; perangkat lama mendeteksi lewat Realtime dan dipaksa keluar.
alter table public.profiles add column if not exists session_id text;
alter table public.profiles add column if not exists session_started_at timestamptz;
alter publication supabase_realtime add table public.profiles;
