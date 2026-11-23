-- Pengajuan Budget (Payment Request & Cash Advance), divisi + approver, notifikasi per pengguna, lampiran.

-- 1. divisi per pengguna
alter table public.profiles add column if not exists division text;
drop policy if exists "profiles self" on public.profiles;
create policy "profiles self" on public.profiles for update to authenticated using (id = auth.uid())
  with check (id = auth.uid()
    and role = (select role from public.profiles p where p.id = auth.uid())
    and coalesce(division,'') = coalesce((select division from public.profiles p where p.id = auth.uid()),''));
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, name, role, division)
  values (new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)),
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
    coalesce((new.raw_user_meta_data->>'role')::app_role, 'accounting'),
    nullif(new.raw_user_meta_data->>'division',''))
  on conflict (id) do nothing;
  return new;
end $$;

-- 2. Staff tidak boleh membaca data sensitif (komisi, bank, tampilan tersimpan, log orang lain)
create or replace function public.is_internal() returns boolean language sql stable set search_path = public as $$ select public.app_role() in ('master','finance','accounting') $$;
do $$ declare t text; begin
  foreach t in array array['comm_rules','comm_payments','banks','views'] loop
    execute format('drop policy if exists "read authenticated" on public.%I', t);
    execute format('create policy "read internal" on public.%I for select to authenticated using (public.is_internal())', t);
  end loop;
end $$;
drop policy if exists "log read" on public.activity_log;
create policy "log read" on public.activity_log for select to authenticated using (public.is_internal() or user_id = auth.uid());

-- 3. pengajuan budget
create table if not exists public.budget_requests (
  id text primary key,
  data jsonb not null,
  status text,
  by_user uuid,
  appr1 uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
create index if not exists budget_requests_by on public.budget_requests (by_user);
create index if not exists budget_requests_appr on public.budget_requests (appr1);
create or replace function public._budget_touch() returns trigger language plpgsql set search_path = public as $$
declare r app_role := public.app_role(); fin boolean := r in ('master','finance'); u text := auth.uid()::text;
  os text; ns text;
begin
  new.status := new.data->>'status';
  new.by_user := nullif(new.data->>'by','')::uuid;
  new.appr1 := nullif(new.data->>'appr1','')::uuid;
  new.updated_at := now();
  new.updated_by := auth.uid();
  if fin or auth.uid() is null then return new; end if;
  if r = 'accounting' then raise exception 'Accounting hanya bisa melihat'; end if;
  if tg_op = 'INSERT' then
    if new.data->>'by' is distinct from u then raise exception 'Pengajuan harus atas nama sendiri'; end if;
    if new.status not in ('draft','appr1','fin') then raise exception 'Status awal tidak valid'; end if;
    if new.status = 'fin' and new.appr1 is not null and new.appr1::text <> u then raise exception 'Harus lewat atasan'; end if;
    return new;
  end if;
  os := old.status; ns := new.status;
  if old.by_user::text = u then
    -- pengaju: kirim / revisi / batalkan / settlement
    if (os in ('draft','rejected') and ns in ('draft','appr1','fin','cancelled'))
       or (os in ('appr1','fin') and ns in (os,'cancelled'))
       or (os = 'ca_open' and ns in ('ca_open','st_appr1','st_fin'))
       or (os = ns) then
      if ns = 'fin' and os in ('draft','rejected') and new.appr1 is not null and new.appr1::text <> u then raise exception 'Harus lewat atasan'; end if;
      if os not in ('draft','rejected') and ((new.data->'amount') is distinct from (old.data->'amount') or (new.data->'alloc') is distinct from (old.data->'alloc') or (new.data->'pay') is distinct from (old.data->'pay') or new.appr1 is distinct from old.appr1) then
        raise exception 'Nominal/alokasi/pembayaran tidak bisa diubah setelah diajukan';
      end if;
      if os = ns and os not in ('draft','rejected','ca_open') and (new.data->'settle') is distinct from (old.data->'settle') then raise exception 'Settlement terkunci'; end if;
      return new;
    end if;
  end if;
  if old.appr1::text = u then
    -- atasan: setujui / tolak pengajuan & settlement
    if (os = 'appr1' and ns in ('fin','rejected')) or (os = 'st_appr1' and ns in ('st_fin','ca_open')) then
      if (new.data->'amount') is distinct from (old.data->'amount') or (new.data->'alloc') is distinct from (old.data->'alloc') or (new.data->'pay') is distinct from (old.data->'pay') or (new.data->'settle'->'items') is distinct from (old.data->'settle'->'items') or new.appr1 is distinct from old.appr1 or new.by_user is distinct from old.by_user then
        raise exception 'Atasan hanya bisa menyetujui/menolak';
      end if;
      return new;
    end if;
  end if;
  raise exception 'Tidak berwenang mengubah pengajuan ini (status %)', os;
end $$;
drop trigger if exists touch on public.budget_requests;
create trigger touch before insert or update on public.budget_requests for each row execute function public._budget_touch();
alter table public.budget_requests enable row level security;
create policy "budget read" on public.budget_requests for select to authenticated
  using (public.is_internal() or by_user = auth.uid() or appr1 = auth.uid());
create policy "budget insert" on public.budget_requests for insert to authenticated
  with check (public.app_role() is not null and public.app_role() <> 'accounting');
create policy "budget update" on public.budget_requests for update to authenticated
  using (public.can_write() or by_user = auth.uid() or appr1 = auth.uid())
  with check (public.can_write() or by_user = auth.uid() or appr1 = auth.uid());
create policy "budget delete" on public.budget_requests for delete to authenticated
  using (public.can_write() or (by_user = auth.uid() and status = 'draft'));
alter publication supabase_realtime add table public.budget_requests;

-- nomor urut PR / CA / NP
create sequence if not exists public.budget_pr_seq;
create sequence if not exists public.budget_ca_seq;
create or replace function public.next_budget_no(kind text) returns text language plpgsql security definer set search_path = public as $$
begin
  if public.app_role() is null then raise exception 'Belum masuk'; end if;
  if kind = 'CA' then return 'CA-' || lpad(nextval('public.budget_ca_seq')::text, 4, '0'); end if;
  return 'PR-' || lpad(nextval('public.budget_pr_seq')::text, 4, '0');
end $$;
revoke execute on function public.next_budget_no(text) from anon, public;
grant execute on function public.next_budget_no(text) to authenticated;

-- 4. notifikasi per pengguna
create table if not exists public.notifications (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  m text not null,
  link text,
  read_at timestamptz,
  by_user uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists notifications_user on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;
create policy "notif read own" on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "notif mark own" on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "notif delete own" on public.notifications for delete to authenticated using (user_id = auth.uid());
create policy "notif insert" on public.notifications for insert to authenticated with check (public.app_role() is not null and by_user = auth.uid());
alter publication supabase_realtime add table public.notifications;

-- 5. pengaturan divisi & approver (diisi Master/Finance di Pengaturan)
insert into public.settings (key, data) values ('divisions', '[
  {"id":"am","name":"AM","appr1":null,"direct":false,"sales":true},
  {"id":"affcc","name":"AFF/CC/Live","appr1":null,"direct":false,"sales":false},
  {"id":"mcn","name":"MCN","appr1":null,"direct":true,"sales":false},
  {"id":"bd","name":"BD","appr1":null,"direct":false,"sales":true},
  {"id":"mkt","name":"Marketing","appr1":null,"direct":false,"sales":false}
]'::jsonb) on conflict (key) do nothing;

-- 6. lampiran (bucket privat)
insert into storage.buckets (id, name, public, file_size_limit) values ('budget-files','budget-files', false, 10485760)
  on conflict (id) do nothing;
create policy "budget files read" on storage.objects for select to authenticated using (bucket_id = 'budget-files' and public.app_role() is not null);
create policy "budget files upload" on storage.objects for insert to authenticated with check (bucket_id = 'budget-files' and public.app_role() is not null and public.app_role() <> 'accounting');
