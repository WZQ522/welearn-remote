begin;

create or replace function public.agent_update_submission_progress(
    p_submission_id uuid,
    p_agent_id text,
    p_execution_status text,
    p_task_total integer,
    p_task_completed integer,
    p_task_failed integer,
    p_result_message text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer := 0;
begin
    if p_execution_status not in ('waiting', 'running', 'needs_action') then
        raise exception 'invalid_execution_status';
    end if;
    if p_task_total < 0 or p_task_completed < 0 or p_task_failed < 0
       or p_task_completed + p_task_failed > p_task_total then
        raise exception 'invalid_task_counts';
    end if;

    update public.remote_submissions as submission
    set execution_status = p_execution_status,
        task_total = p_task_total,
        task_completed = p_task_completed,
        task_failed = p_task_failed,
        result_message = left(coalesce(p_result_message, ''), 2000),
        heartbeat_at = now(),
        updated_at = now()
    where submission.id = p_submission_id
      and submission.agent_id = trim(p_agent_id)
      and submission.status = 'processing'
      and submission.cancel_requested = false;
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

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

    select submission.id into selected_id
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

revoke all on function public.agent_update_submission_progress(uuid, text, text, integer, integer, integer, text) from public;
revoke all on function public.claim_next_submission_excluding(text, uuid[]) from public;
grant execute on function public.agent_update_submission_progress(uuid, text, text, integer, integer, integer, text) to service_role;
grant execute on function public.claim_next_submission_excluding(text, uuid[]) to service_role;

commit;
