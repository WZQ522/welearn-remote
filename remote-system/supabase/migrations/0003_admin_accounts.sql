alter table public.remote_users
    drop constraint if exists remote_users_username_check;

alter table public.remote_users
    add constraint remote_users_username_check
    check (username ~ '^[a-z0-9][a-z0-9_.@-]{2,63}$');

alter table public.remote_users
    add column if not exists is_admin boolean not null default false;

create or replace function public.current_remote_admin_id(p_session_token text)
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
    select user_record.id
    from public.remote_sessions as session
    join public.remote_users as user_record on user_record.id = session.user_id
    where p_session_token is not null
      and session.token_hash = public.hash_remote_secret(p_session_token)
      and session.expires_at > now()
      and user_record.is_admin
$$;

revoke all on function public.current_remote_admin_id(text) from public, anon, authenticated;

create or replace function public.register_remote_user(
    p_username text,
    p_password text,
    p_invitation_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    normalized_username text := lower(btrim(coalesce(p_username, '')));
    normalized_code text := upper(btrim(coalesce(p_invitation_code, '')));
    invitation public.invitation_codes;
    existing_user_id uuid;
    created_user public.remote_users;
    session_token text;
    session_expiry timestamptz := now() + interval '30 days';
begin
    if normalized_username !~ '^[a-z0-9][a-z0-9_.@-]{2,63}$' then
        raise exception 'invalid_username';
    end if;
    if p_password is null or char_length(p_password) < 8 or char_length(p_password) > 128 then
        raise exception 'invalid_password';
    end if;
    if normalized_code !~ '^[A-F0-9]{32}$' then
        raise exception 'invalid_invitation_code';
    end if;

    select user_record.id into existing_user_id
    from public.remote_users as user_record
    where user_record.username = normalized_username;
    if existing_user_id is not null then
        raise exception 'username_taken';
    end if;

    select * into invitation
    from public.invitation_codes
    where code_hash = public.hash_remote_secret(normalized_code)
      and issue_date = (timezone('Asia/Shanghai', now()))::date
      and used_at is null
    for update;

    if not found then
        if exists (
            select 1 from public.invitation_codes
            where code_hash = public.hash_remote_secret(normalized_code)
              and used_at is not null
        ) then
            raise exception 'invitation_code_used';
        end if;
        if exists (
            select 1 from public.invitation_codes
            where code_hash = public.hash_remote_secret(normalized_code)
              and issue_date <> (timezone('Asia/Shanghai', now()))::date
        ) then
            raise exception 'invitation_code_expired';
        end if;
        raise exception 'invalid_invitation_code';
    end if;

    session_token := encode(extensions.gen_random_bytes(32), 'hex');

    insert into public.remote_users (username, password_hash, is_admin, last_login_at)
    values (
        normalized_username,
        extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
        false,
        now()
    )
    returning * into created_user;

    update public.invitation_codes
    set used_at = now(),
        used_by = created_user.id
    where id = invitation.id;

    insert into public.remote_sessions (token_hash, user_id, expires_at)
    values (public.hash_remote_secret(session_token), created_user.id, session_expiry);

    return jsonb_build_object(
        'user_id', created_user.id,
        'username', created_user.username,
        'is_admin', created_user.is_admin,
        'session_token', session_token,
        'expires_at', session_expiry
    );
end;
$$;

revoke all on function public.register_remote_user(text, text, text) from public;
grant execute on function public.register_remote_user(text, text, text) to anon, authenticated;

create or replace function public.login_remote_user(
    p_username text,
    p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    normalized_username text := lower(btrim(coalesce(p_username, '')));
    account public.remote_users;
    session_token text;
    session_expiry timestamptz := now() + interval '30 days';
begin
    select * into account
    from public.remote_users
    where username = normalized_username;

    if not found or p_password is null
       or account.password_hash <> extensions.crypt(p_password, account.password_hash) then
        raise exception 'invalid_credentials';
    end if;

    session_token := encode(extensions.gen_random_bytes(32), 'hex');
    update public.remote_users
    set last_login_at = now()
    where id = account.id;

    insert into public.remote_sessions (token_hash, user_id, expires_at)
    values (public.hash_remote_secret(session_token), account.id, session_expiry);

    return jsonb_build_object(
        'user_id', account.id,
        'username', account.username,
        'is_admin', account.is_admin,
        'session_token', session_token,
        'expires_at', session_expiry
    );
end;
$$;

revoke all on function public.login_remote_user(text, text) from public;
grant execute on function public.login_remote_user(text, text) to anon, authenticated;

create or replace function public.admin_issue_invitation_codes(
    p_session_token text,
    p_count integer default 10
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if public.current_remote_admin_id(p_session_token) is null then
        raise exception 'admin_required';
    end if;
    return public.issue_invitation_codes(p_count);
end;
$$;

revoke all on function public.admin_issue_invitation_codes(text, integer) from public, anon, authenticated;
grant execute on function public.admin_issue_invitation_codes(text, integer) to anon, authenticated;

create or replace function public.admin_list_invitation_codes(
    p_session_token text,
    p_issue_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    requested_date date := coalesce(p_issue_date, (timezone('Asia/Shanghai', now()))::date);
begin
    if public.current_remote_admin_id(p_session_token) is null then
        raise exception 'admin_required';
    end if;

    return coalesce(
        (
            select jsonb_agg(
                jsonb_build_object(
                    'code', code_text,
                    'issue_date', issue_date,
                    'used_at', used_at,
                    'created_at', created_at
                ) order by created_at desc
            )
            from public.invitation_codes
            where issue_date = requested_date
        ),
        '[]'::jsonb
    );
end;
$$;

revoke all on function public.admin_list_invitation_codes(text, date) from public, anon, authenticated;
grant execute on function public.admin_list_invitation_codes(text, date) to anon, authenticated;

create or replace function public.bootstrap_admin_account(
    p_username text,
    p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    normalized_username text := lower(btrim(coalesce(p_username, '')));
    account_id uuid;
begin
    if normalized_username !~ '^[a-z0-9][a-z0-9_.@-]{2,63}$' then
        raise exception 'invalid_username';
    end if;
    if p_password is null or char_length(p_password) < 8 or char_length(p_password) > 128 then
        raise exception 'invalid_password';
    end if;

    insert into public.remote_users (username, password_hash, is_admin)
    values (
        normalized_username,
        extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
        true
    )
    on conflict (username) do update
    set password_hash = excluded.password_hash,
        is_admin = true
    returning id into account_id;

    return jsonb_build_object(
        'user_id', account_id,
        'username', normalized_username,
        'is_admin', true
    );
end;
$$;

revoke all on function public.bootstrap_admin_account(text, text) from public, anon, authenticated;
grant execute on function public.bootstrap_admin_account(text, text) to service_role;
