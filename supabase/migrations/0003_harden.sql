alter function public.can_write() set search_path = public;
alter function public.is_master() set search_path = public;
alter function public._doc_touch() set search_path = public;
alter function public._touch() set search_path = public;
revoke execute on function public.app_role() from anon, public;
revoke execute on function public.handle_new_user() from anon, authenticated, public;
