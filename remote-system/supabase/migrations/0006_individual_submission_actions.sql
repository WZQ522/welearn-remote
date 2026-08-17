begin;

create or replace function public.delete_submission(
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
    deleted integer := 0;
begin
    delete from public.remote_submissions as submission
    where submission.id = p_submission_id
      and submission.user_id = public.current_remote_user_id(p_session_token)
      and submission.view_token_hash = public.hash_submission_view_token(p_view_token);
    get diagnostics deleted = row_count;
    return deleted = 1;
end;
$$;

revoke all on function public.delete_submission(uuid, text, text) from public;
grant execute on function public.delete_submission(uuid, text, text) to anon, authenticated;

commit;
