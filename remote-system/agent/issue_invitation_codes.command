#!/bin/sh
set -e
cd "$(dirname "$0")"
python3 issue_invitation_codes.py "$@"
printf '\n按回车键关闭窗口...'
read -r _
