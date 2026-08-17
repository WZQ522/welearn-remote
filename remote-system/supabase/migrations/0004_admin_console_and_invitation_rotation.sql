create or replace function public.issue_invitation_codes(p_count integer default 10)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    current_issue_date date := (timezone('Asia/Shanghai', now()))::date;
    generated_count integer := 0;
    candidate text;
    inserted_id uuid;
    generated_codes jsonb := '[]'::jsonb;
begin
    if p_count is null or p_count < 1 or p_count > 1000 then
        raise exception 'invalid_invitation_count';
    end if;

    perform pg_advisory_xact_lock(hashtext('remote-invitation-codes:' || current_issue_date::text));

    delete from public.invitation_codes
    where issue_date = current_issue_date
      and used_at is null;

    while generated_count < p_count loop
        candidate := upper(encode(extensions.gen_random_bytes(16), 'hex'));
        inserted_id := null;

        insert into public.invitation_codes (code_hash, code_text, issue_date)
        values (
            public.hash_remote_secret(candidate),
            candidate,
            current_issue_date
        )
        on conflict (code_hash) do nothing
        returning id into inserted_id;

        if inserted_id is not null then
            generated_count := generated_count + 1;
            generated_codes := generated_codes || to_jsonb(candidate);
        end if;
    end loop;

    return generated_codes;
end;
$$;

revoke all on function public.issue_invitation_codes(integer) from public, anon, authenticated;
grant execute on function public.issue_invitation_codes(integer) to service_role;

create or replace function public.admin_list_invitation_codes(
    p_session_token text,
    p_issue_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    requested_date date := coalesce(p_issue_date, (timezone('Asia/Shanghai', now()))::date);
begin
    if public.current_remote_admin_id(p_session_token) is null then
        raise exception 'admin_required';
    end if;

    return coalesce(
        (
            select jsonb_agg(
                jsonb_build_object(
                    'code', invitation.code_text,
                    'issue_date', invitation.issue_date,
                    'used_at', invitation.used_at,
                    'used_by', invitation.used_by,
                    'used_username', user_record.username,
                    'created_at', invitation.created_at
                ) order by invitation.used_at nulls first, invitation.created_at desc
            )
            from public.invitation_codes as invitation
            left join public.remote_users as user_record on user_record.id = invitation.used_by
            where invitation.issue_date = requested_date
        ),
        '[]'::jsonb
    );
end;
$$;

revoke all on function public.admin_list_invitation_codes(text, date) from public, anon, authenticated;
grant execute on function public.admin_list_invitation_codes(text, date) to anon, authenticated;

create or replace function public.admin_list_remote_users(p_session_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
    if public.current_remote_admin_id(p_session_token) is null then
        raise exception 'admin_required';
    end if;

    return coalesce(
        (
            select jsonb_agg(
                jsonb_build_object(
                    'id', user_record.id,
                    'username', user_record.username,
                    'is_admin', user_record.is_admin,
                    'created_at', user_record.created_at,
                    'last_login_at', user_record.last_login_at
                ) order by user_record.created_at desc
            )
            from public.remote_users as user_record
        ),
        '[]'::jsonb
    );
end;
$$;

revoke all on function public.admin_list_remote_users(text) from public, anon, authenticated;
grant execute on function public.admin_list_remote_users(text) to anon, authenticated;

do $$
begin
    perform public.issue_invitation_codes(10);
end;
$$;
