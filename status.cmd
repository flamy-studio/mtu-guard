@echo off
setlocal
set "BIN=%~dp0withen-mtu-guard.exe"
if not exist "%BIN%" set "BIN=%ProgramFiles%\WITHEN\MTU Guard\withen-mtu-guard.exe"
if not exist "%BIN%" (
  echo [FAIL] Executable not found. Install from release ZIP.
  pause >nul
  exit /b 1
)
echo === SERVICE ===
sc.exe query WithenMtuGuard
if errorlevel 1 echo [INFO] MTU Guard service is absent or unavailable. Adapter diagnostics follow.
echo.
echo === VPN ADAPTER ===
"%BIN%" status
set "RC=%ERRORLEVEL%"
echo.
echo Press any key to close.
pause >nul
exit /b %RC%
