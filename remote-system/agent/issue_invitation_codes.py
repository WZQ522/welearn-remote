from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from agent import load_env
from supabase_client import SupabaseAgentClient, SupabaseError


ROOT = Path(__file__).resolve().parent


def prompt_with_osascript(message: str, hidden: bool = False) -> str:
    answer_mode = " with hidden answer" if hidden else ""
    script = (
        f'display dialog "{message}" default answer ""{answer_mode} '
        'buttons {"取消", "继续"} default button "继续"'
        "\ntext returned of result"
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("已取消配置或无法打开 Mac 配置窗口") from error
    return result.stdout.strip()


def save_local_credentials(url: str, service_role_key: str) -> None:
    env_file = ROOT / ".env"
    existing = env_file.read_text(encoding="utf-8").splitlines() if env_file.is_file() else []
    values = {
        "SUPABASE_URL": url,
        "SUPABASE_SERVICE_ROLE_KEY": service_role_key,
    }
    replaced = set()
    lines = []
    for line in existing:
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in values:
            lines.append(f"{key}={values[key]}")
            replaced.add(key)
        else:
            lines.append(line)
    for key, value in values.items():
        if key not in replaced:
            lines.append(f"{key}={value}")
    env_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    env_file.chmod(0o600)


def ensure_credentials() -> None:
    url = os.environ.get("SUPABASE_URL", "").strip()
    service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    if url.startswith("https://") and len(service_role_key) >= 20:
        return
    if sys.platform != "darwin":
        raise ValueError("请先在 agent/.env 配置 SUPABASE_URL 和 SUPABASE_SERVICE_ROLE_KEY")

    url = prompt_with_osascript("首次使用，请输入 Supabase Project URL\n例如：https://xxxx.supabase.co")
    if not url.startswith("https://"):
        raise ValueError("Supabase Project URL 必须以 https:// 开头")
    service_role_key = prompt_with_osascript(
        "请输入 Supabase service_role key\n只会保存在这台 Mac 的本地配置中",
        hidden=True,
    )
    if len(service_role_key) < 20:
        raise ValueError("service_role key 格式不正确")
    save_local_credentials(url, service_role_key)
    os.environ["SUPABASE_URL"] = url
    os.environ["SUPABASE_SERVICE_ROLE_KEY"] = service_role_key


def main() -> int:
    parser = argparse.ArgumentParser(description="Issue invitation codes for the remote console")
    parser.add_argument("--count", type=int, default=10, help="Number of codes to issue (default: 10)")
    args = parser.parse_args()
    if args.count < 1 or args.count > 1000:
        parser.error("--count must be between 1 and 1000")

    load_env(ROOT.parent / ".env")
    load_env(ROOT / ".env")
    try:
        ensure_credentials()
        client = SupabaseAgentClient(
            os.environ.get("SUPABASE_URL", ""),
            os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""),
        )
        for code in client.issue_invitation_codes(args.count):
            print(code)
        return 0
    except (ValueError, SupabaseError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
