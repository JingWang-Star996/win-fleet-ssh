@echo off
setlocal
title Machine Console

REM Entry point. All logic lives in console2.py.
REM ASCII-only on purpose: cmd.exe mangles non-ASCII depending on codepage.

set "D=%~dp0"
set "PYW=C:\Users\<user>\AppData\Local\Programs\Python\Python311\pythonw.exe"

if exist "%D%console2.py" goto :HAVE
echo   [ERROR] console2.py not found in %D%
pause
exit /b 1

:HAVE
if exist "%PYW%" goto :RUNW
echo   [WARN] pythonw.exe missing, falling back to python.exe
pushd "%D%"
python console2.py
popd
exit /b

:RUNW
pushd "%D%"
start "" "%PYW%" "%D%console2.py"
popd
exit /b 0
