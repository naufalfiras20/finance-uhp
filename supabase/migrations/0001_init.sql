-- Upscale Finance Monitoring · skema v1
-- Pola: tiap koleksi = tabel dokumen (id text + data jsonb) dengan kolom turunan (diisi trigger) untuk query & constraint.
-- Logika bisnis (kalkulasi faktur, komisi, akrual, proyeksi) hidup di aplikasi; DB menjaga akses (RLS), audit, dan konsistensi dasar.

create type app_role as enum ('master','finance','accounting');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  name text not null,
  role app_role not null default 'accounting',
  active boolean not null default true,
  prefs jsonb not null default '{"lang":"id","theme":"auto"}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.app_role() returns app_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;
create or replace function public.can_write() returns boolean language sql stable as $$ select public.app_role() in ('master','finance') $$;
create or replace function public.is_master() returns boolean language sql stable as $$ select public.app_role() = 'master' $$;

-- kolom turunan + jejak ubah
create or replace function public._doc_touch() returns trigger language plpgsql as $$
begin
  new.status := new.data->>'status';
  new.cust := new.data->>'cust';
  new.doc_date := nullif(new.data->>'date','')::date;
  new.doc_month := left(coalesce(new.data->>'date',''),7);
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

create or replace function public._mk_doc_table(t text) returns void language plpgsql as $$
begin
  execute format($f$
    create table public.%1$I (
      id text primary key,
      data jsonb not null,
      status text,
      cust text,
      doc_date date,
      doc_month text,
      updated_at timestamptz not null default now(),
      updated_by uuid references auth.users(id)
    );
    create index on public.%1$I (doc_date);
    create index on public.%1$I (cust);
    create index on public.%1$I (status);
    create trigger touch before insert or update on public.%1$I for each row execute function public._doc_touch();
    alter table public.%1$I enable row level security;
    create policy "read authenticated" on public.%1$I for select to authenticated using (public.app_role() is not null);
    create policy "insert finance/master" on public.%1$I for insert to authenticated with check (public.can_write());
    create policy "update finance/master" on public.%1$I for update to authenticated using (public.can_write()) with check (public.can_write());
    create policy "delete finance/master" on public.%1$I for delete to authenticated using (public.can_write());
  $f$, t);
end $$;

select public._mk_doc_table('customers');
select public._mk_doc_table('sellers');
select public._mk_doc_table('items');
select public._mk_doc_table('terms');
select public._mk_doc_table('taxes');
select public._mk_doc_table('comm_rules');
select public._mk_doc_table('banks');
select public._mk_doc_table('views');
select public._mk_doc_table('quotes');
select public._mk_doc_table('invoices');
select public._mk_doc_table('receipts');
select public._mk_doc_table('credit_notes');
select public._mk_doc_table('comm_payments');
drop function public._mk_doc_table(text);

-- satu faktur/proyeksi aktif per pelanggan per bulan (aturan lempar & geser)
create unique index invoices_one_active_per_cust_month on public.invoices (cust, doc_month) where status in ('issued','draft');

-- singleton: company, periods, seq
create table public.settings (
  key text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
create or replace function public._touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
create trigger touch before insert or update on public.settings for each row execute function public._touch();
alter table public.settings enable row level security;
create policy "settings read" on public.settings for select to authenticated using (public.app_role() is not null);
create policy "settings insert" on public.settings for insert to authenticated with check (public.can_write());
create policy "settings update" on public.settings for update to authenticated using (public.can_write()) with check (public.can_write());

-- log aktivitas: append-only (tidak bisa diubah/dihapus dari aplikasi)
create table public.activity_log (
  id bigserial primary key,
  t date not null,
  who text not null,
  user_id uuid references auth.users(id),
  entity text not null,
  doc_id text,
  m text not null,
  created_at timestamptz not null default now()
);
create index on public.activity_log (created_at desc);
alter table public.activity_log enable row level security;
create policy "log read" on public.activity_log for select to authenticated using (public.app_role() is not null);
create policy "log insert" on public.activity_log for insert to authenticated with check (public.app_role() is not null);

-- profiles RLS: semua bisa lihat; user ubah prefs sendiri; Master kelola semua
alter table public.profiles enable row level security;
create policy "profiles read" on public.profiles for select to authenticated using (auth.uid() is not null);
create policy "profiles self" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid() and role = (select role from public.profiles p where p.id = auth.uid()));
create policy "profiles master" on public.profiles for all to authenticated using (public.is_master()) with check (public.is_master());

-- profil otomatis saat akun dibuat (metadata dari Master: username, name, role)
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, name, role)
  values (new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)),
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
    coalesce((new.raw_user_meta_data->>'role')::app_role, 'accounting'))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
