begin;

-- New desktop builds attach a small, validated unit quote to live progress.
-- Keep the seven-argument 0009 RPC in place so an older running desktop can
-- still finish its current task while the website is being upgraded.
create or replace function public.agent_update_submission_progress(
    p_submission_id uuid,
    p_agent_id text,
    p_execution_status text,
    p_task_total integer,
    p_task_completed integer,
    p_task_failed integer,
    p_result_message text,
    p_unit_summary jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    changed integer := 0;
    available_units integer;
    selected_units integer;
    unit_price integer;
    estimated_amount integer;
begin
    if p_execution_status not in ('waiting', 'running', 'needs_action') then
        raise exception 'invalid_execution_status';
    end if;
    if p_task_total < 0 or p_task_completed < 0 or p_task_failed < 0
       or p_task_completed + p_task_failed > p_task_total then
        raise exception 'invalid_task_counts';
    end if;

    if p_unit_summary is not null then
        if jsonb_typeof(p_unit_summary) <> 'object'
           or coalesce(p_unit_summary ->> 'available_unit_count', '') !~ '^[1-9][0-9]*$'
           or coalesce(p_unit_summary ->> 'selected_unit_count', '') !~ '^[1-9][0-9]*$'
           or coalesce(p_unit_summary ->> 'unit_price_cents', '') !~ '^[1-9][0-9]*$'
           or coalesce(p_unit_summary ->> 'estimated_amount_cents', '') !~ '^[1-9][0-9]*$' then
            raise exception 'invalid_unit_summary';
        end if;
        available_units := (p_unit_summary ->> 'available_unit_count')::integer;
        selected_units := (p_unit_summary ->> 'selected_unit_count')::integer;
        unit_price := (p_unit_summary ->> 'unit_price_cents')::integer;
        estimated_amount := (p_unit_summary ->> 'estimated_amount_cents')::integer;
        if selected_units > available_units
           or unit_price <> 50
           or estimated_amount <> selected_units * unit_price then
            raise exception 'invalid_unit_summary';
        end if;
    end if;

    update public.remote_submissions as submission
    set execution_status = p_execution_status,
        task_total = p_task_total,
        task_completed = p_task_completed,
        task_failed = p_task_failed,
        result_message = left(coalesce(p_result_message, ''), 2000),
        result_payload = case
            when p_unit_summary is null then submission.result_payload
            else coalesce(submission.result_payload, '{}'::jsonb)
                || jsonb_build_object('unit_summary', p_unit_summary)
        end,
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

create or replace function public.list_my_submissions(
    p_session_token text,
    p_limit integer default 5000
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
    if p_limit is null or p_limit not between 1 and 5000 then
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
                'batch_id', submission.batch_id,
                'batch_position', submission.batch_position,
                'batch_size', submission.batch_size,
                'task_label', submission.task_label,
                'status', submission.status,
                'execution_status', submission.execution_status,
                'line_count', submission.line_count,
                'task_total', submission.task_total,
                'task_completed', submission.task_completed,
                'task_failed', submission.task_failed,
                'result_message', submission.result_message,
                'score_summary', submission.result_payload -> 'score_summary',
                'unit_summary', submission.result_payload -> 'unit_summary',
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
        'score_summary', submission.result_payload -> 'score_summary',
        'unit_summary', submission.result_payload -> 'unit_summary',
        'error_message', submission.error_message,
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

revoke all on function public.agent_update_submission_progress(uuid, text, text, integer, integer, integer, text, jsonb) from public;
revoke all on function public.list_my_submissions(text, integer) from public;
revoke all on function public.get_submission(uuid, text, text) from public;
grant execute on function public.agent_update_submission_progress(uuid, text, text, integer, integer, integer, text, jsonb) to service_role;
grant execute on function public.list_my_submissions(text, integer) to anon, authenticated;
grant execute on function public.get_submission(uuid, text, text) to anon, authenticated;

commit;
