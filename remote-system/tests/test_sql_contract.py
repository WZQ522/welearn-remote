from __future__ import annotations

import unittest
from pathlib import Path


SQL = (Path(__file__).resolve().parents[1] / "supabase/migrations/0001_remote_tasks.sql").read_text(encoding="utf-8")


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

    def test_required_rpc_contract_is_present(self) -> None:
        for name in (
            "submit_submission",
            "get_submission",
            "cancel_submission",
            "retry_submission",
            "clear_submission",
            "claim_next_submission",
            "agent_heartbeat_submission",
            "agent_report_submission",
        ):
            self.assertIn(f"function public.{name}", SQL)


if __name__ == "__main__":
    unittest.main()
