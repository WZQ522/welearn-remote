begin;

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

revoke all on function public.claim_next_submission_excluding(text, uuid[]) from public;
grant execute on function public.claim_next_submission_excluding(text, uuid[]) to service_role;

commit;
