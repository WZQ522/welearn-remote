#!/bin/sh
set -e
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/issue_invitation_codes.py" ]; then
  AGENT_DIR="$SCRIPT_DIR"
elif [ -f "/Users/wangziqian/Documents/ChatGPT/welearn/remote-system/agent/issue_invitation_codes.py" ]; then
  AGENT_DIR="/Users/wangziqian/Documents/ChatGPT/welearn/remote-system/agent"
else
  echo "找不到邀请码生成脚本"
  exit 1
fi
cd "$AGENT_DIR"
python3 issue_invitation_codes.py "$@"
printf '\n按回车键关闭窗口...'
read -r _
