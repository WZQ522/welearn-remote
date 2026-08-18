begin;

-- Keep the legacy receipt-token status endpoint aligned with the account-scoped
-- list endpoint: callers receive the score summary, never the full processor
-- result payload.
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

revoke all on function public.get_submission(uuid, text, text) from public;
grant execute on function public.get_submission(uuid, text, text) to anon, authenticated;

commit;
