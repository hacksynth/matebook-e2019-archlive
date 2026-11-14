@echo off
setlocal
set "PE_TOOLS=X:\Program Files\RecoveryPE"
set "PATH=%PE_TOOLS%\7-Zip;%PE_TOOLS%\Explorer++;%PATH%"

echo Initializing Windows PE...
wpeinit
echo.

echo ============================================================
echo   MateBook E 2019 ARM64 Recovery PE
echo ============================================================
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 goto command_prompt

if exist X:\Windows\System32\pnputil.exe (
    echo Rescanning plug-and-play devices...
    pnputil.exe /scan-devices
)

>X:\rescan-storage.txt echo rescan
>X:\rescan-storage.txt echo list disk
>X:\rescan-storage.txt echo exit
if exist X:\Windows\System32\diskpart.exe (
    echo Rescanning storage...
    diskpart.exe /s X:\rescan-storage.txt
)

if exist "%PE_TOOLS%\diagnose.ps1" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PE_TOOLS%\diagnose.ps1"
)

echo Physical disks and volumes:
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-Disk | Format-Table -AutoSize; Get-Volume | Sort-Object DriveLetter | Format-Table -AutoSize"
echo.

if exist "%PE_TOOLS%\7-Zip\7zFM.exe" (
    echo Starting 7-Zip graphical file manager...
    start "" /wait "%PE_TOOLS%\7-Zip\7zFM.exe"
    >C:\RecoveryPE\7zip-file-manager-launch.txt echo 7zFM exit code: %ERRORLEVEL%
)

:command_prompt
echo The included ARM64 drivers are also available at X:\Drivers.
echo The diagnostic report is saved to C:\RecoveryPE\pe-diagnostics.txt.
echo Use the graphical file manager or type diskpart, notepad, or powershell.
echo.
cmd.exe
