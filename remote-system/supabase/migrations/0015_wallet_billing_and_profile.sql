begin;

alter table public.remote_users
    add column if not exists balance_cents bigint not null default 0
        check (balance_cents >= 0);

alter table public.remote_submissions
    add column if not exists platform text not null default 'unknown',
    add column if not exists charge_status text not null default 'unpriced',
    add column if not exists charge_amount_cents integer not null default 0,
    add column if not exists charged_at timestamptz,
    add column if not exists refunded_at timestamptz;

do $$
begin
    if not exists (
        select 1 from pg_constraint where conname = 'remote_submissions_platform_check'
    ) then
        alter table public.remote_submissions
            add constraint remote_submissions_platform_check
            check (platform in ('ucampus', 'welearn', 'unknown'));
    end if;
    if not exists (
        select 1 from pg_constraint where conname = 'remote_submissions_charge_status_check'
    ) then
        alter table public.remote_submissions
            add constraint remote_submissions_charge_status_check
            check (charge_status in ('unpriced', 'charged', 'refunded', 'exempt'));
    end if;
    if not exists (
        select 1 from pg_constraint where conname = 'remote_submissions_charge_amount_check'
    ) then
        alter table public.remote_submissions
            add constraint remote_submissions_charge_amount_check
            check (charge_amount_cents >= 0);
    end if;
end;
$$;

create or replace function public.remote_platform_from_line(p_raw_text text)
returns text
language sql
immutable
strict
set search_path = public, extensions
as $$
    select case lower((regexp_match(btrim(p_raw_text), '^\S+'))[1])
        when 'u校园' then 'ucampus'
        when 'ucampus' then 'ucampus'
        when 'welearn' then 'welearn'
        else 'unknown'
    end
$$;

create or replace function public.unit_price_cents_for_platform(p_platform text)
returns integer
language sql
immutable
strict
set search_path = public, extensions
as $$
    select case lower(p_platform)
        when 'ucampus' then 30
        when 'welearn' then 15
        else 0
    end
$$;

create or replace function public.assign_remote_submission_platform()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
    new.platform := public.remote_platform_from_line(new.raw_text);
    return new;
end;
$$;

drop trigger if exists remote_submission_platform_trigger on public.remote_submissions;
create trigger remote_submission_platform_trigger
before insert or update of raw_text on public.remote_submissions
for each row execute function public.assign_remote_submission_platform();

update public.remote_submissions
set platform = public.remote_platform_from_line(raw_text)
where platform = 'unknown';

create table if not exists public.recharge_requests (
    id uuid primary key default extensions.gen_random_uuid(),
    user_id uuid not null references public.remote_users(id) on delete cascade,
    amount_cents integer not null check (amount_cents between 100 and 1000000),
    status text not null default 'pending'
        check (status in ('pending', 'approved', 'rejected')),
    user_note text,
    admin_note text,
    decided_by uuid references public.remote_users(id) on delete set null,
    created_at timestamptz not null default now(),
    decided_at timestamptz
);

create index if not exists recharge_requests_user_idx
    on public.recharge_requests (user_id, created_at desc);
create index if not exists recharge_requests_pending_idx
    on public.recharge_requests (status, created_at)
    where status = 'pending';

create table if not exists public.wallet_transactions (
    id uuid primary key default extensions.gen_random_uuid(),
    user_id uuid not null references public.remote_users(id) on delete cascade,
    submission_id uuid references public.remote_submissions(id) on delete set null,
    recharge_request_id uuid references public.recharge_requests(id) on delete set null,
    transaction_type text not null
        check (transaction_type in ('recharge', 'admin_adjustment', 'task_charge', 'task_refund')),
    amount_cents bigint not null check (amount_cents <> 0),
    balance_after_cents bigint not null check (balance_after_cents >= 0),
    description text not null,
    idempotency_key text not null unique,
    created_at timestamptz not null default now()
);

create index if not exists wallet_transactions_user_idx
    on public.wallet_transactions (user_id, created_at desc);
create index if not exists wallet_transactions_submission_idx
    on public.wallet_transactions (submission_id)
    where submission_id is not null;

alter table public.recharge_requests enable row level security;
alter table public.wallet_transactions enable row level security;
revoke all on table public.recharge_requests from anon, authenticated;
revoke all on table public.wallet_transactions from anon, authenticated;
grant all on table public.recharge_requests to service_role;
grant all on table public.wallet_transactions to service_role;

create or replace function public.canonical_unit_summary(
    p_platform text,
    p_unit_summary jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
    available_units integer;
    selected_units integer;
    unit_price integer;
begin
    if p_unit_summary is null
       or jsonb_typeof(p_unit_summary) <> 'object'
       or coalesce(p_unit_summary ->> 'available_unit_count', '') !~ '^[1-9][0-9]*$'
       or coalesce(p_unit_summary ->> 'selected_unit_count', '') !~ '^[1-9][0-9]*$' then
        raise exception 'invalid_unit_summary';
    end if;
    available_units := (p_unit_summary ->> 'available_unit_count')::integer;
    selected_units := (p_unit_summary ->> 'selected_unit_count')::integer;
    unit_price := public.unit_price_cents_for_platform(p_platform);
    if selected_units > available_units or unit_price <= 0 then
        raise exception 'invalid_unit_summary';
    end if;
    return jsonb_build_object(
        'available_unit_count', available_units,
        'selected_unit_count', selected_units,
        'unit_price_cents', unit_price,
        'estimated_amount_cents', selected_units * unit_price
    );
end;
$$;

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
    submission_platform text;
    canonical_summary jsonb;
begin
    if p_execution_status not in ('waiting', 'running', 'needs_action') then
        raise exception 'invalid_execution_status';
    end if;
    if p_task_total < 0 or p_task_completed < 0 or p_task_failed < 0
       or p_task_completed + p_task_failed > p_task_total then
        raise exception 'invalid_task_counts';
    end if;
    if p_unit_summary is not null then
        select platform into submission_platform
        from public.remote_submissions
        where id = p_submission_id;
        canonical_summary := public.canonical_unit_summary(submission_platform, p_unit_summary);
    end if;

    update public.remote_submissions as submission
    set execution_status = p_execution_status,
        task_total = p_task_total,
        task_completed = p_task_completed,
        task_failed = p_task_failed,
        result_message = left(coalesce(p_result_message, ''), 2000),
        result_payload = case
            when canonical_summary is null then submission.result_payload
            else coalesce(submission.result_payload, '{}'::jsonb)
                || jsonb_build_object('unit_summary', canonical_summary)
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

create or replace function public.agent_authorize_submission_charge(
    p_submission_id uuid,
    p_agent_id text,
    p_unit_summary jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    owner_id uuid;
    submission_platform text;
    current_status text;
    current_charge_status text;
    current_agent text;
    current_attempt integer;
    canceled boolean;
    owner_is_admin boolean;
    owner_balance bigint;
    canonical_summary jsonb;
    charge_amount integer;
    balance_after bigint;
begin
    select submission.user_id,
           submission.platform,
           submission.status,
           submission.charge_status,
           submission.agent_id,
           submission.attempt_count,
           submission.cancel_requested,
           user_record.is_admin,
           user_record.balance_cents
    into owner_id,
         submission_platform,
         current_status,
         current_charge_status,
         current_agent,
         current_attempt,
         canceled,
         owner_is_admin,
         owner_balance
    from public.remote_submissions as submission
    join public.remote_users as user_record on user_record.id = submission.user_id
    where submission.id = p_submission_id
    for update of submission, user_record;

    if owner_id is null
       or current_status <> 'processing'
       or current_agent <> trim(p_agent_id)
       or canceled then
        return jsonb_build_object('authorized', false, 'reason', 'submission_not_active');
    end if;

    canonical_summary := public.canonical_unit_summary(submission_platform, p_unit_summary);
    charge_amount := (canonical_summary ->> 'estimated_amount_cents')::integer;

    if current_charge_status in ('charged', 'exempt') then
        return jsonb_build_object(
            'authorized', true,
            'reason', current_charge_status,
            'amount_cents', case when current_charge_status = 'exempt' then 0 else charge_amount end,
            'balance_cents', owner_balance
        );
    end if;

    if owner_is_admin then
        update public.remote_submissions
        set charge_status = 'exempt',
            charge_amount_cents = 0,
            charged_at = coalesce(charged_at, now()),
            result_payload = coalesce(result_payload, '{}'::jsonb)
                || jsonb_build_object('unit_summary', canonical_summary),
            result_message = '单元识别完成，管理员账号免扣费，开始执行',
            updated_at = now()
        where id = p_submission_id;
        return jsonb_build_object(
            'authorized', true,
            'reason', 'admin_exempt',
            'amount_cents', 0,
            'balance_cents', owner_balance
        );
    end if;

    if owner_balance < charge_amount then
        update public.remote_submissions
        set status = 'failed',
            execution_status = 'failed',
            task_failed = greatest(1, task_total),
            result_payload = coalesce(result_payload, '{}'::jsonb)
                || jsonb_build_object('unit_summary', canonical_summary),
            result_message = '余额不足，任务未开始执行',
            error_message = '余额不足：需要 ' || charge_amount || ' 分，当前 ' || owner_balance || ' 分',
            completed_at = now(),
            heartbeat_at = now(),
            updated_at = now()
        where id = p_submission_id;
        return jsonb_build_object(
            'authorized', false,
            'reason', 'insufficient_balance',
            'amount_cents', charge_amount,
            'balance_cents', owner_balance
        );
    end if;

    update public.remote_users
    set balance_cents = balance_cents - charge_amount
    where id = owner_id
    returning balance_cents into balance_after;

    insert into public.wallet_transactions (
        user_id,
        submission_id,
        transaction_type,
        amount_cents,
        balance_after_cents,
        description,
        idempotency_key
    ) values (
        owner_id,
        p_submission_id,
        'task_charge',
        -charge_amount,
        balance_after,
        case submission_platform when 'ucampus' then 'U校园任务扣费' else 'WeLearn任务扣费' end,
        'task_charge:' || p_submission_id || ':' || current_attempt
    ) on conflict (idempotency_key) do nothing;

    update public.remote_submissions
    set charge_status = 'charged',
        charge_amount_cents = charge_amount,
        charged_at = now(),
        refunded_at = null,
        result_payload = coalesce(result_payload, '{}'::jsonb)
            || jsonb_build_object('unit_summary', canonical_summary),
        result_message = '已扣费，任务开始执行',
        updated_at = now()
    where id = p_submission_id;

    return jsonb_build_object(
        'authorized', true,
        'reason', 'charged',
        'amount_cents', charge_amount,
        'balance_cents', balance_after
    );
end;
$$;

create or replace function public.agent_report_submission(
    p_submission_id uuid,
    p_agent_id text,
    p_execution_status text,
    p_task_total integer,
    p_task_completed integer,
    p_task_failed integer,
    p_result_message text default null,
    p_result jsonb default null,
    p_error_message text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    submission_record public.remote_submissions;
    balance_after bigint;
    canonical_result jsonb;
    refunded_this_report boolean := false;
begin
    if p_execution_status not in ('needs_action', 'completed', 'partial', 'failed') then
        raise exception 'invalid_execution_status';
    end if;
    if p_task_total < 0 or p_task_completed < 0 or p_task_failed < 0
       or p_task_completed + p_task_failed > p_task_total then
        raise exception 'invalid_task_counts';
    end if;

    select * into submission_record
    from public.remote_submissions
    where id = p_submission_id
      and agent_id = trim(p_agent_id)
      and status = 'processing'
    for update;
    if submission_record.id is null then
        return false;
    end if;
    if not submission_record.cancel_requested
       and p_execution_status in ('completed', 'partial')
       and submission_record.charge_status not in ('charged', 'exempt') then
        raise exception 'charge_required';
    end if;

    if not submission_record.cancel_requested
       and p_execution_status = 'failed'
       and submission_record.charge_status = 'charged'
       and submission_record.charge_amount_cents > 0 then
        update public.remote_users
        set balance_cents = balance_cents + submission_record.charge_amount_cents
        where id = submission_record.user_id
        returning balance_cents into balance_after;

        insert into public.wallet_transactions (
            user_id,
            submission_id,
            transaction_type,
            amount_cents,
            balance_after_cents,
            description,
            idempotency_key
        ) values (
            submission_record.user_id,
            submission_record.id,
            'task_refund',
            submission_record.charge_amount_cents,
            balance_after,
            '任务执行失败，自动退款',
            'task_refund:' || submission_record.id || ':' || submission_record.attempt_count
        ) on conflict (idempotency_key) do nothing;

        submission_record.charge_status := 'refunded';
        refunded_this_report := true;
    end if;

    canonical_result := coalesce(p_result, '{}'::jsonb) - 'unit_summary';
    if submission_record.result_payload ? 'unit_summary' then
        canonical_result := canonical_result || jsonb_build_object(
            'unit_summary', submission_record.result_payload -> 'unit_summary'
        );
    end if;

    update public.remote_submissions
    set status = case
            when submission_record.cancel_requested then 'canceled'
            when p_execution_status = 'failed' then 'failed'
            else 'completed'
        end,
        execution_status = case
            when submission_record.cancel_requested then submission_record.execution_status
            else p_execution_status
        end,
        task_total = p_task_total,
        task_completed = p_task_completed,
        task_failed = p_task_failed,
        result_message = case
            when submission_record.cancel_requested then '已取消，已发生的任务费用不退还'
            when p_execution_status = 'failed' and refunded_this_report
                then left(coalesce(p_result_message, '任务执行失败'), 1940) || '；费用已自动退还'
            else left(coalesce(p_result_message, ''), 2000)
        end,
        result_payload = case
            when submission_record.cancel_requested then submission_record.result_payload
            else canonical_result
        end,
        error_message = case
            when submission_record.cancel_requested then 'Canceled from web console'
            when p_execution_status = 'failed' then left(coalesce(p_error_message, p_result_message, 'Processor failed'), 2000)
            else null
        end,
        charge_status = submission_record.charge_status,
        refunded_at = case
            when submission_record.charge_status = 'refunded' then now()
            else refunded_at
        end,
        heartbeat_at = now(),
        completed_at = now(),
        updated_at = now()
    where id = p_submission_id;
    return true;
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
    if owner_id is null then raise exception 'login_required'; end if;
    update public.remote_submissions as submission
    set cancel_requested = true,
        status = 'canceled',
        result_message = case
            when submission.charge_status = 'charged' then '已取消，已发生的任务费用不退还'
            else '已取消'
        end,
        completed_at = now(),
        updated_at = now()
    where submission.id = p_submission_id
      and submission.user_id = owner_id
      and submission.status in ('pending', 'processing');
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

create or replace function public.cancel_submission(
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
    set cancel_requested = true,
        status = 'canceled',
        result_message = case
            when submission.charge_status = 'charged' then '已取消，已发生的任务费用不退还'
            else '已取消'
        end,
        completed_at = now(),
        updated_at = now()
    where submission.id = p_submission_id
      and submission.user_id = public.current_remote_user_id(p_session_token)
      and submission.view_token_hash = public.hash_submission_view_token(p_view_token)
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
    if owner_id is null then raise exception 'login_required'; end if;
    delete from public.remote_submissions as submission
    where submission.id = p_submission_id
      and submission.user_id = owner_id
      and submission.status in ('completed', 'failed', 'canceled');
    get diagnostics deleted = row_count;
    return deleted = 1;
end;
$$;

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
      and submission.view_token_hash = public.hash_submission_view_token(p_view_token)
      and submission.status in ('completed', 'failed', 'canceled');
    get diagnostics deleted = row_count;
    return deleted = 1;
end;
$$;

create or replace function public.get_my_profile(
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
    profile jsonb;
begin
    if p_limit is null or p_limit not between 1 and 200 then raise exception 'invalid_limit'; end if;
    owner_id := public.current_remote_user_id(p_session_token);
    if owner_id is null then raise exception 'login_required'; end if;

    select jsonb_build_object(
        'username', user_record.username,
        'is_admin', user_record.is_admin,
        'balance_cents', user_record.balance_cents,
        'pricing', jsonb_build_object('ucampus_unit_cents', 30, 'welearn_unit_cents', 15),
        'total_charged_cents', coalesce((
            select -sum(amount_cents) from public.wallet_transactions
            where user_id = owner_id and transaction_type = 'task_charge'
        ), 0),
        'total_refunded_cents', coalesce((
            select sum(amount_cents) from public.wallet_transactions
            where user_id = owner_id and transaction_type = 'task_refund'
        ), 0),
        'recharge_requests', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', request.id,
                'amount_cents', request.amount_cents,
                'status', request.status,
                'user_note', request.user_note,
                'admin_note', request.admin_note,
                'created_at', request.created_at,
                'decided_at', request.decided_at
            ) order by request.created_at desc)
            from (select * from public.recharge_requests where user_id = owner_id order by created_at desc limit p_limit) request
        ), '[]'::jsonb),
        'transactions', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', wallet_entry.id,
                'type', wallet_entry.transaction_type,
                'amount_cents', wallet_entry.amount_cents,
                'balance_after_cents', wallet_entry.balance_after_cents,
                'description', wallet_entry.description,
                'created_at', wallet_entry.created_at
            ) order by wallet_entry.created_at desc)
            from (select * from public.wallet_transactions where user_id = owner_id order by created_at desc limit p_limit) wallet_entry
        ), '[]'::jsonb)
    ) into profile
    from public.remote_users as user_record
    where user_record.id = owner_id;
    return profile;
end;
$$;

create or replace function public.create_recharge_request(
    p_session_token text,
    p_amount_cents integer,
    p_user_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    owner_id uuid;
    created_request public.recharge_requests;
begin
    owner_id := public.current_remote_user_id(p_session_token);
    if owner_id is null then raise exception 'login_required'; end if;
    if p_amount_cents is null or p_amount_cents not between 100 and 1000000 then
        raise exception 'invalid_recharge_amount';
    end if;
    if (select count(*) from public.recharge_requests where user_id = owner_id and status = 'pending') >= 3 then
        raise exception 'too_many_pending_recharges';
    end if;
    insert into public.recharge_requests (user_id, amount_cents, user_note)
    values (owner_id, p_amount_cents, nullif(left(btrim(coalesce(p_user_note, '')), 200), ''))
    returning * into created_request;
    return jsonb_build_object(
        'id', created_request.id,
        'amount_cents', created_request.amount_cents,
        'status', created_request.status,
        'created_at', created_request.created_at
    );
end;
$$;

create or replace function public.admin_list_recharge_requests(
    p_session_token text,
    p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_remote_admin(p_session_token) then raise exception 'admin_required'; end if;
    if p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_limit'; end if;
    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', request.id,
            'user_id', request.user_id,
            'username', user_record.username,
            'amount_cents', request.amount_cents,
            'status', request.status,
            'user_note', request.user_note,
            'admin_note', request.admin_note,
            'created_at', request.created_at,
            'decided_at', request.decided_at
        ) order by case when request.status = 'pending' then 0 else 1 end, request.created_at desc)
        from (
            select * from public.recharge_requests
            order by case when status = 'pending' then 0 else 1 end, created_at desc
            limit p_limit
        ) request
        join public.remote_users user_record on user_record.id = request.user_id
    ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_decide_recharge_request(
    p_session_token text,
    p_request_id uuid,
    p_decision text,
    p_admin_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    admin_id uuid;
    request_record public.recharge_requests;
    balance_after bigint;
begin
    if not public.is_remote_admin(p_session_token) then raise exception 'admin_required'; end if;
    admin_id := public.current_remote_user_id(p_session_token);
    if p_decision not in ('approved', 'rejected') then raise exception 'invalid_recharge_decision'; end if;
    select * into request_record
    from public.recharge_requests
    where id = p_request_id
    for update;
    if request_record.id is null then raise exception 'recharge_request_not_found'; end if;
    if request_record.status <> 'pending' then
        return request_record.status = p_decision;
    end if;

    if p_decision = 'approved' then
        update public.remote_users
        set balance_cents = balance_cents + request_record.amount_cents
        where id = request_record.user_id
        returning balance_cents into balance_after;
        insert into public.wallet_transactions (
            user_id,
            recharge_request_id,
            transaction_type,
            amount_cents,
            balance_after_cents,
            description,
            idempotency_key
        ) values (
            request_record.user_id,
            request_record.id,
            'recharge',
            request_record.amount_cents,
            balance_after,
            '管理员确认充值到账',
            'recharge:' || request_record.id
        ) on conflict (idempotency_key) do nothing;
    end if;

    update public.recharge_requests
    set status = p_decision,
        admin_note = nullif(left(btrim(coalesce(p_admin_note, '')), 200), ''),
        decided_by = admin_id,
        decided_at = now()
    where id = request_record.id;
    return true;
end;
$$;

create or replace function public.admin_adjust_remote_user_balance(
    p_session_token text,
    p_target_user_id uuid,
    p_amount_cents integer,
    p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    target_user public.remote_users;
    balance_after bigint;
    transaction_id uuid := extensions.gen_random_uuid();
begin
    if not public.is_remote_admin(p_session_token) then raise exception 'admin_required'; end if;
    if p_amount_cents is null or p_amount_cents = 0 or abs(p_amount_cents) > 1000000 then
        raise exception 'invalid_adjustment_amount';
    end if;
    if btrim(coalesce(p_reason, '')) = '' then raise exception 'adjustment_reason_required'; end if;
    select * into target_user from public.remote_users where id = p_target_user_id for update;
    if target_user.id is null then raise exception 'remote_user_not_found'; end if;
    if target_user.is_admin then raise exception 'admin_target_protected'; end if;
    if target_user.balance_cents + p_amount_cents < 0 then raise exception 'insufficient_balance'; end if;

    update public.remote_users
    set balance_cents = balance_cents + p_amount_cents
    where id = target_user.id
    returning balance_cents into balance_after;
    insert into public.wallet_transactions (
        id,
        user_id,
        transaction_type,
        amount_cents,
        balance_after_cents,
        description,
        idempotency_key
    ) values (
        transaction_id,
        target_user.id,
        'admin_adjustment',
        p_amount_cents,
        balance_after,
        left(btrim(p_reason), 200),
        'admin_adjustment:' || transaction_id
    );
    return jsonb_build_object('balance_cents', balance_after);
end;
$$;

create or replace function public.admin_list_remote_users(p_session_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_remote_admin(p_session_token) then raise exception 'admin_required'; end if;
    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', user_record.id,
            'username', user_record.username,
            'is_admin', user_record.is_admin,
            'balance_cents', user_record.balance_cents,
            'created_at', user_record.created_at,
            'last_login_at', user_record.last_login_at
        ) order by user_record.created_at desc)
        from public.remote_users as user_record
    ), '[]'::jsonb);
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
begin
    if p_limit is null or p_limit not between 1 and 5000 then raise exception 'invalid_limit'; end if;
    owner_id := public.current_remote_user_id(p_session_token);
    if owner_id is null then raise exception 'login_required'; end if;
    return coalesce((
        select jsonb_agg(record.payload order by record.created_at desc)
        from (
            select submission.created_at,
                   jsonb_build_object(
                       'id', submission.id,
                       'batch_id', submission.batch_id,
                       'batch_position', submission.batch_position,
                       'batch_size', submission.batch_size,
                       'task_label', submission.task_label,
                       'platform', submission.platform,
                       'status', submission.status,
                       'execution_status', submission.execution_status,
                       'line_count', submission.line_count,
                       'task_total', submission.task_total,
                       'task_completed', submission.task_completed,
                       'task_failed', submission.task_failed,
                       'result_message', submission.result_message,
                       'score_summary', submission.result_payload -> 'score_summary',
                       'unit_summary', submission.result_payload -> 'unit_summary',
                       'charge_status', submission.charge_status,
                       'charge_amount_cents', submission.charge_amount_cents,
                       'charged_at', submission.charged_at,
                       'refunded_at', submission.refunded_at,
                       'error_message', submission.error_message,
                       'attempt_count', submission.attempt_count,
                       'cancel_requested', submission.cancel_requested,
                       'created_at', submission.created_at,
                       'updated_at', submission.updated_at,
                       'completed_at', submission.completed_at
                   ) payload
            from public.remote_submissions submission
            where submission.user_id = owner_id
            order by submission.created_at desc
            limit p_limit
        ) record
    ), '[]'::jsonb);
end;
$$;

revoke all on function public.agent_update_submission_progress(uuid, text, text, integer, integer, integer, text, jsonb) from public;
revoke all on function public.agent_authorize_submission_charge(uuid, text, jsonb) from public;
revoke all on function public.agent_report_submission(uuid, text, text, integer, integer, integer, text, jsonb, text) from public;
revoke all on function public.get_my_profile(text, integer) from public;
revoke all on function public.create_recharge_request(text, integer, text) from public;
revoke all on function public.admin_list_recharge_requests(text, integer) from public;
revoke all on function public.admin_decide_recharge_request(text, uuid, text, text) from public;
revoke all on function public.admin_adjust_remote_user_balance(text, uuid, integer, text) from public;
revoke all on function public.delete_my_submission(uuid, text) from public;
revoke all on function public.delete_submission(uuid, text, text) from public;

grant execute on function public.agent_update_submission_progress(uuid, text, text, integer, integer, integer, text, jsonb) to service_role;
grant execute on function public.agent_authorize_submission_charge(uuid, text, jsonb) to service_role;
grant execute on function public.agent_report_submission(uuid, text, text, integer, integer, integer, text, jsonb, text) to service_role;
grant execute on function public.get_my_profile(text, integer) to anon, authenticated;
grant execute on function public.create_recharge_request(text, integer, text) to anon, authenticated;
grant execute on function public.admin_list_recharge_requests(text, integer) to anon, authenticated;
grant execute on function public.admin_decide_recharge_request(text, uuid, text, text) to anon, authenticated;
grant execute on function public.admin_adjust_remote_user_balance(text, uuid, integer, text) to anon, authenticated;
grant execute on function public.delete_my_submission(uuid, text) to anon, authenticated;
grant execute on function public.delete_submission(uuid, text, text) to anon, authenticated;

commit;
