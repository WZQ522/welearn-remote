from __future__ import annotations

import os
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

AGENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENT_DIR))

from agent import AgentConfig, TaskAgent  # noqa: E402
from submission_locks import submission_account_keys  # noqa: E402


class QueueCloudClient:
    def __init__(self, tasks: list[dict], stop_event: threading.Event) -> None:
        self._tasks = list(tasks)
        self._lock = threading.Lock()
        self.stop_event = stop_event
        self.completed: list[str] = []

    def claim_next(self, agent_id: str, excluded_submission_ids=()):
        with self._lock:
            return self._tasks.pop(0) if self._tasks else None

    def heartbeat(self, task_id: str, agent_id: str) -> bool:
        return True

    def report_result(self, task_id: str, agent_id: str, result) -> bool:
        with self._lock:
            self.completed.append(task_id)
            if len(self.completed) == 2:
                self.stop_event.set()
        return True

    def report_failed(self, task_id: str, agent_id: str, message: str, task_total: int) -> bool:
        self.stop_event.set()
        return True


class ConcurrencyProbeAdapter:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.active = 0
        self.maximum_active = 0

    def process(self, task, should_continue):
        with self._lock:
            self.active += 1
            self.maximum_active = max(self.maximum_active, self.active)
        try:
            time.sleep(0.15)
            return {
                "execution_status": "completed",
                "task_total": 1,
                "task_completed": 1,
                "task_failed": 0,
                "result_message": "done",
            }
        finally:
            with self._lock:
                self.active -= 1


class DuplicateProneCloudClient(QueueCloudClient):
    """Models the database behavior that can return an agent's processing row again."""

    def __init__(self, tasks: list[dict], stop_event: threading.Event) -> None:
        super().__init__(tasks, stop_event)
        self.claim_exclusions: list[tuple[str, ...]] = []

    def claim_next(self, agent_id: str, excluded_submission_ids=()):
        with self._lock:
            excluded = tuple(excluded_submission_ids)
            self.claim_exclusions.append(excluded)
            return next((item for item in self._tasks if item["id"] not in excluded), None)

    def report_result(self, task_id: str, agent_id: str, result) -> bool:
        with self._lock:
            self._tasks = [item for item in self._tasks if item["id"] != task_id]
            self.completed.append(task_id)
            if len(set(self.completed)) == 2:
                self.stop_event.set()
        return True


def task(identifier: str, account: str) -> dict:
    return {
        "id": identifier,
        "raw_text": f"u校园 {account} password course",
        "line_count": 1,
        "attempt_count": 1,
    }


def config(worker_count: int) -> AgentConfig:
    return AgentConfig(
        agent_id="pool-test",
        poll_interval=0.05,
        heartbeat_interval=5,
        processor_timeout=5,
        work_root=Path("/tmp/worker-pool-test"),
        worker_count=worker_count,
    )


class WorkerPoolTests(unittest.TestCase):
    def test_worker_count_defaults_to_two_and_is_bounded_at_four(self) -> None:
        with patch.dict(os.environ, {"AGENT_WORKERS": ""}, clear=False):
            self.assertEqual(AgentConfig.load().worker_count, 2)
        with patch.dict(os.environ, {"AGENT_WORKERS": "99"}, clear=False):
            self.assertEqual(AgentConfig.load().worker_count, 4)

    def test_account_keys_normalize_platform_and_account_without_password(self) -> None:
        keys = submission_account_keys("U校园 Alice Secret course\nwelearn BOB hidden course")
        self.assertEqual(keys, ("u校园:alice", "welearn:bob"))
        self.assertNotIn("secret", " ".join(keys))

    def test_two_workers_run_different_accounts_concurrently(self) -> None:
        stop = threading.Event()
        cloud = QueueCloudClient([task("a", "alice"), task("b", "bob")], stop)
        adapter = ConcurrencyProbeAdapter()
        TaskAgent(cloud, adapter, config(2)).run_forever(stop)
        self.assertCountEqual(cloud.completed, ["a", "b"])
        self.assertEqual(adapter.maximum_active, 2)

    def test_same_account_is_serialized_across_workers(self) -> None:
        stop = threading.Event()
        cloud = QueueCloudClient([task("a", "Alice"), task("b", "alice")], stop)
        adapter = ConcurrencyProbeAdapter()
        TaskAgent(cloud, adapter, config(2)).run_forever(stop)
        self.assertCountEqual(cloud.completed, ["a", "b"])
        self.assertEqual(adapter.maximum_active, 1)

    def test_workers_exclude_in_process_claims_before_requesting_another_task(self) -> None:
        stop = threading.Event()
        cloud = DuplicateProneCloudClient([task("a", "alice"), task("b", "bob")], stop)
        adapter = ConcurrencyProbeAdapter()
        TaskAgent(cloud, adapter, config(2)).run_forever(stop)
        self.assertCountEqual(cloud.completed, ["a", "b"])
        self.assertTrue(any("a" in excluded or "b" in excluded for excluded in cloud.claim_exclusions))


if __name__ == "__main__":
    unittest.main()
