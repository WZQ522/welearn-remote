from __future__ import annotations

import argparse
import json
import math
import threading
import time
from pathlib import Path

from agent import AgentConfig, TaskAgent
from submission_locks import submission_account_keys


class QueueLoadClient:
    def __init__(self, tasks: list[dict], stop_event: threading.Event) -> None:
        self._pending = list(tasks)
        self._claimed_at: dict[str, float] = {}
        self._lock = threading.Lock()
        self._total = len(tasks)
        self.stop_event = stop_event
        self.completed_ids: list[str] = []
        self.durations: list[float] = []

    def claim_next(self, agent_id: str, excluded_submission_ids=()):
        excluded = set(excluded_submission_ids)
        with self._lock:
            for index, task in enumerate(self._pending):
                if task["id"] in excluded:
                    continue
                claimed = self._pending.pop(index)
                self._claimed_at[claimed["id"]] = time.perf_counter()
                return claimed
        return None

    def heartbeat(self, task_id: str, agent_id: str) -> bool:
        return True

    def report_result(self, task_id: str, agent_id: str, result) -> bool:
        with self._lock:
            started = self._claimed_at.pop(task_id)
            self.durations.append(time.perf_counter() - started)
            self.completed_ids.append(task_id)
            if len(self.completed_ids) >= self._total:
                self.stop_event.set()
        return True

    def report_failed(self, task_id: str, agent_id: str, message: str, task_total: int) -> bool:
        return self.report_result(task_id, agent_id, {"execution_status": "failed"})


class LoadProbeAdapter:
    def __init__(self, delay_seconds: float) -> None:
        self.delay_seconds = delay_seconds
        self._lock = threading.Lock()
        self.active = 0
        self.maximum_active = 0
        self.active_accounts: dict[str, int] = {}
        self.maximum_active_per_account = 0

    def process(self, task, should_continue):
        keys = submission_account_keys(task.get("raw_text", ""))
        account_key = keys[0] if keys else "unknown"
        with self._lock:
            self.active += 1
            self.maximum_active = max(self.maximum_active, self.active)
            self.active_accounts[account_key] = self.active_accounts.get(account_key, 0) + 1
            self.maximum_active_per_account = max(
                self.maximum_active_per_account,
                self.active_accounts[account_key],
            )
        try:
            deadline = time.monotonic() + self.delay_seconds
            while time.monotonic() < deadline:
                if not should_continue():
                    raise RuntimeError("load task canceled")
                time.sleep(min(0.01, max(0.0, deadline - time.monotonic())))
            return {
                "execution_status": "completed",
                "task_total": 1,
                "task_completed": 1,
                "task_failed": 0,
                "result_message": "load probe completed",
            }
        finally:
            with self._lock:
                self.active -= 1
                self.active_accounts[account_key] -= 1


def percentile(values: list[float], percentile_value: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * percentile_value) - 1))
    return ordered[index]


def run_load_test(tasks: int, workers: int, account_pool: int, delay_seconds: float) -> dict:
    if tasks < 1 or tasks > 10_000:
        raise ValueError("tasks must be between 1 and 10000")
    if workers < 1 or workers > 4:
        raise ValueError("workers must be between 1 and 4")
    if account_pool < 1 or account_pool > tasks:
        raise ValueError("account_pool must be between 1 and tasks")
    if delay_seconds <= 0 or delay_seconds > 60:
        raise ValueError("delay_seconds must be between 0 and 60")

    submissions = [
        {
            "id": f"load-{index + 1}",
            "raw_text": f"u校园 account-{index % account_pool + 1} placeholder course",
            "line_count": 1,
            "attempt_count": 1,
        }
        for index in range(tasks)
    ]
    stop = threading.Event()
    cloud = QueueLoadClient(submissions, stop)
    adapter = LoadProbeAdapter(delay_seconds)
    config = AgentConfig(
        agent_id="offline-load-test",
        poll_interval=0.02,
        heartbeat_interval=5,
        processor_timeout=max(5.0, delay_seconds * 4),
        work_root=Path("/tmp/unified-agent-load-test"),
        worker_count=workers,
    )
    started = time.perf_counter()
    TaskAgent(cloud, adapter, config).run_forever(stop)
    elapsed = time.perf_counter() - started
    duplicate_count = len(cloud.completed_ids) - len(set(cloud.completed_ids))
    return {
        "tasks": tasks,
        "workers": workers,
        "account_pool": account_pool,
        "completed": len(cloud.completed_ids),
        "duplicates": duplicate_count,
        "max_concurrency": adapter.maximum_active,
        "max_concurrency_per_account": adapter.maximum_active_per_account,
        "elapsed_seconds": round(elapsed, 3),
        "throughput_per_second": round(tasks / elapsed, 3),
        "p50_task_seconds": round(percentile(cloud.durations, 0.50), 3),
        "p95_task_seconds": round(percentile(cloud.durations, 0.95), 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline Agent concurrency/load probe")
    parser.add_argument("--tasks", type=int, default=20)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--account-pool", type=int, default=20)
    parser.add_argument("--delay", type=float, default=0.1, dest="delay_seconds")
    args = parser.parse_args()
    result = run_load_test(args.tasks, args.workers, args.account_pool, args.delay_seconds)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["completed"] == args.tasks and result["duplicates"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
