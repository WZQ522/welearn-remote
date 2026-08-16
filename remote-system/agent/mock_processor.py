from __future__ import annotations

import argparse
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    source = json.loads(Path(args.input).read_text(encoding="utf-8"))
    raw_text = source.get("raw_text")
    if not isinstance(raw_text, str) or not raw_text.strip():
        raise ValueError("raw_text is required")
    lines = [line.strip() for line in raw_text.splitlines() if line.strip()]
    delay = min(5.0, max(0.0, float(os.environ.get("MOCK_PROCESSOR_DELAY_SECONDS", "0"))))
    if delay:
        time.sleep(delay)
    if os.environ.get("MOCK_PROCESSOR_FAIL") == "1":
        raise RuntimeError("Mock processor failure requested")

    result = {
        "execution_status": "completed",
        "task_total": len(lines),
        "task_completed": len(lines),
        "task_failed": 0,
        "result_message": f"模拟执行完成，共处理 {len(lines)} 条账号任务",
        "submission_id": source.get("submission_id"),
        "processed_at": datetime.now(timezone.utc).isoformat(),
    }
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
