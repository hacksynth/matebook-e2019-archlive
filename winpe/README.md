# MateBook E 2019 ARM64 Recovery PE

This directory contains a private Windows PE build pipeline for the current
HUAWEI MateBook E 2019 / PAK-AL09 device.

The generated ISO:

- boots the ARM64 Windows PE image from UEFI;
- includes the inbox ARM64 UFS, SD, USB storage, ACPI, display, and I2C-HID
  drivers required for the PAK-AL09 storage and input stack;
- injects the local Qualcomm ARM64 I2C, GPIO, SPI, UART, USB, WLAN, power,
  SMMU, and monitor driver packages into `boot.wim`;
- copies the complete driver tree to `X:\Drivers` for offline recovery;
- enables WMI, .NET, PowerShell, DISM, storage management, scripting, HTA,
  Chinese fonts, and x64 emulation where the ADK supports them;
- displays physical disks and volumes automatically at startup.

The full Adreno WDDM graphics package is intentionally not injected. WinPE
uses Microsoft's Basic Display Driver and does not run the full Windows
desktop graphics stack.

Windows PE does not provide a general desktop or general Wi-Fi manager. The
presence of a WLAN driver does not guarantee wireless networking in this
environment.

The ISO contains Microsoft WinPE and locally extracted device drivers. Keep
the repository private and do not redistribute the generated media without
checking the Microsoft and hardware-vendor license terms.

## Build

Run the `Build ARM64 Recovery PE` workflow manually. It uses the matched
Windows ADK and Windows PE add-on version `10.1.26100.9457`.
