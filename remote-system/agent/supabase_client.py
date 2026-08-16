from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any


class SupabaseError(RuntimeError):
    pass


class SupabaseAgentClient:
    def __init__(self, url: str, service_role_key: str, timeout: float = 30.0) -> None:
        origin = url.rstrip("/")
        if not origin.startswith("https://"):
            raise ValueError("SUPABASE_URL must use HTTPS")
        if not service_role_key or len(service_role_key) < 20:
            raise ValueError("SUPABASE_SERVICE_ROLE_KEY is missing")
        self._origin = origin
        self._key = service_role_key
        self._timeout = timeout

    def claim_next(self, agent_id: str) -> dict[str, Any] | None:
        result = self._rpc("claim_next_submission", {"p_agent_id": agent_id})
        return result if isinstance(result, dict) else None

    def issue_invitation_codes(self, count: int = 10) -> list[str]:
        result = self._rpc("issue_invitation_codes", {"p_count": count})
        if not isinstance(result, list) or not all(isinstance(code, str) for code in result):
            raise SupabaseError("Invitation code RPC returned an invalid response")
        return result

    def heartbeat(self, submission_id: str, agent_id: str) -> bool:
        return bool(
            self._rpc(
                "agent_heartbeat_submission",
                {
                    "p_submission_id": submission_id,
                    "p_agent_id": agent_id,
                },
            )
        )

    def report_result(self, submission_id: str, agent_id: str, result: dict[str, Any]) -> bool:
        return bool(
            self._rpc(
                "agent_report_submission",
                {
                    "p_submission_id": submission_id,
                    "p_agent_id": agent_id,
                    "p_execution_status": result["execution_status"],
                    "p_task_total": result["task_total"],
                    "p_task_completed": result["task_completed"],
                    "p_task_failed": result["task_failed"],
                    "p_result_message": result["result_message"],
                    "p_result": result,
                    "p_error_message": None,
                },
            )
        )

    def report_failed(self, submission_id: str, agent_id: str, message: str, task_total: int) -> bool:
        return bool(
            self._rpc(
                "agent_report_submission",
                {
                    "p_submission_id": submission_id,
                    "p_agent_id": agent_id,
                    "p_execution_status": "failed",
                    "p_task_total": task_total,
                    "p_task_completed": 0,
                    "p_task_failed": task_total,
                    "p_result_message": message[:2000],
                    "p_result": None,
                    "p_error_message": message[:2000],
                },
            )
        )

    def _rpc(self, name: str, body: dict[str, Any]) -> Any:
        request = urllib.request.Request(
            f"{self._origin}/rest/v1/rpc/{name}",
            data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers={
                "apikey": self._key,
                "authorization": f"Bearer {self._key}",
                "content-type": "application/json",
                "user-agent": "unified-task-agent/1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                payload = response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")[:500]
            raise SupabaseError(f"Supabase RPC {name} failed: HTTP {error.code}: {detail}") from error
        except urllib.error.URLError as error:
            raise SupabaseError(f"Supabase RPC {name} connection failed: {error.reason}") from error
        if not payload:
            return None
        try:
            return json.loads(payload)
        except json.JSONDecodeError as error:
            raise SupabaseError(f"Supabase RPC {name} returned invalid JSON") from error
