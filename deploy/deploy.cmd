@echo off
REM ============================================================
REM  Double-click wrapper. All real logic lives in deploy.ps1.
REM
REM  Why this file is so short:
REM    cmd.exe has a list of traps that cost hours to debug:
REM      - %~dp0 always ends with a backslash, which escapes the
REM        closing quote when placed inside quoted arguments
REM        (that is what made robocopy return 16 and copy 0 files)
REM      - non-ASCII text in .bat turns into ????? depending on
REM        the active code page
REM      - if/else-if must be written as goto chains
REM    So: this file does ONE thing - hand over to PowerShell with
REM    an absolute path, and let PowerShell do everything else.
REM
REM  Heartbeat is ON by default.
REM    The target address lives in heartbeat-target.txt (one line).
REM    Edit that file to change it - no code changes needed.
REM    To skip heartbeat for one run, pass -SkipHeartbeat: this
REM    wrapper detects it and stops injecting the address.
REM
REM  ASCII-only on purpose.
REM ============================================================

setlocal

set "D=%~dp0"
set "PS1=%D%deploy.ps1"
set "HBFILE=%D%heartbeat-target.txt"

if exist "%PS1%" goto :HAVE_PS1
echo.
echo   [ERROR] deploy.ps1 not found next to this file.
echo.
pause
exit /b 1

:HAVE_PS1
REM If the caller explicitly asked to skip heartbeat, do not inject
REM an address: -HeartbeatServer plus -SkipHeartbeat together makes
REM PowerShell choose one by parameter-set rules, which is confusing.
echo %* | findstr /I /C:"-SkipHeartbeat" >nul
if not errorlevel 1 goto :NO_HB

set "HBURL="
if not exist "%HBFILE%" goto :RUN
rem set /p reads the first line and stops at CRLF - no text parsing.
set /p HBURL=<"%HBFILE%"

:RUN
if "%HBURL%"=="" goto :NO_HB
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -HeartbeatServer "%HBURL%" %*
exit /b %errorlevel%

:NO_HB
if not exist "%HBFILE%" echo   [WARN] heartbeat-target.txt missing - installing without heartbeat.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %errorlevel%
