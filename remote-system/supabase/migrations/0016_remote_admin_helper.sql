begin;

create or replace function public.is_remote_admin(p_session_token text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
    select public.current_remote_admin_id(p_session_token) is not null
$$;

revoke all on function public.is_remote_admin(text) from public, anon, authenticated;

commit;
