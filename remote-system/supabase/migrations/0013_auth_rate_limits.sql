begin;

-- Public RPCs remain available to anonymous users, but repeated login and
-- invitation guesses are bounded in the database instead of trusting the UI.
-- Only a digest of the bucket is stored; no password, invitation value, or
-- browser token is written to this table.
create table if not exists public.remote_auth_rate_limits (
    bucket_hash text primary key check (length(bucket_hash) = 64),
    attempt_count integer not null default 1 check (attempt_count >= 0),
    window_started timestamptz not null default now(),
    blocked_until timestamptz,
    updated_at timestamptz not null default now()
);

alter table public.remote_auth_rate_limits enable row level security;
revoke all on table public.remote_auth_rate_limits from anon, authenticated;
grant all on table public.remote_auth_rate_limits to service_role;

create or replace function public.consume_remote_auth_rate_limit(
    p_bucket text,
    p_limit integer default 10,
    p_window_seconds integer default 900
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    normalized_bucket text := btrim(coalesce(p_bucket, ''));
    bucket_digest text;
    current_limit public.remote_auth_rate_limits;
begin
    if normalized_bucket = '' or char_length(normalized_bucket) > 256 then
        raise exception 'invalid_rate_limit_bucket';
    end if;
    if p_limit is null or p_limit < 1 or p_limit > 100 then
        raise exception 'invalid_rate_limit_limit';
    end if;
    if p_window_seconds is null or p_window_seconds < 60 or p_window_seconds > 86400 then
        raise exception 'invalid_rate_limit_window';
    end if;

    delete from public.remote_auth_rate_limits
    where updated_at < now() - interval '2 days';

    bucket_digest := public.hash_remote_secret(normalized_bucket);
    perform pg_advisory_xact_lock(hashtext('remote-auth-rate:' || bucket_digest));
    select * into current_limit
    from public.remote_auth_rate_limits
    where bucket_hash = bucket_digest
    for update;

    if not found then
        insert into public.remote_auth_rate_limits (bucket_hash)
        values (bucket_digest);
        return true;
    end if;

    if current_limit.window_started <= now() - make_interval(secs => p_window_seconds) then
        update public.remote_auth_rate_limits
        set attempt_count = 1,
            window_started = now(),
            blocked_until = null,
            updated_at = now()
        where bucket_hash = bucket_digest;
        return true;
    end if;

    if current_limit.blocked_until is not null and current_limit.blocked_until > now() then
        return false;
    end if;

    if current_limit.attempt_count >= p_limit then
        update public.remote_auth_rate_limits
        set blocked_until = now() + make_interval(secs => p_window_seconds),
            updated_at = now()
        where bucket_hash = bucket_digest;
        return false;
    end if;

    update public.remote_auth_rate_limits
    set attempt_count = attempt_count + 1,
        updated_at = now()
    where bucket_hash = bucket_digest;
    return true;
end;
$$;

revoke all on function public.consume_remote_auth_rate_limit(text, integer, integer)
    from public, anon, authenticated;

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
    if not public.consume_remote_auth_rate_limit('register-user:' || normalized_username, 5, 900)
       or not public.consume_remote_auth_rate_limit('register-code:' || normalized_code, 10, 900) then
        raise exception 'auth_rate_limited';
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
    insert into public.remote_users (username, password_hash, last_login_at)
    values (
        normalized_username,
        extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
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
    if normalized_username !~ '^[a-z0-9][a-z0-9_.@-]{2,63}$' then
        raise exception 'invalid_username';
    end if;
    if not public.consume_remote_auth_rate_limit('login-user:' || normalized_username, 10, 900) then
        raise exception 'auth_rate_limited';
    end if;

    select * into account
    from public.remote_users
    where username = normalized_username;

    if not found or p_password is null
       or account.password_hash <> extensions.crypt(p_password, account.password_hash) then
        raise exception 'invalid_credentials';
    end if;

    delete from public.remote_auth_rate_limits
    where bucket_hash = public.hash_remote_secret('login-user:' || normalized_username);

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

commit;
