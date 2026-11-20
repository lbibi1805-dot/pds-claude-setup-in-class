@echo off
rem Double-click launcher: runs setup-claude.ps1 with the execution policy bypassed
rem for this window only. Extra arguments are passed through, e.g.
rem   setup-claude.cmd -StudentId 4029308 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-claude.ps1" %*
echo.
pause
