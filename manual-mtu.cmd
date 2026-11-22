@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\manual-mtu.ps1" -Mode Menu
exit /b %ERRORLEVEL%
