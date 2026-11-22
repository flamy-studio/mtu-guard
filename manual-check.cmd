@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\manual-mtu.ps1" -Mode Check
exit /b %ERRORLEVEL%
