@echo off
setlocal
title Restore SSH

REM ============================================================
REM  DOUBLE-CLICK THIS FILE ON THE MACHINE TO RESTORE SSH.
REM
REM  Background: an automated service migration removed the
REM  working sshd process but the new service failed to start.
REM  This script puts SSH back to a working state and keeps it.
REM
REM  It runs from its own folder, so no path typing needed.
REM  ASCII-only on purpose.
REM ============================================================

echo ============================================================
echo   Restore SSH
echo ============================================================
echo.

if exist "%~dp0restore-ssh.ps1" goto :RUN
echo   [ERROR] restore-ssh.ps1 not found next to this file.
echo.
pause
exit /b 1

:RUN
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-ssh.ps1"
set "RC=%errorlevel%"

echo.
echo ============================================================
if "%RC%"=="0" (
    echo   SSH restored - you can connect again
) else (
    echo   Finished with code %RC%
)
echo ============================================================
echo.
pause
exit /b %RC%
