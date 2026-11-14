@echo off
setlocal
set "PE_TOOLS=X:\Program Files\RecoveryPE"

echo Initializing Windows PE...
wpeinit
echo.

echo ============================================================
echo   MateBook E 2019 ARM64 Recovery PE
echo ============================================================
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 goto command_prompt

if exist "%PE_TOOLS%\diagnose.ps1" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PE_TOOLS%\diagnose.ps1"
)

echo Physical disks and volumes:
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-Disk | Format-Table -AutoSize; Get-Volume | Sort-Object DriveLetter | Format-Table -AutoSize"
echo.

if exist "%PE_TOOLS%\Explorer++\Explorer++.exe" (
    echo Starting Explorer++ graphical file manager...
    start "" "%PE_TOOLS%\Explorer++\Explorer++.exe"
)

:command_prompt
echo The included ARM64 drivers are also available at X:\Drivers.
echo The diagnostic report is saved to C:\RecoveryPE\pe-diagnostics.txt.
echo Use Explorer++ or type diskpart, notepad, or powershell.
echo.
cmd.exe
