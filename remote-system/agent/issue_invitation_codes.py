from __future__ import annotations

import argparse
import os
from pathlib import Path

from agent import load_env
from supabase_client import SupabaseAgentClient


ROOT = Path(__file__).resolve().parent


def main() -> int:
    parser = argparse.ArgumentParser(description="Issue invitation codes for the remote console")
    parser.add_argument("--count", type=int, default=10, help="Number of codes to issue (default: 10)")
    args = parser.parse_args()
    if args.count < 1 or args.count > 1000:
        parser.error("--count must be between 1 and 1000")

    load_env(ROOT.parent / ".env")
    load_env(ROOT / ".env")
    client = SupabaseAgentClient(
        os.environ.get("SUPABASE_URL", ""),
        os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""),
    )
    for code in client.issue_invitation_codes(args.count):
        print(code)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
