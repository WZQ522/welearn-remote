create extension if not exists pgcrypto with schema extensions;

create table if not exists public.remote_submissions (
    id uuid primary key default gen_random_uuid(),
    client_id uuid not null,
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

create index if not exists remote_submissions_claim_idx
    on public.remote_submissions (status, created_at)
    where status in ('pending', 'processing');

create index if not exists remote_submissions_client_idx
    on public.remote_submissions (client_id, created_at desc);

alter table public.remote_submissions enable row level security;
revoke all on table public.remote_submissions from anon, authenticated;
grant all on table public.remote_submissions to service_role;

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

create or replace function public.submit_submission(
    p_raw_text text,
    p_client_id uuid,
    p_view_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    created public.remote_submissions;
    calculated_line_count integer;
begin
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
        view_token_hash,
        raw_text,
        line_count,
        task_total
    )
    values (
        p_client_id,
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
    p_view_token text
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
        'attempt_count', submission.attempt_count,
        'cancel_requested', submission.cancel_requested,
        'created_at', submission.created_at,
        'updated_at', submission.updated_at,
        'completed_at', submission.completed_at
    )
    from public.remote_submissions as submission
    where submission.id = p_submission_id
      and submission.view_token_hash = public.hash_submission_view_token(p_view_token)
$$;

create or replace function public.cancel_submission(
    p_submission_id uuid,
    p_view_token text
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
      and view_token_hash = public.hash_submission_view_token(p_view_token)
      and status in ('pending', 'processing');
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

create or replace function public.retry_submission(
    p_submission_id uuid,
    p_view_token text
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
    p_view_token text
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
      and view_token_hash = public.hash_submission_view_token(p_view_token)
      and status in ('completed', 'failed', 'canceled');
    get diagnostics changed = row_count;

    if changed = 0 then
        update public.remote_submissions
        set view_token_hash = encode(extensions.gen_random_bytes(32), 'hex'),
            updated_at = now()
        where id = p_submission_id
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

revoke all on function public.submit_submission(text, uuid, text) from public;
revoke all on function public.get_submission(uuid, text) from public;
revoke all on function public.cancel_submission(uuid, text) from public;
revoke all on function public.retry_submission(uuid, text) from public;
revoke all on function public.clear_submission(uuid, text) from public;
revoke all on function public.claim_next_submission(text) from public;
revoke all on function public.agent_heartbeat_submission(uuid, text) from public;
revoke all on function public.agent_report_submission(uuid, text, text, integer, integer, integer, text, jsonb, text) from public;

grant execute on function public.submit_submission(text, uuid, text) to anon, authenticated;
grant execute on function public.get_submission(uuid, text) to anon, authenticated;
grant execute on function public.cancel_submission(uuid, text) to anon, authenticated;
grant execute on function public.retry_submission(uuid, text) to anon, authenticated;
grant execute on function public.clear_submission(uuid, text) to anon, authenticated;
grant execute on function public.claim_next_submission(text) to service_role;
grant execute on function public.agent_heartbeat_submission(uuid, text) to service_role;
grant execute on function public.agent_report_submission(uuid, text, text, integer, integer, integer, text, jsonb, text) to service_role;
