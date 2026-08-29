@echo off
rem ============================================================
rem  ComfyUI TestKit launcher for laptop (run as administrator)
rem  Double-click this .bat. It will:
rem    - re-launch PowerShell script as admin
rem    - install Docker if missing (winget), then tell you to reboot
rem    - build image (local source, CPU) and run tests
rem    - write log.txt next to this file
rem
rem  IMPORTANT: run from the extracted folder (do NOT move files out).
rem ============================================================
setlocal
cd /d "%~dp0"

set "PWR=powershell.exe"
set "SCRIPT=%~dp0app\run_test.ps1"

rem If we are not elevated, re-launch ourselves as administrator.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='%~dp0app\run_test.ps1'; Start-Process powershell.exe -Verb RunAs -WorkingDirectory '%~dp0' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$p)"
    echo If a UAC prompt appeared and you accepted, a new window will show the test.
    echo When it finishes, check log.txt. Press any key to close this window.
    pause >nul
    exit /b 0
)

rem We are admin already; run the PS script directly.
echo Running ComfyUI TestKit ...
"%PWR%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
echo.
echo Done. See log.txt next to this file. Press any key to close.
pause >nul
exit /b %errorlevel%
