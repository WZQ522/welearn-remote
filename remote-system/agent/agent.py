from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from processor_adapter import ProcessorAdapter, ProcessorError, command_from_environment
from supabase_client import SupabaseAgentClient, SupabaseError


ROOT = Path(__file__).resolve().parent
FINAL_EXECUTION_STATUSES = {"needs_action", "completed", "partial", "failed"}


def load_env(path: Path) -> None:
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def numeric_env(name: str, default: float, minimum: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return max(minimum, float(raw))
    except ValueError as error:
        raise ValueError(f"{name} must be numeric") from error


@dataclass(frozen=True)
class AgentConfig:
    agent_id: str
    poll_interval: float
    heartbeat_interval: float
    processor_timeout: float
    work_root: Path

    @classmethod
    def load(cls) -> "AgentConfig":
        agent_id = os.environ.get("AGENT_ID", "").strip() or socket.gethostname()
        if len(agent_id) > 128:
            raise ValueError("AGENT_ID must be 128 characters or fewer")
        return cls(
            agent_id=agent_id,
            poll_interval=numeric_env("POLL_INTERVAL_SECONDS", 10.0, 2.0),
            heartbeat_interval=numeric_env("HEARTBEAT_INTERVAL_SECONDS", 30.0, 5.0),
            processor_timeout=numeric_env("PROCESSOR_TIMEOUT_SECONDS", 3600.0, 1.0),
            work_root=Path(os.environ.get("AGENT_WORK_DIR", ROOT / "work")).resolve(),
        )


class HeartbeatMonitor:
    def __init__(
        self,
        client: SupabaseAgentClient,
        task_id: str,
        agent_id: str,
        interval: float,
    ) -> None:
        self.client = client
        self.task_id = task_id
        self.agent_id = agent_id
        self.interval = interval
        self.stop_event = threading.Event()
        self.cancel_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name=f"heartbeat-{task_id}", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=self.interval + 1)

    def should_continue(self) -> bool:
        return not self.cancel_event.is_set()

    def _run(self) -> None:
        while not self.stop_event.wait(self.interval):
            try:
                if not self.client.heartbeat(self.task_id, self.agent_id):
                    self.cancel_event.set()
                    return
            except SupabaseError as error:
                print(f"heartbeat warning: {error}", file=sys.stderr, flush=True)


def normalized_processor_result(value: Any, fallback_total: int) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProcessorError("Processor result must be a JSON object")

    status = value.get("execution_status")
    if status not in FINAL_EXECUTION_STATUSES:
        raise ProcessorError("Processor result has an invalid execution_status")

    counts: dict[str, int] = {}
    for name, default in (
        ("task_total", fallback_total),
        ("task_completed", 0),
        ("task_failed", 0),
    ):
        raw = value.get(name, default)
        if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0:
            raise ProcessorError(f"Processor result has an invalid {name}")
        counts[name] = raw

    if counts["task_completed"] + counts["task_failed"] > counts["task_total"]:
        raise ProcessorError("Processor result task counts exceed task_total")
    if counts["task_total"] < 1:
        raise ProcessorError("Processor result task_total must be positive")
    if status == "completed" and counts["task_completed"] + counts["task_failed"] != counts["task_total"]:
        raise ProcessorError("Completed processor result must settle every task")
    if status == "failed" and counts["task_failed"] < 1:
        raise ProcessorError("Failed processor result must include a failed task")

    message = value.get("result_message", "")
    if not isinstance(message, str):
        raise ProcessorError("Processor result has an invalid result_message")

    return {
        **value,
        "execution_status": status,
        **counts,
        "result_message": message[:2000],
    }


class TaskAgent:
    def __init__(
        self,
        client: SupabaseAgentClient,
        adapter: ProcessorAdapter,
        config: AgentConfig,
    ) -> None:
        self.client = client
        self.adapter = adapter
        self.config = config

    def run_once(self) -> bool:
        task = self.client.claim_next(self.config.agent_id)
        if not task:
            return False

        task_id = str(task["id"])
        print(f"claimed task {task_id}", flush=True)
        monitor = HeartbeatMonitor(
            self.client,
            task_id,
            self.config.agent_id,
            self.config.heartbeat_interval,
        )
        monitor.start()
        try:
            raw_result = self.adapter.process(task, should_continue=monitor.should_continue)
            result = normalized_processor_result(raw_result, int(task.get("line_count") or 0))
            if not self.client.report_result(task_id, self.config.agent_id, result):
                raise SupabaseError("Cloud rejected completion report")
            print(f"reported submission {task_id}: {result['execution_status']}", flush=True)
        except (ProcessorError, SupabaseError, OSError, ValueError) as error:
            message = str(error) or error.__class__.__name__
            print(f"failed task {task_id}: {message}", file=sys.stderr, flush=True)
            try:
                reported = self.client.report_failed(
                    task_id,
                    self.config.agent_id,
                    message,
                    max(1, int(task.get("line_count") or 0)),
                )
                if not reported:
                    print(f"cloud rejected failure report for {task_id}", file=sys.stderr, flush=True)
            except SupabaseError as report_error:
                print(f"failed to upload error for {task_id}: {report_error}", file=sys.stderr, flush=True)
        finally:
            monitor.stop()
        return True

    def run_forever(self) -> None:
        print(f"agent {self.config.agent_id} started", flush=True)
        delay = self.config.poll_interval
        while True:
            try:
                processed = self.run_once()
                delay = 0.2 if processed else self.config.poll_interval
            except SupabaseError as error:
                print(f"cloud warning: {error}", file=sys.stderr, flush=True)
                delay = min(max(delay * 2, self.config.poll_interval), 120.0)
            time.sleep(delay)


def create_agent() -> TaskAgent:
    load_env(ROOT.parent / ".env")
    load_env(ROOT / ".env")
    config = AgentConfig.load()
    client = SupabaseAgentClient(
        os.environ.get("SUPABASE_URL", ""),
        os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""),
    )
    adapter = ProcessorAdapter(
        command_from_environment(),
        config.work_root,
        timeout_seconds=config.processor_timeout,
    )
    return TaskAgent(client, adapter, config)


def main() -> int:
    parser = argparse.ArgumentParser(description="Supabase remote task agent")
    parser.add_argument("--once", action="store_true", help="Claim at most one task and exit")
    parser.add_argument("--check", action="store_true", help="Validate local configuration and exit")
    args = parser.parse_args()
    try:
        agent = create_agent()
        if args.check:
            print(json.dumps({"ok": True, "agent_id": agent.config.agent_id}, ensure_ascii=False))
            return 0
        if args.once:
            agent.run_once()
            return 0
        agent.run_forever()
    except (ValueError, ProcessorError) as error:
        print(f"configuration error: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
