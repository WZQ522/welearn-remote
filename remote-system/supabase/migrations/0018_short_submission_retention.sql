begin;

-- Terminal submissions no longer need the submitted platform credential.
-- Keep pending/processing input available to the Agent, but permit redaction
-- as soon as a submission reaches a terminal state.
alter table public.remote_submissions
    alter column raw_text drop not null;

alter table public.remote_submissions
    drop constraint if exists remote_submissions_raw_text_check;

alter table public.remote_submissions
    add constraint remote_submissions_raw_text_check
    check (
        (status in ('pending', 'processing')
            and raw_text is not null
            and char_length(raw_text) between 1 and 200000)
        or
        (status in ('completed', 'failed', 'canceled') and raw_text is null)
    ) not valid;

create or replace function public.assign_remote_submission_platform()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
    if new.raw_text is not null then
        new.platform := public.remote_platform_from_line(new.raw_text);
    end if;
    return new;
end;
$$;

create or replace function public.apply_remote_submission_terminal_retention()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
    if new.status in ('completed', 'failed', 'canceled') then
        new.raw_text := null;
    end if;
    return new;
end;
$$;

drop trigger if exists remote_submission_terminal_retention_trigger
    on public.remote_submissions;
create trigger remote_submission_terminal_retention_trigger
before insert or update of status on public.remote_submissions
for each row execute function public.apply_remote_submission_terminal_retention();

create or replace function public.delete_canceled_remote_submission()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
    if new.status = 'canceled' then
        delete from public.remote_submissions where id = new.id;
    end if;
    return null;
end;
$$;

drop trigger if exists remote_submission_canceled_delete_trigger
    on public.remote_submissions;
create trigger remote_submission_canceled_delete_trigger
after insert or update of status on public.remote_submissions
for each row execute function public.delete_canceled_remote_submission();

-- Redacted terminal rows cannot be retried in place. A fresh submission is
-- required so that no credential is recreated from history.
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
    if owner_id is null then raise exception 'login_required'; end if;
    update public.remote_submissions as submission
    set status = 'pending',
        execution_status = 'waiting',
        task_total = submission.line_count,
        task_completed = 0,
        task_failed = 0,
        result_message = null,
        result_payload = case when submission.charge_status in ('charged', 'exempt')
            then submission.result_payload else null end,
        error_message = null,
        agent_id = null,
        cancel_requested = false,
        claimed_at = null,
        heartbeat_at = null,
        completed_at = null,
        charge_status = case when submission.charge_status = 'refunded' then 'unpriced' else submission.charge_status end,
        charge_amount_cents = case when submission.charge_status = 'refunded' then 0 else submission.charge_amount_cents end,
        charged_at = case when submission.charge_status = 'refunded' then null else submission.charged_at end,
        refunded_at = case when submission.charge_status = 'refunded' then null else submission.refunded_at end,
        updated_at = now()
    where submission.id = p_submission_id
      and submission.user_id = owner_id
      and submission.raw_text is not null
      and (
          submission.status in ('failed', 'canceled')
          or submission.execution_status in ('needs_action', 'partial', 'failed')
      );
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
    changed integer := 0;
begin
    update public.remote_submissions as submission
    set status = 'pending',
        execution_status = 'waiting',
        task_total = submission.line_count,
        task_completed = 0,
        task_failed = 0,
        result_message = null,
        result_payload = case when submission.charge_status in ('charged', 'exempt')
            then submission.result_payload else null end,
        error_message = null,
        agent_id = null,
        cancel_requested = false,
        claimed_at = null,
        heartbeat_at = null,
        completed_at = null,
        charge_status = case when submission.charge_status = 'refunded' then 'unpriced' else submission.charge_status end,
        charge_amount_cents = case when submission.charge_status = 'refunded' then 0 else submission.charge_amount_cents end,
        charged_at = case when submission.charge_status = 'refunded' then null else submission.charged_at end,
        refunded_at = case when submission.charge_status = 'refunded' then null else submission.refunded_at end,
        updated_at = now()
    where submission.id = p_submission_id
      and submission.user_id = public.current_remote_user_id(p_session_token)
      and submission.view_token_hash = public.hash_submission_view_token(p_view_token)
      and submission.raw_text is not null
      and (
          submission.status in ('failed', 'canceled')
          or submission.execution_status in ('needs_action', 'partial', 'failed')
      );
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

create or replace function public.cleanup_remote_submission_retention()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    redacted_count integer := 0;
    canceled_count integer := 0;
    expired_count integer := 0;
begin
    delete from public.remote_submissions
    where status = 'canceled';
    get diagnostics canceled_count = row_count;

    update public.remote_submissions
    set raw_text = null,
        updated_at = now()
    where status in ('completed', 'failed')
      and raw_text is not null;
    get diagnostics redacted_count = row_count;

    delete from public.remote_submissions
    where status in ('completed', 'failed')
      and coalesce(completed_at, updated_at, created_at) < now() - interval '3 days';
    get diagnostics expired_count = row_count;

    return jsonb_build_object(
        'redacted', redacted_count,
        'canceled_deleted', canceled_count,
        'expired_deleted', expired_count
    );
end;
$$;

revoke all on function public.apply_remote_submission_terminal_retention()
    from public, anon, authenticated;
revoke all on function public.delete_canceled_remote_submission()
    from public, anon, authenticated;
revoke all on function public.cleanup_remote_submission_retention()
    from public, anon, authenticated;
grant execute on function public.cleanup_remote_submission_retention()
    to service_role;

-- Apply the policy to existing data before scheduling recurring cleanup.
select public.cleanup_remote_submission_retention();

alter table public.remote_submissions
    validate constraint remote_submissions_raw_text_check;

do $$
declare
    existing_job_id bigint;
begin
    select jobid into existing_job_id
    from cron.job
    where jobname = 'welearn-short-submission-retention';

    if existing_job_id is not null then
        perform cron.unschedule(existing_job_id);
    end if;

    perform cron.schedule(
        'welearn-short-submission-retention',
        '17 * * * *',
        $command$select public.cleanup_remote_submission_retention();$command$
    );
end;
$$;

commit;
