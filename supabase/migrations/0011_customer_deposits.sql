-- Uang muka penjualan (DP manual): dicatat Master/Finance; Staff tidak bisa membaca.
create table if not exists public.customer_deposits (
  id text primary key, data jsonb not null, status text, cust text, doc_date date, doc_month text,
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id));
create index if not exists customer_deposits_date on public.customer_deposits (doc_date);
create index if not exists customer_deposits_cust on public.customer_deposits (cust);
create trigger touch before insert or update on public.customer_deposits for each row execute function public._doc_touch();
alter table public.customer_deposits enable row level security;
create policy "read internal" on public.customer_deposits for select to authenticated using (public.is_internal());
create policy "insert finance/master" on public.customer_deposits for insert to authenticated with check (public.can_write());
create policy "update finance/master" on public.customer_deposits for update to authenticated using (public.can_write()) with check (public.can_write());
create policy "delete finance/master" on public.customer_deposits for delete to authenticated using (public.can_write());
alter publication supabase_realtime add table public.customer_deposits;
