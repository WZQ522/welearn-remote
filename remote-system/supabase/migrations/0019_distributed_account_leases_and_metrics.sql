begin;

create or replace function public.submission_account_lock_key(p_raw_text text)
returns text
language plpgsql
immutable
strict
set search_path = public, extensions
as $$
declare
    tokens text[];
    platform_name text;
    account_name text;
begin
    tokens := regexp_split_to_array(btrim(p_raw_text), E'\s+');
    platform_name := lower(coalesce(tokens[1], ''));
    if platform_name in ('u校园', 'ucampus') then
        platform_name := 'ucampus';
        account_name := case
            when lower(coalesce(tokens[2], '')) = 'ai' then coalesce(tokens[3], '')
            else coalesce(tokens[2], '')
        end;
    elsif platform_name = 'welearn' then
        account_name := coalesce(tokens[2], '');
    else
        account_name := coalesce(tokens[2], '');
    end if;
    account_name := lower(btrim(account_name));
    if platform_name = '' or account_name = '' then return null; end if;
    return public.hash_remote_secret(platform_name || E'\x1f' || account_name);
end;
$$;

revoke all on function public.submission_account_lock_key(text) from public, anon, authenticated;

alter table public.remote_submissions
    add column if not exists account_lock_key text
        check (account_lock_key is null or char_length(account_lock_key) = 64);

create or replace function public.set_submission_account_lock_key()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    new.account_lock_key := public.submission_account_lock_key(new.raw_text);
    return new;
end;
$$;

revoke all on function public.set_submission_account_lock_key() from public, anon, authenticated;

drop trigger if exists remote_submission_account_lock_key on public.remote_submissions;
create trigger remote_submission_account_lock_key
before insert or update of raw_text on public.remote_submissions
for each row execute function public.set_submission_account_lock_key();

update public.remote_submissions
set account_lock_key = public.submission_account_lock_key(raw_text)
where account_lock_key is distinct from public.submission_account_lock_key(raw_text);

create index if not exists remote_submissions_active_account_idx
    on public.remote_submissions (account_lock_key, heartbeat_at desc)
    where status = 'processing' and account_lock_key is not null;

create or replace function public.claim_next_submission_excluding(
    p_agent_id text,
    p_excluded_submission_ids uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    candidate record;
    selected_id uuid;
    selected_submission public.remote_submissions;
    excluded_ids uuid[] := coalesce(p_excluded_submission_ids, '{}'::uuid[]);
begin
    if p_agent_id is null or char_length(trim(p_agent_id)) not between 1 and 128 then
        raise exception 'invalid_agent_id';
    end if;
    if cardinality(excluded_ids) > 5000 then
        raise exception 'too_many_excluded_submissions';
    end if;

    for candidate in
        select submission.id, submission.account_lock_key
        from public.remote_submissions as submission
        where submission.cancel_requested = false
          and submission.id <> all(excluded_ids)
          and (
              submission.status = 'pending'
              or (
                  submission.status = 'processing'
                  and (
                      submission.agent_id = trim(p_agent_id)
                      or submission.heartbeat_at is null
                      or submission.heartbeat_at < now() - interval '5 minutes'
                  )
              )
          )
        order by
            case
                when submission.status = 'processing' and submission.agent_id = trim(p_agent_id) then 0
                when submission.status = 'processing' then 1
                else 2
            end,
            submission.created_at,
            submission.id
        for update skip locked
        limit 100
    loop
        if candidate.account_lock_key is not null
           and not pg_catalog.pg_try_advisory_xact_lock(
               pg_catalog.hashtextextended(candidate.account_lock_key, 0)
           ) then
            continue;
        end if;
        if candidate.account_lock_key is not null and exists (
            select 1
            from public.remote_submissions as active
            where active.id <> candidate.id
              and active.account_lock_key = candidate.account_lock_key
              and active.status = 'processing'
              and active.cancel_requested = false
              and active.heartbeat_at is not null
              and active.heartbeat_at >= now() - interval '5 minutes'
        ) then
            continue;
        end if;
        selected_id := candidate.id;
        exit;
    end loop;

    if selected_id is null then return null; end if;

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
        'submitted_by', (
            select user_record.username
            from public.remote_users as user_record
            where user_record.id = selected_submission.user_id
        ),
        'line_count', selected_submission.line_count,
        'attempt_count', selected_submission.attempt_count,
        'created_at', selected_submission.created_at
    );
end;
$$;

create or replace function public.claim_next_submission(p_agent_id text)
returns jsonb
language sql
security definer
set search_path = public, extensions
as $$
    select public.claim_next_submission_excluding(p_agent_id, '{}'::uuid[])
$$;

revoke all on function public.claim_next_submission_excluding(text, uuid[]) from public, anon, authenticated;
revoke all on function public.claim_next_submission(text) from public, anon, authenticated;
grant execute on function public.claim_next_submission_excluding(text, uuid[]) to service_role;
grant execute on function public.claim_next_submission(text) to service_role;

create or replace function public.admin_get_queue_metrics(p_session_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    metrics jsonb;
begin
    if public.current_remote_admin_id(p_session_token) is null then
        raise exception 'admin_required';
    end if;

    select jsonb_build_object(
        'pending', count(*) filter (where status = 'pending' and cancel_requested = false),
        'processing', count(*) filter (
            where status = 'processing'
              and heartbeat_at >= now() - interval '5 minutes'
        ),
        'stale', count(*) filter (
            where status = 'processing'
              and (heartbeat_at is null or heartbeat_at < now() - interval '5 minutes')
        ),
        'completed_last_hour', count(*) filter (
            where status = 'completed' and completed_at >= now() - interval '1 hour'
        ),
        'failed_last_hour', count(*) filter (
            where status = 'failed' and completed_at >= now() - interval '1 hour'
        ),
        'active_accounts', count(distinct account_lock_key) filter (
            where status = 'processing'
              and heartbeat_at >= now() - interval '5 minutes'
              and account_lock_key is not null
        ),
        'oldest_pending_seconds', coalesce(
            extract(epoch from now() - min(created_at) filter (
                where status = 'pending' and cancel_requested = false
            ))::bigint,
            0
        ),
        'online_agents', coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'agent_id', agent.agent_id,
                    'active_tasks', agent.active_tasks,
                    'last_heartbeat_at', agent.last_heartbeat_at
                ) order by agent.agent_id
            )
            from (
                select
                    submission.agent_id,
                    count(*)::integer as active_tasks,
                    max(submission.heartbeat_at) as last_heartbeat_at
                from public.remote_submissions as submission
                where submission.status = 'processing'
                  and submission.agent_id is not null
                  and submission.heartbeat_at >= now() - interval '5 minutes'
                group by submission.agent_id
            ) as agent
        ), '[]'::jsonb)
    ) into metrics
    from public.remote_submissions;

    return metrics;
end;
$$;

revoke all on function public.admin_get_queue_metrics(text) from public;
grant execute on function public.admin_get_queue_metrics(text) to anon, authenticated;

commit;
