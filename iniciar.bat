@echo off
title Bot BTC
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File bot.ps1
pause
