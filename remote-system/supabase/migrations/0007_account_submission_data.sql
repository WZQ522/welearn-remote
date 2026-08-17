begin;

create or replace function public.list_my_submissions(
    p_session_token text,
    p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    owner_id uuid;
    submissions jsonb;
begin
    if p_limit is null or p_limit not between 1 and 200 then
        raise exception 'invalid_limit';
    end if;

    owner_id := public.current_remote_user_id(p_session_token);
    if owner_id is null then
        raise exception 'login_required';
    end if;
    select coalesce(jsonb_agg(record.payload order by record.created_at desc), '[]'::jsonb)
    into submissions
    from (
        select
            submission.created_at,
            jsonb_build_object(
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
            ) as payload
        from public.remote_submissions as submission
        where submission.user_id = owner_id
        order by submission.created_at desc
        limit p_limit
    ) as record;
    return submissions;
end;
$$;

create or replace function public.cancel_my_submission(
    p_submission_id uuid,
    p_session_token text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer := 0;
    owner_id uuid;
begin
    owner_id := public.current_remote_user_id(p_session_token);
    if owner_id is null then
        raise exception 'login_required';
    end if;
    update public.remote_submissions as submission
    set cancel_requested = true,
        status = case when submission.status = 'pending' then 'canceled' else submission.status end,
        result_message = case when submission.status = 'pending' then '已取消' else submission.result_message end,
        completed_at = case when submission.status = 'pending' then now() else submission.completed_at end,
        updated_at = now()
    where submission.id = p_submission_id
      and submission.user_id = owner_id
      and submission.status in ('pending', 'processing');
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

create or replace function public.retry_my_submission(
    p_submission_id uuid,
    p_session_token text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer := 0;
    owner_id uuid;
begin
    owner_id := public.current_remote_user_id(p_session_token);
    if owner_id is null then
        raise exception 'login_required';
    end if;
    update public.remote_submissions as submission
    set status = 'pending',
        execution_status = 'waiting',
        task_total = submission.line_count,
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
    where submission.id = p_submission_id
      and submission.user_id = owner_id
      and (
          submission.status in ('failed', 'canceled')
          or submission.execution_status in ('needs_action', 'partial', 'failed')
      );
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

create or replace function public.delete_my_submission(
    p_submission_id uuid,
    p_session_token text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    deleted integer := 0;
    owner_id uuid;
begin
    owner_id := public.current_remote_user_id(p_session_token);
    if owner_id is null then
        raise exception 'login_required';
    end if;
    delete from public.remote_submissions as submission
    where submission.id = p_submission_id
      and submission.user_id = owner_id;
    get diagnostics deleted = row_count;
    return deleted = 1;
end;
$$;

revoke all on function public.list_my_submissions(text, integer) from public;
revoke all on function public.cancel_my_submission(uuid, text) from public;
revoke all on function public.retry_my_submission(uuid, text) from public;
revoke all on function public.delete_my_submission(uuid, text) from public;

grant execute on function public.list_my_submissions(text, integer) to anon, authenticated;
grant execute on function public.cancel_my_submission(uuid, text) to anon, authenticated;
grant execute on function public.retry_my_submission(uuid, text) to anon, authenticated;
grant execute on function public.delete_my_submission(uuid, text) to anon, authenticated;

commit;
