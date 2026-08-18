create extension if not exists pgcrypto with schema extensions;

create table if not exists public.remote_users (
    id uuid primary key default gen_random_uuid(),
    username text not null unique check (username ~ '^[A-Za-z0-9_.-]{3,32}$'),
    password_hash text not null,
    created_at timestamptz not null default now(),
    last_login_at timestamptz
);

create table if not exists public.remote_sessions (
    token_hash text primary key check (length(token_hash) = 64),
    user_id uuid not null references public.remote_users(id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null
);

create index if not exists remote_sessions_user_idx
    on public.remote_sessions (user_id, expires_at desc);

create table if not exists public.invitation_codes (
    id uuid primary key default gen_random_uuid(),
    code_hash text not null unique check (length(code_hash) = 64),
    code_text text not null check (length(code_text) between 12 and 64),
    issue_date date not null default (timezone('Asia/Shanghai', now()))::date,
    used_at timestamptz,
    used_by uuid references public.remote_users(id) on delete set null,
    created_at timestamptz not null default now()
);

create index if not exists invitation_codes_daily_idx
    on public.invitation_codes (issue_date, used_at, created_at);

alter table public.remote_users enable row level security;
alter table public.remote_sessions enable row level security;
alter table public.invitation_codes enable row level security;
revoke all on table public.remote_users from anon, authenticated;
revoke all on table public.remote_sessions from anon, authenticated;
revoke all on table public.invitation_codes from anon, authenticated;
grant all on table public.remote_users to service_role;
grant all on table public.remote_sessions to service_role;
grant all on table public.invitation_codes to service_role;

create table if not exists public.remote_submissions (
    id uuid primary key default gen_random_uuid(),
    client_id uuid not null,
    user_id uuid references public.remote_users(id) on delete cascade,
    view_token_hash text not null check (length(view_token_hash) = 64),
    raw_text text not null check (char_length(raw_text) between 1 and 200000),
    line_count integer not null check (line_count between 1 and 5000),
    status text not null default 'pending'
        check (status in ('pending', 'processing', 'completed', 'failed', 'canceled')),
    execution_status text not null default 'waiting'
        check (execution_status in ('waiting', 'running', 'needs_action', 'completed', 'partial', 'failed')),
    task_total integer not null default 0 check (task_total >= 0),
    task_completed integer not null default 0 check (task_completed >= 0),
    task_failed integer not null default 0 check (task_failed >= 0),
    result_message text,
    result_payload jsonb,
    error_message text,
    agent_id text,
    attempt_count integer not null default 0 check (attempt_count >= 0),
    cancel_requested boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    claimed_at timestamptz,
    heartbeat_at timestamptz,
    completed_at timestamptz
);

alter table public.remote_submissions
    add column if not exists user_id uuid references public.remote_users(id) on delete cascade;

create index if not exists remote_submissions_claim_idx
    on public.remote_submissions (status, created_at)
    where status in ('pending', 'processing');

create index if not exists remote_submissions_client_idx
    on public.remote_submissions (client_id, created_at desc);

create index if not exists remote_submissions_user_idx
    on public.remote_submissions (user_id, created_at desc);

alter table public.remote_submissions enable row level security;
revoke all on table public.remote_submissions from anon, authenticated;
grant all on table public.remote_submissions to service_role;

create or replace function public.hash_remote_secret(value text)
returns text
language sql
immutable
strict
set search_path = public, extensions
as $$
    select encode(extensions.digest(convert_to(value, 'UTF8'), 'sha256'), 'hex')
$$;

revoke all on function public.hash_remote_secret(text) from public, anon, authenticated;

create or replace function public.current_remote_user_id(p_session_token text)
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
    select session.user_id
    from public.remote_sessions as session
    where p_session_token is not null
      and session.token_hash = public.hash_remote_secret(p_session_token)
      and session.expires_at > now()
$$;

revoke all on function public.current_remote_user_id(text) from public, anon, authenticated;

create or replace function public.issue_invitation_codes(p_count integer default 10)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    generated_count integer := 0;
    candidate text;
    inserted_id uuid;
    generated_codes jsonb := '[]'::jsonb;
begin
    if p_count is null or p_count < 1 or p_count > 1000 then
        raise exception 'invalid_invitation_count';
    end if;

    while generated_count < p_count loop
        candidate := upper(encode(extensions.gen_random_bytes(16), 'hex'));
        inserted_id := null;

        insert into public.invitation_codes (code_hash, code_text, issue_date)
        values (
            public.hash_remote_secret(candidate),
            candidate,
            (timezone('Asia/Shanghai', now()))::date
        )
        on conflict (code_hash) do nothing
        returning id into inserted_id;

        if inserted_id is not null then
            generated_count := generated_count + 1;
            generated_codes := generated_codes || to_jsonb(candidate);
        end if;
    end loop;

    return generated_codes;
end;
$$;

revoke all on function public.issue_invitation_codes(integer) from public, anon, authenticated;
grant execute on function public.issue_invitation_codes(integer) to service_role;

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
    if normalized_username !~ '^[a-z0-9_.-]{3,32}$' then
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
        'session_token', session_token,
        'expires_at', session_expiry
    );
end;
$$;

revoke all on function public.login_remote_user(text, text) from public;
grant execute on function public.login_remote_user(text, text) to anon, authenticated;

create or replace function public.logout_remote_user(p_session_token text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    deleted_count integer;
begin
    delete from public.remote_sessions
    where token_hash = public.hash_remote_secret(p_session_token);
    get diagnostics deleted_count = row_count;
    return deleted_count = 1;
end;
$$;

revoke all on function public.logout_remote_user(text) from public;
grant execute on function public.logout_remote_user(text) to anon, authenticated;

create or replace function public.hash_submission_view_token(value text)
returns text
language sql
immutable
strict
set search_path = public, extensions
as $$
    select encode(extensions.digest(convert_to(value, 'UTF8'), 'sha256'), 'hex')
$$;

revoke all on function public.hash_submission_view_token(text) from public, anon, authenticated;

drop function if exists public.submit_submission(text, uuid, text);
drop function if exists public.get_submission(uuid, text);
drop function if exists public.cancel_submission(uuid, text);
drop function if exists public.retry_submission(uuid, text);
drop function if exists public.clear_submission(uuid, text);

create or replace function public.submit_submission(
    p_raw_text text,
    p_client_id uuid,
    p_view_token text,
    p_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    created public.remote_submissions;
    calculated_line_count integer;
    authenticated_user_id uuid;
begin
    authenticated_user_id := public.current_remote_user_id(p_session_token);
    if authenticated_user_id is null then
        raise exception 'login_required';
    end if;
    if p_raw_text is null or btrim(p_raw_text) = '' then
        raise exception 'raw_text_required';
    end if;
    if octet_length(p_raw_text) > 200000 then
        raise exception 'raw_text_too_large';
    end if;
    if p_view_token is null or char_length(p_view_token) < 32 or char_length(p_view_token) > 256 then
        raise exception 'invalid_view_token';
    end if;

    select count(*)::integer into calculated_line_count
    from regexp_split_to_table(p_raw_text, E'\\r?\\n') as entry(line)
    where btrim(entry.line) <> '';

    if calculated_line_count < 1 or calculated_line_count > 5000 then
        raise exception 'invalid_line_count';
    end if;

    insert into public.remote_submissions (
        client_id,
        user_id,
        view_token_hash,
        raw_text,
        line_count,
        task_total
    )
    values (
        p_client_id,
        authenticated_user_id,
        public.hash_submission_view_token(p_view_token),
        p_raw_text,
        calculated_line_count,
        calculated_line_count
    )
    returning * into created;

    return jsonb_build_object(
        'id', created.id,
        'status', created.status,
        'execution_status', created.execution_status,
        'line_count', created.line_count,
        'created_at', created.created_at
    );
end;
$$;

create or replace function public.get_submission(
    p_submission_id uuid,
    p_view_token text,
    p_session_token text
)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
    select jsonb_build_object(
        'id', submission.id,
        'status', submission.status,
        'execution_status', submission.execution_status,
        'line_count', submission.line_count,
        'task_total', submission.task_total,
        'task_completed', submission.task_completed,
        'task_failed', submission.task_failed,
        'result_message', submission.result_message,
        'error_message', submission.error_message,
        'score_summary', submission.result_payload -> 'score_summary',
        'attempt_count', submission.attempt_count,
        'cancel_requested', submission.cancel_requested,
        'created_at', submission.created_at,
        'updated_at', submission.updated_at,
        'completed_at', submission.completed_at
    )
    from public.remote_submissions as submission
    where submission.id = p_submission_id
      and submission.user_id = public.current_remote_user_id(p_session_token)
      and submission.view_token_hash = public.hash_submission_view_token(p_view_token)
$$;

create or replace function public.cancel_submission(
    p_submission_id uuid,
    p_view_token text,
    p_session_token text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer;
begin
    update public.remote_submissions
    set cancel_requested = true,
        status = case when status = 'pending' then 'canceled' else status end,
        result_message = case when status = 'pending' then '已取消' else result_message end,
        completed_at = case when status = 'pending' then now() else completed_at end,
        updated_at = now()
    where id = p_submission_id
      and user_id = public.current_remote_user_id(p_session_token)
      and view_token_hash = public.hash_submission_view_token(p_view_token)
      and status in ('pending', 'processing');
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

create or replace function public.retry_submission(
    p_submission_id uuid,
    p_view_token text,
    p_session_token text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer;
begin
    update public.remote_submissions
    set status = 'pending',
        execution_status = 'waiting',
        task_total = line_count,
        task_completed = 0,
        task_failed = 0,
        result_message = null,
        result_payload = null,
        error_message = null,
        agent_id = null,
        cancel_requested = false,
        claimed_at = null,
        heartbeat_at = null,
        completed_at = null,
        updated_at = now()
    where id = p_submission_id
      and user_id = public.current_remote_user_id(p_session_token)
      and view_token_hash = public.hash_submission_view_token(p_view_token)
      and (
          status in ('failed', 'canceled')
          or execution_status in ('needs_action', 'partial', 'failed')
      );
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

create or replace function public.clear_submission(
    p_submission_id uuid,
    p_view_token text,
    p_session_token text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer := 0;
begin
    delete from public.remote_submissions
    where id = p_submission_id
      and user_id = public.current_remote_user_id(p_session_token)
      and view_token_hash = public.hash_submission_view_token(p_view_token)
      and status in ('completed', 'failed', 'canceled');
    get diagnostics changed = row_count;

    if changed = 0 then
        update public.remote_submissions
        set view_token_hash = encode(extensions.gen_random_bytes(32), 'hex'),
            updated_at = now()
        where id = p_submission_id
          and user_id = public.current_remote_user_id(p_session_token)
          and view_token_hash = public.hash_submission_view_token(p_view_token);
        get diagnostics changed = row_count;
    end if;
    return changed = 1;
end;
$$;

create or replace function public.claim_next_submission(p_agent_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    selected_id uuid;
    selected_submission public.remote_submissions;
begin
    if p_agent_id is null or char_length(trim(p_agent_id)) not between 1 and 128 then
        raise exception 'invalid_agent_id';
    end if;

    select id into selected_id
    from public.remote_submissions
    where cancel_requested = false
      and (
          status = 'pending'
          or (
              status = 'processing'
              and (
                  agent_id = trim(p_agent_id)
                  or heartbeat_at is null
                  or heartbeat_at < now() - interval '5 minutes'
              )
          )
      )
    order by
        case
            when status = 'processing' and agent_id = trim(p_agent_id) then 0
            when status = 'processing' then 1
            else 2
        end,
        created_at,
        id
    for update skip locked
    limit 1;

    if selected_id is null then
        return null;
    end if;

    update public.remote_submissions
    set status = 'processing',
        execution_status = 'running',
        agent_id = trim(p_agent_id),
        attempt_count = attempt_count + 1,
        claimed_at = now(),
        heartbeat_at = now(),
        updated_at = now()
    where id = selected_id
    returning * into selected_submission;

    return jsonb_build_object(
        'id', selected_submission.id,
        'raw_text', selected_submission.raw_text,
        'line_count', selected_submission.line_count,
        'attempt_count', selected_submission.attempt_count,
        'created_at', selected_submission.created_at
    );
end;
$$;

create or replace function public.agent_heartbeat_submission(
    p_submission_id uuid,
    p_agent_id text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    should_continue boolean;
begin
    update public.remote_submissions
    set heartbeat_at = now(),
        execution_status = 'running',
        updated_at = now()
    where id = p_submission_id
      and agent_id = trim(p_agent_id)
      and status = 'processing'
    returning not cancel_requested into should_continue;
    return coalesce(should_continue, false);
end;
$$;

create or replace function public.agent_report_submission(
    p_submission_id uuid,
    p_agent_id text,
    p_execution_status text,
    p_task_total integer,
    p_task_completed integer,
    p_task_failed integer,
    p_result_message text default null,
    p_result jsonb default null,
    p_error_message text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer;
begin
    if p_execution_status not in ('needs_action', 'completed', 'partial', 'failed') then
        raise exception 'invalid_execution_status';
    end if;
    if p_task_total < 0 or p_task_completed < 0 or p_task_failed < 0
       or p_task_completed + p_task_failed > p_task_total then
        raise exception 'invalid_task_counts';
    end if;

    update public.remote_submissions
    set status = case
            when cancel_requested then 'canceled'
            when p_execution_status = 'failed' then 'failed'
            else 'completed'
        end,
        execution_status = case when cancel_requested then execution_status else p_execution_status end,
        task_total = p_task_total,
        task_completed = p_task_completed,
        task_failed = p_task_failed,
        result_message = case
            when cancel_requested then '已取消'
            else left(coalesce(p_result_message, ''), 2000)
        end,
        result_payload = case when cancel_requested then null else p_result end,
        error_message = case
            when cancel_requested then 'Canceled from web console'
            when p_execution_status = 'failed' then left(coalesce(p_error_message, p_result_message, 'Processor failed'), 2000)
            else null
        end,
        heartbeat_at = now(),
        completed_at = now(),
        updated_at = now()
    where id = p_submission_id
      and agent_id = trim(p_agent_id)
      and status = 'processing';
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

revoke all on function public.submit_submission(text, uuid, text, text) from public;
revoke all on function public.get_submission(uuid, text, text) from public;
revoke all on function public.cancel_submission(uuid, text, text) from public;
revoke all on function public.retry_submission(uuid, text, text) from public;
revoke all on function public.clear_submission(uuid, text, text) from public;
revoke all on function public.claim_next_submission(text) from public;
revoke all on function public.agent_heartbeat_submission(uuid, text) from public;
revoke all on function public.agent_report_submission(uuid, text, text, integer, integer, integer, text, jsonb, text) from public;

grant execute on function public.submit_submission(text, uuid, text, text) to anon, authenticated;
grant execute on function public.get_submission(uuid, text, text) to anon, authenticated;
grant execute on function public.cancel_submission(uuid, text, text) to anon, authenticated;
grant execute on function public.retry_submission(uuid, text, text) to anon, authenticated;
grant execute on function public.clear_submission(uuid, text, text) to anon, authenticated;
grant execute on function public.claim_next_submission(text) to service_role;
grant execute on function public.agent_heartbeat_submission(uuid, text) to service_role;
grant execute on function public.agent_report_submission(uuid, text, text, integer, integer, integer, text, jsonb, text) to service_role;
