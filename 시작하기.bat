@echo off
chcp 65001 >nul
title AI Office
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
if errorlevel 1 pause
