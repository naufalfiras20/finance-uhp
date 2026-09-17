-- satu PROYEKSI per pelanggan per bulan; faktur terbit boleh lebih dari satu (add-on, termin)
drop index if exists public.invoices_one_active_per_cust_month;
create unique index invoices_one_draft_per_cust_month on public.invoices (cust, doc_month) where status = 'draft';
