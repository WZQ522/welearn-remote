create or replace function public.admin_reset_remote_user_password(
    p_session_token text,
    p_target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    admin_id uuid := public.current_remote_admin_id(p_session_token);
    target_user public.remote_users;
begin
    if admin_id is null then
        raise exception 'admin_required';
    end if;

    select * into target_user
    from public.remote_users
    where id = p_target_user_id;

    if not found then
        raise exception 'remote_user_not_found';
    end if;
    if target_user.is_admin then
        raise exception 'admin_target_protected';
    end if;

    update public.remote_users
    set password_hash = extensions.crypt('11111111', extensions.gen_salt('bf', 12)),
        last_login_at = null
    where id = target_user.id;

    delete from public.remote_sessions
    where user_id = target_user.id;

    return jsonb_build_object(
        'user_id', target_user.id,
        'username', target_user.username,
        'password_reset', true
    );
end;
$$;

revoke all on function public.admin_reset_remote_user_password(text, uuid) from public, anon, authenticated;
grant execute on function public.admin_reset_remote_user_password(text, uuid) to anon, authenticated;

create or replace function public.admin_delete_remote_user(
    p_session_token text,
    p_target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    admin_id uuid := public.current_remote_admin_id(p_session_token);
    target_user public.remote_users;
begin
    if admin_id is null then
        raise exception 'admin_required';
    end if;
    if admin_id = p_target_user_id then
        raise exception 'admin_self_protected';
    end if;

    select * into target_user
    from public.remote_users
    where id = p_target_user_id;

    if not found then
        raise exception 'remote_user_not_found';
    end if;
    if target_user.is_admin then
        raise exception 'admin_target_protected';
    end if;

    delete from public.remote_users
    where id = target_user.id;

    return jsonb_build_object(
        'user_id', target_user.id,
        'username', target_user.username,
        'deleted', true
    );
end;
$$;

revoke all on function public.admin_delete_remote_user(text, uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_remote_user(text, uuid) to anon, authenticated;
