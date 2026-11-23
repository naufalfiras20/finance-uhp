-- Peran Staff (pengaju budget). Dipisah karena nilai enum baru tidak boleh dipakai di transaksi yang sama.
alter type public.app_role add value if not exists 'staff';
