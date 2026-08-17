begin;

alter table public.remote_submissions
    add column if not exists batch_id uuid not null default extensions.gen_random_uuid(),
    add column if not exists batch_position integer not null default 1 check (batch_position > 0),
    add column if not exists batch_size integer not null default 1 check (batch_size > 0),
    add column if not exists task_label text not null default '旧版批量任务';

update public.remote_submissions
set task_label = '旧版批量任务 · ' || line_count || ' 条账号'
where task_label = '旧版批量任务';

create index if not exists remote_submissions_batch_idx
    on public.remote_submissions (user_id, batch_id, batch_position);

create or replace function public.submit_account_batch(
    p_raw_text text,
    p_client_id uuid,
    p_view_token text,
    p_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    authenticated_user_id uuid;
    calculated_line_count integer;
    created_batch_id uuid := extensions.gen_random_uuid();
    batch_created_at timestamptz := clock_timestamp();
    entry record;
    tokens text[];
    platform_label text;
    account_label text;
    display_label text;
begin
    authenticated_user_id := public.current_remote_user_id(p_session_token);
    if authenticated_user_id is null then
        raise exception 'login_required';
    end if;
    if p_raw_text is null or btrim(p_raw_text) = '' then
        raise exception 'raw_text_required';
    end if;
    if octet_length(p_raw_text) > 200000 then
        raise exception 'raw_text_too_large';
    end if;
    if p_view_token is null or char_length(p_view_token) < 32 or char_length(p_view_token) > 256 then
        raise exception 'invalid_view_token';
    end if;

    select count(*)::integer into calculated_line_count
    from regexp_split_to_table(p_raw_text, E'\r?\n') as source(line)
    where btrim(source.line) <> '';

    if calculated_line_count < 1 or calculated_line_count > 5000 then
        raise exception 'invalid_line_count';
    end if;

    for entry in
        select
            btrim(source.line) as raw_line,
            row_number() over (order by source.source_position)::integer as position
        from regexp_split_to_table(p_raw_text, E'\r?\n') with ordinality as source(line, source_position)
        where btrim(source.line) <> ''
        order by source.source_position
    loop
        tokens := regexp_split_to_array(entry.raw_line, E'\s+');
        if lower(coalesce(tokens[1], '')) in ('u校园', 'ucampus')
           and lower(coalesce(tokens[2], '')) = 'ai' then
            platform_label := 'U校园';
            account_label := coalesce(tokens[3], '');
        else
            platform_label := case lower(coalesce(tokens[1], ''))
                when 'u校园' then 'U校园'
                when 'ucampus' then 'U校园'
                when 'welearn' then 'WeLearn'
                else coalesce(tokens[1], '任务')
            end;
            account_label := coalesce(tokens[2], '');
        end if;
        display_label := left(
            case when account_label = ''
                then platform_label || ' · 账号任务 ' || entry.position
                else platform_label || ' · ' || account_label
            end,
            180
        );

        insert into public.remote_submissions (
            client_id,
            user_id,
            view_token_hash,
            raw_text,
            line_count,
            task_total,
            batch_id,
            batch_position,
            batch_size,
            task_label,
            created_at,
            updated_at
        ) values (
            p_client_id,
            authenticated_user_id,
            public.hash_submission_view_token(p_view_token),
            entry.raw_line,
            1,
            1,
            created_batch_id,
            entry.position,
            calculated_line_count,
            display_label,
            batch_created_at + ((entry.position - 1) * interval '1 microsecond'),
            batch_created_at
        );
    end loop;

    return jsonb_build_object(
        'id', created_batch_id,
        'batch_id', created_batch_id,
        'status', 'pending',
        'execution_status', 'waiting',
        'line_count', calculated_line_count,
        'created_at', batch_created_at
    );
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

revoke all on function public.submit_account_batch(text, uuid, text, text) from public;
grant execute on function public.submit_account_batch(text, uuid, text, text) to anon, authenticated;

commit;
