from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENT_DIR))

from agent import AgentConfig, TaskAgent, normalized_processor_result  # noqa: E402
from processor_adapter import ProcessorAdapter, ProcessorError  # noqa: E402


class FakeCloudClient:
    def __init__(self) -> None:
        self.task = {
            "id": "integration-task",
            "raw_text": "u校园 account-a password-a 100\nwelearn account-b password-b 90",
            "line_count": 2,
            "attempt_count": 1,
        }
        self.completed = None
        self.failed = None

    def claim_next(self, agent_id: str, excluded_submission_ids=()):
        task, self.task = self.task, None
        return task

    def heartbeat(self, task_id: str, agent_id: str) -> bool:
        return True

    def report_result(self, task_id: str, agent_id: str, result) -> bool:
        self.completed = (task_id, agent_id, result)
        return True

    def report_failed(self, task_id: str, agent_id: str, message: str, task_total: int) -> bool:
        self.failed = (task_id, agent_id, message, task_total)
        return True


class AgentIntegrationTests(unittest.TestCase):
    def test_claim_process_and_upload_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cloud = FakeCloudClient()
            adapter = ProcessorAdapter(
                [sys.executable, str(AGENT_DIR / "mock_processor.py")],
                Path(temporary),
                timeout_seconds=10,
                poll_seconds=0.05,
            )
            config = AgentConfig(
                agent_id="test-agent",
                poll_interval=2,
                heartbeat_interval=5,
                processor_timeout=10,
                work_root=Path(temporary),
            )
            agent = TaskAgent(cloud, adapter, config)
            self.assertTrue(agent.run_once())
            self.assertIsNotNone(cloud.completed)
            self.assertIsNone(cloud.failed)
            self.assertEqual(cloud.completed[0], "integration-task")
            self.assertEqual(cloud.completed[2]["execution_status"], "completed")
            self.assertEqual(cloud.completed[2]["task_total"], 2)
            self.assertEqual(cloud.completed[2]["task_completed"], 2)
            self.assertFalse(agent.run_once())

    def test_invalid_processor_counts_are_rejected_before_upload(self) -> None:
        with self.assertRaises(ProcessorError):
            normalized_processor_result(
                {
                    "execution_status": "completed",
                    "task_total": 1,
                    "task_completed": 1,
                    "task_failed": 1,
                    "result_message": "invalid fixture",
                },
                fallback_total=1,
            )

    def test_completed_processor_result_must_settle_every_task(self) -> None:
        with self.assertRaises(ProcessorError):
            normalized_processor_result(
                {
                    "execution_status": "completed",
                    "task_total": 2,
                    "task_completed": 1,
                    "task_failed": 0,
                    "result_message": "incomplete fixture",
                },
                fallback_total=2,
            )

    def test_failed_processor_result_must_identify_a_failed_task(self) -> None:
        with self.assertRaises(ProcessorError):
            normalized_processor_result(
                {
                    "execution_status": "failed",
                    "task_total": 1,
                    "task_completed": 0,
                    "task_failed": 0,
                    "result_message": "missing failure count",
                },
                fallback_total=1,
            )


if __name__ == "__main__":
    unittest.main()
