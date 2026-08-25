from __future__ import annotations

import threading
from contextlib import contextmanager
from typing import Callable, Iterator


class AccountLockCancelled(RuntimeError):
    """Raised when a claimed task is canceled while waiting for its account."""


def submission_account_keys(raw_text: str) -> tuple[str, ...]:
    """Return stable platform/account identities without retaining passwords."""
    identities: set[str] = set()
    for raw_line in raw_text.splitlines():
        fields = raw_line.split()
        if len(fields) < 2:
            continue
        platform = "".join(fields[0].casefold().split())
        account = fields[1].strip().casefold()
        if account:
            identities.add(f"{platform}:{account}")
    return tuple(sorted(identities))


class SubmissionAccountLockPool:
    """Serializes tasks sharing an account while allowing unrelated tasks through."""

    def __init__(self, poll_seconds: float = 0.1) -> None:
        self._guard = threading.Lock()
        self._locks: dict[str, threading.Lock] = {}
        self._poll_seconds = max(0.01, poll_seconds)

    @contextmanager
    def hold(
        self,
        keys: tuple[str, ...],
        should_continue: Callable[[], bool] = lambda: True,
    ) -> Iterator[None]:
        locks = self._locks_for(keys)
        acquired: list[threading.Lock] = []
        try:
            for lock in locks:
                while not lock.acquire(timeout=self._poll_seconds):
                    if not should_continue():
                        raise AccountLockCancelled("Task canceled while waiting for account lock")
                acquired.append(lock)
                if not should_continue():
                    raise AccountLockCancelled("Task canceled while waiting for account lock")
            yield
        finally:
            for lock in reversed(acquired):
                lock.release()

    def _locks_for(self, keys: tuple[str, ...]) -> list[threading.Lock]:
        with self._guard:
            return [self._locks.setdefault(key, threading.Lock()) for key in sorted(set(keys))]
