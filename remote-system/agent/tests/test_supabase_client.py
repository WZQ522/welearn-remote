from __future__ import annotations

import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

AGENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENT_DIR))

from supabase_client import SupabaseAgentClient  # noqa: E402


class FakeResponse:
    def __init__(self, value) -> None:
        self.body = io.BytesIO(json.dumps(value).encode("utf-8"))

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self) -> bytes:
        return self.body.read()


class SupabaseAgentClientTests(unittest.TestCase):
    def test_service_role_key_stays_in_headers_and_rpc_body_is_exact(self) -> None:
        captured = {}

        def fake_open(request, timeout):
            captured["url"] = request.full_url
            captured["headers"] = dict(request.header_items())
            captured["body"] = json.loads(request.data)
            return FakeResponse({"id": "task-1"})

        client = SupabaseAgentClient("https://project.supabase.co", "s" * 40)
        with patch("urllib.request.urlopen", side_effect=fake_open):
            task = client.claim_next("agent-1", ("active-1", "active-2"))
        self.assertEqual(task, {"id": "task-1"})
        self.assertTrue(captured["url"].endswith("/rest/v1/rpc/claim_next_submission_excluding"))
        self.assertEqual(
            captured["body"],
            {"p_agent_id": "agent-1", "p_excluded_submission_ids": ["active-1", "active-2"]},
        )
        self.assertEqual(captured["headers"]["Apikey"], "s" * 40)
        self.assertNotIn("s" * 40, json.dumps(captured["body"]))

    def test_issue_invitation_codes_uses_admin_rpc_and_validates_array(self) -> None:
        captured = {}

        def fake_open(request, timeout):
            captured["url"] = request.full_url
            captured["body"] = json.loads(request.data)
            return FakeResponse(["A" * 32, "B" * 32])

        client = SupabaseAgentClient("https://project.supabase.co", "s" * 40)
        with patch("urllib.request.urlopen", side_effect=fake_open):
            codes = client.issue_invitation_codes(2)
        self.assertEqual(codes, ["A" * 32, "B" * 32])
        self.assertTrue(captured["url"].endswith("/rest/v1/rpc/issue_invitation_codes"))
        self.assertEqual(captured["body"], {"p_count": 2})

    def test_agent_status_rpc_reports_capacity_without_submission_secrets(self) -> None:
        captured = {}

        def fake_open(request, timeout):
            captured["url"] = request.full_url
            captured["body"] = json.loads(request.data)
            return FakeResponse(True)

        client = SupabaseAgentClient("https://project.supabase.co", "s" * 40)
        with patch("urllib.request.urlopen", side_effect=fake_open):
            reported = client.report_status("agent-1", 4, 2, True)
        self.assertTrue(reported)
        self.assertTrue(captured["url"].endswith("/rest/v1/rpc/agent_report_status"))
        self.assertEqual(
            captured["body"],
            {"p_agent_id": "agent-1", "p_worker_count": 4, "p_active_tasks": 2, "p_online": True},
        )


if __name__ == "__main__":
    unittest.main()
