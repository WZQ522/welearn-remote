@echo off
setlocal
cd /d "%~dp0"
py -3 issue_invitation_codes.py %*
pause
