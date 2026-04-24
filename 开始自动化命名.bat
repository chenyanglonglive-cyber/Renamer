@echo off
set "CURRENT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%CURRENT_DIR%rename_logic.ps1"
pause
