@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File backtest.ps1
pause
