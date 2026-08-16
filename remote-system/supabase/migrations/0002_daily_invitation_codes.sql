create extension if not exists pg_cron with schema extensions;

do $$
declare
    existing_job_id bigint;
begin
    select jobid into existing_job_id
    from cron.job
    where jobname = 'welearn-daily-invitation-codes';

    if existing_job_id is not null then
        perform cron.unschedule(existing_job_id);
    end if;

    perform cron.schedule(
        'welearn-daily-invitation-codes',
        '0 16 * * *',
        $command$select public.issue_invitation_codes(10);$command$
    );

    if not exists (
        select 1
        from public.invitation_codes
        where issue_date = (timezone('Asia/Shanghai', now()))::date
    ) then
        perform public.issue_invitation_codes(10);
    end if;
end;
$$;
