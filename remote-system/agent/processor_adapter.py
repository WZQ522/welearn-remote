from __future__ import annotations

import json
import os
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any, Callable, Sequence


class ProcessorError(RuntimeError):
    pass


class ProcessorCanceled(ProcessorError):
    pass


def command_from_environment() -> list[str]:
    encoded = os.environ.get("PROCESSOR_COMMAND_JSON", "").strip()
    if encoded:
        try:
            value = json.loads(encoded)
        except json.JSONDecodeError as error:
            raise ProcessorError("PROCESSOR_COMMAND_JSON must be a JSON string array") from error
        if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
            raise ProcessorError("PROCESSOR_COMMAND_JSON must be a non-empty JSON string array")
        return value

    command = os.environ.get("PROCESSOR_COMMAND", "my-program.exe").strip()
    if not command:
        raise ProcessorError("PROCESSOR_COMMAND is empty")
    return shlex.split(command, posix=os.name != "nt")


class ProcessorAdapter:
    def __init__(
        self,
        command: Sequence[str],
        work_root: Path,
        timeout_seconds: float = 3600,
        poll_seconds: float = 0.5,
    ) -> None:
        if not command:
            raise ValueError("Processor command is empty")
        self.command = [str(item) for item in command]
        self.work_root = work_root
        self.timeout_seconds = max(1.0, timeout_seconds)
        self.poll_seconds = max(0.05, poll_seconds)

    def process(
        self,
        task: dict[str, Any],
        should_continue: Callable[[], bool] | None = None,
    ) -> Any:
        task_id = safe_task_id(str(task.get("id", "task")))
        attempt = max(1, int(task.get("attempt_count") or 1))
        work_dir = self.work_root / task_id / f"attempt-{attempt}"
        work_dir.mkdir(parents=True, exist_ok=True)
        input_path = work_dir / "input.json"
        output_path = work_dir / "result.json"
        stdout_path = work_dir / "stdout.log"
        stderr_path = work_dir / "stderr.log"

        raw_text = task.get("raw_text")
        if not isinstance(raw_text, str) or not raw_text.strip():
            raise ProcessorError("Submission raw_text is missing")
        line_count = int(task.get("line_count") or count_nonempty_lines(raw_text))
        input_document = {
            "submission_id": task.get("id"),
            "raw_text": raw_text,
            "line_count": line_count,
            "attempt_count": attempt,
        }
        input_path.write_text(json.dumps(input_document, ensure_ascii=False, indent=2), encoding="utf-8")
        if output_path.exists():
            output_path.unlink()

        command = [*self.command, "--input", str(input_path), "--output", str(output_path)]
        started = time.monotonic()
        with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
            try:
                process = subprocess.Popen(
                    command,
                    cwd=Path(__file__).resolve().parent,
                    stdout=stdout_file,
                    stderr=stderr_file,
                )
            except OSError as error:
                raise ProcessorError(f"Unable to start processor: {error}") from error

            while process.poll() is None:
                if should_continue is not None and not should_continue():
                    process.terminate()
                    wait_or_kill(process)
                    raise ProcessorCanceled("Task cancellation requested")
                if time.monotonic() - started > self.timeout_seconds:
                    process.terminate()
                    wait_or_kill(process)
                    raise ProcessorError(f"Processor timed out after {self.timeout_seconds:g} seconds")
                time.sleep(self.poll_seconds)

        if process.returncode != 0:
            detail = tail_text(stderr_path) or tail_text(stdout_path)
            suffix = f": {detail}" if detail else ""
            raise ProcessorError(f"Processor exited with code {process.returncode}{suffix}")
        if not output_path.is_file():
            raise ProcessorError("Processor completed without result.json")
        try:
            return json.loads(output_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ProcessorError("Processor result.json is not valid UTF-8 JSON") from error


def safe_task_id(value: str) -> str:
    safe = "".join(character for character in value if character.isalnum() or character in "-_")
    return safe[:80] or "task"


def count_nonempty_lines(value: str) -> int:
    return sum(1 for line in value.splitlines() if line.strip())


def wait_or_kill(process: subprocess.Popen[bytes]) -> None:
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def tail_text(path: Path, limit: int = 2000) -> str:
    try:
        data = path.read_bytes()
    except OSError:
        return ""
    return data[-limit:].decode("utf-8", errors="replace").strip()
