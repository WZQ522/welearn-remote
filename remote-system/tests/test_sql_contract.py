from __future__ import annotations

import unittest
from pathlib import Path


SQL = (Path(__file__).resolve().parents[1] / "supabase/migrations/0001_remote_tasks.sql").read_text(encoding="utf-8")
CRON_SQL = (Path(__file__).resolve().parents[1] / "supabase/migrations/0002_daily_invitation_codes.sql").read_text(
    encoding="utf-8"
)
ADMIN_SQL = (Path(__file__).resolve().parents[1] / "supabase/migrations/0003_admin_accounts.sql").read_text(
    encoding="utf-8"
)
ADMIN_CONSOLE_SQL = (
    Path(__file__).resolve().parents[1] / "supabase/migrations/0004_admin_console_and_invitation_rotation.sql"
).read_text(encoding="utf-8")


class SQLContractTests(unittest.TestCase):
    def test_public_clients_use_rpc_instead_of_direct_table_access(self) -> None:
        self.assertIn("alter table public.remote_submissions enable row level security", SQL)
        self.assertIn("revoke all on table public.remote_submissions from anon, authenticated", SQL)
        self.assertNotIn("grant select on table public.remote_submissions to anon", SQL)

    def test_agent_claim_is_atomic_and_restart_aware(self) -> None:
        self.assertIn("for update skip locked", SQL)
        self.assertIn("agent_id = trim(p_agent_id)", SQL)
        self.assertIn("heartbeat_at < now() - interval '5 minutes'", SQL)

    def test_submission_contract_keeps_original_batch_fields(self) -> None:
        for field in (
            "raw_text",
            "line_count",
            "execution_status",
            "task_total",
            "task_completed",
            "task_failed",
            "result_message",
        ):
            self.assertIn(field, SQL)

    def test_public_status_rpc_does_not_return_account_text(self) -> None:
        status_function = SQL.split("function public.get_submission", 1)[1].split(
            "function public.cancel_submission", 1
        )[0]
        self.assertNotIn("'raw_text'", status_function)
        self.assertNotIn("password_hash", status_function)
        self.assertNotIn("code_text", status_function)

    def test_registration_atomically_consumes_one_daily_invitation(self) -> None:
        registration = SQL.split("function public.register_remote_user", 1)[1].split(
            "function public.login_remote_user", 1
        )[0]
        self.assertIn("for update", registration)
        self.assertIn("used_at is null", registration)
        self.assertIn("set used_at = now()", registration)
        self.assertIn("timezone('Asia/Shanghai', now())", registration)
        self.assertIn("extensions.crypt", registration)
        self.assertIn("extensions.gen_salt('bf', 12)", registration)

    def test_invitation_issuer_is_service_role_only(self) -> None:
        self.assertIn(
            "revoke all on function public.issue_invitation_codes(integer) from public, anon, authenticated",
            SQL,
        )
        self.assertIn(
            "grant execute on function public.issue_invitation_codes(integer) to service_role",
            SQL,
        )
        self.assertNotIn(
            "grant execute on function public.issue_invitation_codes(integer) to anon",
            SQL,
        )

    def test_submission_rpcs_require_session_and_user_ownership(self) -> None:
        for signature in (
            "submit_submission(text, uuid, text, text)",
            "get_submission(uuid, text, text)",
            "cancel_submission(uuid, text, text)",
            "retry_submission(uuid, text, text)",
            "clear_submission(uuid, text, text)",
        ):
            self.assertIn(signature, SQL)
        self.assertIn("p_session_token text", SQL)
        self.assertIn("submission.user_id = public.current_remote_user_id(p_session_token)", SQL)

    def test_daily_invitation_job_generates_multiple_random_codes(self) -> None:
        self.assertIn("welearn-daily-invitation-codes", CRON_SQL)
        self.assertIn("select public.issue_invitation_codes(10)", CRON_SQL)
        self.assertIn("'0 16 * * *'", CRON_SQL)

    def test_required_rpc_contract_is_present(self) -> None:
        for name in (
            "submit_submission",
            "get_submission",
            "cancel_submission",
            "retry_submission",
            "clear_submission",
            "issue_invitation_codes",
            "register_remote_user",
            "login_remote_user",
            "logout_remote_user",
            "claim_next_submission",
            "agent_heartbeat_submission",
            "agent_report_submission",
        ):
            self.assertIn(f"function public.{name}", SQL)

    def test_admin_migration_requires_admin_session_for_invitation_management(self) -> None:
        self.assertIn("add column if not exists is_admin boolean not null default false", ADMIN_SQL)
        self.assertIn("current_remote_admin_id", ADMIN_SQL)
        self.assertIn("if public.current_remote_admin_id(p_session_token) is null", ADMIN_SQL)
        self.assertIn("grant execute on function public.bootstrap_admin_account(text, text) to service_role", ADMIN_SQL)

    def test_admin_migration_accepts_email_style_usernames(self) -> None:
        self.assertIn("^[a-z0-9][a-z0-9_.@-]{2,63}$", ADMIN_SQL)

    def test_invitation_rotation_replaces_only_unused_codes_for_today(self) -> None:
        self.assertIn("delete from public.invitation_codes", ADMIN_CONSOLE_SQL)
        self.assertIn("where issue_date = current_issue_date", ADMIN_CONSOLE_SQL)
        self.assertIn("and used_at is null", ADMIN_CONSOLE_SQL)
        self.assertIn("perform public.issue_invitation_codes(10)", ADMIN_CONSOLE_SQL)

    def test_admin_invitation_list_includes_usage_account_details(self) -> None:
        self.assertIn("'used_by', invitation.used_by", ADMIN_CONSOLE_SQL)
        self.assertIn("'used_username', user_record.username", ADMIN_CONSOLE_SQL)
        self.assertIn("left join public.remote_users", ADMIN_CONSOLE_SQL)

    def test_admin_can_list_accounts_without_password_data(self) -> None:
        function_sql = ADMIN_CONSOLE_SQL.split("function public.admin_list_remote_users", 1)[1]
        self.assertIn("current_remote_admin_id", function_sql)
        self.assertIn("'username', user_record.username", function_sql)
        self.assertIn("'last_login_at', user_record.last_login_at", function_sql)
        self.assertNotIn("password_hash", function_sql)
        self.assertIn(
            "grant execute on function public.admin_list_remote_users(text) to anon, authenticated",
            function_sql,
        )


if __name__ == "__main__":
    unittest.main()
