-- Jenjang approval per orang (settings.people[uid].chain), pengajuan multi-item, akses penawaran per orang.
insert into public.settings (key, data) values ('people', '{}'::jsonb) on conflict (key) do nothing;
update public.settings set data = '[{"id":"am","name":"AM"},{"id":"aff","name":"AFF"},{"id":"cc","name":"CC"},{"id":"live","name":"Live"},{"id":"mcn","name":"MCN"},{"id":"bd","name":"BD"},{"id":"mkt","name":"Marketing"}]'::jsonb where key = 'divisions';

create or replace function public.is_sales_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles p join public.settings s on s.key = 'people'
    where p.id = auth.uid() and p.active and p.role = 'staff'
      and coalesce((s.data -> (auth.uid()::text) ->> 'quotes')::boolean, false))
$$;

create or replace function public._budget_touch() returns trigger language plpgsql set search_path = public as $$
declare r app_role := public.app_role(); fin boolean := r in ('master','finance'); u text := auth.uid()::text;
  os text; ns text; cfg jsonb; ch jsonb; i int; n int;
begin
  new.status := new.data->>'status';
  new.by_user := nullif(new.data->>'by','')::uuid;
  new.appr1 := nullif(new.data->>'appr1','')::uuid;
  new.updated_at := now();
  new.updated_by := auth.uid();
  if fin or auth.uid() is null then return new; end if;
  if r = 'accounting' then raise exception 'Accounting hanya bisa melihat'; end if;
  ns := new.status;
  os := case when tg_op = 'INSERT' then 'draft' else old.status end;
  -- pengaju
  if new.data->>'by' = u and (tg_op = 'INSERT' or old.by_user::text = u) then
    if tg_op = 'UPDATE' and old.status not in ('draft','rejected') and (
      (old.data->'items') is distinct from (new.data->'items') or (old.data->'amount') is distinct from (new.data->'amount')
      or (old.data->'pay') is distinct from (new.data->'pay') or (old.data->'chain') is distinct from (new.data->'chain')) then
      raise exception 'Isi pengajuan tidak bisa diubah setelah diajukan';
    end if;
    if os in ('draft','rejected') and ns in ('draft','cancelled') then return new; end if;
    if os in ('draft','rejected') and ns in ('appr1','fin') then
      select s.data -> u into cfg from public.settings s where s.key = 'people';
      if cfg is null or jsonb_typeof(cfg->'chain') is distinct from 'array' then raise exception 'Jenjang approval Anda belum diatur'; end if;
      ch := cfg->'chain';
      if (new.data->'chain') is distinct from ch then raise exception 'Jenjang approval tidak sesuai pengaturan'; end if;
      if jsonb_array_length(ch) = 0 then
        if ns <> 'fin' then raise exception 'Harus langsung ke Finance'; end if;
      elsif ns <> 'appr1' or (new.data->>'appr1') is distinct from (ch->>0) then raise exception 'Harus lewat approver pertama'; end if;
      return new;
    end if;
    if os in ('appr1','fin') and ns = 'cancelled' then return new; end if;
    if os = 'ca_open' and ns = 'ca_open' then return new; end if;
    if os = 'ca_open' and ns in ('st_appr1','st_fin') then
      ch := coalesce(old.data->'chain','[]'::jsonb);
      if jsonb_array_length(ch) = 0 then
        if ns <> 'st_fin' then raise exception 'Settlement langsung ke Finance'; end if;
      elsif ns <> 'st_appr1' or (new.data->>'appr1') is distinct from (ch->>0) then raise exception 'Settlement harus lewat approver pertama'; end if;
      return new;
    end if;
  end if;
  -- approver yang sedang bertugas
  if tg_op = 'UPDATE' and old.appr1::text = u and old.status in ('appr1','st_appr1') then
    if (old.data->'items') is distinct from (new.data->'items') or (old.data->'amount') is distinct from (new.data->'amount')
      or (old.data->'chain') is distinct from (new.data->'chain') or (old.data->'pay') is distinct from (new.data->'pay')
      or (old.data->'settle'->'items') is distinct from (new.data->'settle'->'items') or new.by_user is distinct from old.by_user then
      raise exception 'Approver hanya bisa menyetujui atau menolak';
    end if;
    if old.status = 'appr1' and ns = 'rejected' then return new; end if;
    if old.status = 'st_appr1' and ns = 'ca_open' then return new; end if;
    ch := coalesce(old.data->'chain','[]'::jsonb); n := jsonb_array_length(ch);
    select t.ord - 1 into i from jsonb_array_elements_text(ch) with ordinality as t(v, ord) where t.v = u limit 1;
    if i is not null and i < n - 1 then
      if ns = old.status and (new.data->>'appr1') = (ch->>(i + 1)) then return new; end if;
    elsif (old.status = 'appr1' and ns = 'fin') or (old.status = 'st_appr1' and ns = 'st_fin') then
      return new;
    end if;
    raise exception 'Langkah approval tidak valid';
  end if;
  raise exception 'Tidak berwenang mengubah pengajuan ini (status %)', os;
end $$;

drop policy if exists "budget read" on public.budget_requests;
create policy "budget read" on public.budget_requests for select to authenticated
  using (public.is_internal() or by_user = auth.uid() or appr1 = auth.uid() or (data->'chain') ? (auth.uid()::text));
drop policy if exists "budget update" on public.budget_requests;
create policy "budget update" on public.budget_requests for update to authenticated
  using (public.can_write() or by_user = auth.uid() or appr1 = auth.uid())
  with check (public.can_write() or by_user = auth.uid() or appr1 = auth.uid() or (data->'chain') ? (auth.uid()::text));
