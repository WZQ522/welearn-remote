from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

AGENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENT_DIR))

from processor_adapter import ProcessorAdapter, ProcessorCanceled, ProcessorError  # noqa: E402


class ProcessorAdapterTests(unittest.TestCase):
    def test_mock_processor_receives_input_and_writes_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            adapter = ProcessorAdapter(
                [sys.executable, str(AGENT_DIR / "mock_processor.py")],
                Path(temporary),
                timeout_seconds=10,
                poll_seconds=0.05,
            )
            result = adapter.process(
                {
                    "id": "task-1",
                    "raw_text": "u校园 account-a password-a 100\nwelearn account-b password-b 90",
                    "line_count": 2,
                    "attempt_count": 1,
                }
            )
            self.assertEqual(result["execution_status"], "completed")
            self.assertEqual(result["task_total"], 2)
            input_path = Path(temporary) / "task-1" / "attempt-1" / "input.json"
            self.assertTrue(input_path.is_file())
            input_document = json.loads(input_path.read_text(encoding="utf-8"))
            self.assertEqual(input_document["submission_id"], "task-1")
            self.assertEqual(input_document["line_count"], 2)
            self.assertIn("u校园", input_document["raw_text"])

    def test_processor_is_terminated_when_cloud_requests_cancel(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            adapter = ProcessorAdapter(
                [sys.executable, str(AGENT_DIR / "mock_processor.py")],
                Path(temporary),
                timeout_seconds=10,
                poll_seconds=0.05,
            )
            calls = 0

            def should_continue() -> bool:
                nonlocal calls
                calls += 1
                return calls < 2

            with patch.dict(os.environ, {"MOCK_PROCESSOR_DELAY_SECONDS": "2"}):
                with self.assertRaises(ProcessorCanceled):
                    adapter.process(
                        {
                            "id": "task-cancel",
                            "raw_text": "u校园 account password 100",
                            "line_count": 1,
                            "attempt_count": 1,
                        },
                        should_continue=should_continue,
                    )

    def test_line_count_mismatch_is_rejected_before_starting_processor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            adapter = ProcessorAdapter(
                [sys.executable, str(AGENT_DIR / "mock_processor.py")],
                Path(temporary),
                timeout_seconds=10,
                poll_seconds=0.05,
            )
            with self.assertRaises(ProcessorError):
                adapter.process(
                    {
                        "id": "task-mismatch",
                        "raw_text": "u校园 account password 100\nwelearn account password 100",
                        "line_count": 1,
                        "attempt_count": 1,
                    }
                )


if __name__ == "__main__":
    unittest.main()
