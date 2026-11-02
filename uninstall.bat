@echo off
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Please right-click this file and choose "Run as administrator".
    pause
    exit /b 1
)
powershell -NoProfile -Command "Unregister-ScheduledTask -TaskName 'NJUPT-net-KeepAlive' -Confirm:$false -ErrorAction SilentlyContinue; Write-Host 'Task removed.'"
echo.
pause