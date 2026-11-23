-- Staff divisi ber-akses penawaran (AM/BD) boleh membuat & mengubah penawaran (bukan konversi ke faktur).
create or replace function public.is_sales_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles p join public.settings s on s.key = 'divisions'
    cross join lateral jsonb_array_elements(s.data) d
    where p.id = auth.uid() and p.active and p.role = 'staff' and d->>'id' = p.division and coalesce((d->>'sales')::boolean,false))
$$;
revoke execute on function public.is_sales_staff() from anon, public;
grant execute on function public.is_sales_staff() to authenticated;
create policy "quotes insert sales staff" on public.quotes for insert to authenticated
  with check (public.is_sales_staff() and coalesce(data->>'status','draft') <> 'converted');
create policy "quotes update sales staff" on public.quotes for update to authenticated
  using (public.is_sales_staff() and coalesce(status,'') <> 'converted')
  with check (public.is_sales_staff() and coalesce(data->>'status','') <> 'converted');
create policy "quotes delete sales staff" on public.quotes for delete to authenticated
  using (public.is_sales_staff() and coalesce(status,'draft') = 'draft');
-- nomor penawaran diambil atomik di server (Staff tidak bisa menulis settings)
create or replace function public.next_quote_seq() returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not (public.can_write() or public.is_sales_staff()) then raise exception 'Tidak berwenang membuat penawaran'; end if;
  update public.settings set data = jsonb_set(data, '{quote}', to_jsonb(coalesce((data->>'quote')::int, 1) + 1))
    where key = 'seq' returning (data->>'quote')::int - 1 into n;
  if n is null then raise exception 'Pengaturan nomor belum ada'; end if;
  return n;
end $$;
revoke execute on function public.next_quote_seq() from anon, public;
grant execute on function public.next_quote_seq() to authenticated;
