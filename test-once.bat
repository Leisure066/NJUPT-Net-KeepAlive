@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

echo.
echo NJUPT keepalive 1.3.0 - single test
echo.
echo Log out from the campus Portal first, then press any key to test once.
pause >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\portal.ps1" -ConfigPath ".\config.ps1" -Once -DebugMode
set "test_exit=%ERRORLEVEL%"

echo.
echo Exit code: %test_exit%
echo Recent log:
echo.
powershell.exe -NoProfile -Command "Get-Content '.\keepalive.log' -Tail 30 -Encoding UTF8"

echo.
pause
exit /b %test_exit%
