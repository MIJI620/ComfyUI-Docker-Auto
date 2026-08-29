@echo off
rem ============================================================================
rem  ComfyUI-experience -- Docker Quick Start (Windows)
rem  Run as Administrator. Opens the visual guide window.
rem ============================================================================
setlocal
cd /d "%~dp0"
echo Starting ComfyUI-experience ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\experience.ps1"
endlocal
