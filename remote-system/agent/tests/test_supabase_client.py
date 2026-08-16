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
            task = client.claim_next("agent-1")
        self.assertEqual(task, {"id": "task-1"})
        self.assertTrue(captured["url"].endswith("/rest/v1/rpc/claim_next_submission"))
        self.assertEqual(captured["body"], {"p_agent_id": "agent-1"})
        self.assertEqual(captured["headers"]["Apikey"], "s" * 40)
        self.assertNotIn("s" * 40, json.dumps(captured["body"]))


if __name__ == "__main__":
    unittest.main()
