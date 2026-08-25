from __future__ import annotations

import sys
import unittest
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENT_DIR))

from load_test import run_load_test  # noqa: E402


class AgentLoadTestTests(unittest.TestCase):
    def test_four_workers_complete_twenty_distinct_accounts_without_duplicates(self) -> None:
        result = run_load_test(tasks=20, workers=4, account_pool=20, delay_seconds=0.02)
        self.assertEqual(result["completed"], 20)
        self.assertEqual(result["duplicates"], 0)
        self.assertEqual(result["max_concurrency"], 4)
        self.assertLess(result["elapsed_seconds"], 0.6)

    def test_reused_accounts_never_overlap(self) -> None:
        result = run_load_test(tasks=8, workers=4, account_pool=2, delay_seconds=0.02)
        self.assertEqual(result["completed"], 8)
        self.assertEqual(result["duplicates"], 0)
        self.assertEqual(result["max_concurrency_per_account"], 1)
        self.assertLessEqual(result["max_concurrency"], 2)


if __name__ == "__main__":
    unittest.main()
