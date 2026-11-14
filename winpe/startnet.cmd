@echo off
setlocal

echo Initializing Windows PE...
wpeinit
echo.

echo ============================================================
echo   MateBook E 2019 ARM64 Recovery PE
echo ============================================================
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 goto command_prompt

echo Physical disks and volumes:
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-Disk | Format-Table -AutoSize; Get-Volume | Sort-Object DriveLetter | Format-Table -AutoSize"
echo.

:command_prompt
echo The included ARM64 drivers are also available at X:\Drivers.
echo Type diskpart, notepad, or powershell to begin recovery.
echo.
cmd.exe
