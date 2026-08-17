begin;

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
                'result_payload', submission.result_payload,
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

revoke all on function public.list_my_submissions(text, integer) from public;
grant execute on function public.list_my_submissions(text, integer) to anon, authenticated;

commit;
