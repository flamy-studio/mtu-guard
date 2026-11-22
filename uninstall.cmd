@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo [PASS] Finished) else (echo [FAIL] Uninstall returned %RC%)
echo Press any key to close.
pause >nul
exit /b %RC%
