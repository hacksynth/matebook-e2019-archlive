# Huawei MateBook E 2019 BIOS 1.16 Static Analysis

Static analysis only. The Windows updater was never executed and no firmware was
flashed or mounted.

## Inputs

| File | Size | SHA-256 |
|---|---:|---|
| `MateBook_E_2019_BIOS_1.16.zip` | 13,587,876 | `8f411026864c9760a0172259ef4a7fd01e9647a8b65ed56ab310858ee707c49d` |
| inner `MateBook_E_2019_BIOS_1.16.zip` | 13,617,326 | `f6afffe99a01a3da7ce42e57567609b491e05ece40cd8ebbc56f7f7e0b85953c` |
| `Planck_BIOS_1.16.exe` | 32,594,448 | `30d80a0d8dbf18a63a807cacd8d0dc303141962bb0c7a31842ac0407e97fbb90` |
| `qcfirmwarePK850116.cap` | 23,221,587 | `e3cc5861a81a4ba0601bbae4599e2d3f0055a5afd94ec87d27b6e5bc204b9415` |

The bundled DOCX still refers to `Planck_BIOS_1.15`. It is stale and does not
match the 1.16 outer package.

## Execution Chain

1. `Planck_BIOS_1.16.exe` is an ARM64 PE32+ launcher.
2. It scans its own last 8 KiB for the `FE&FR&SH` table.
3. The launcher extracts five files into a temporary directory.
4. It loads `USilenceExt.dll!IWannaRun`; if that DLL is unavailable, it runs
   `s_default.bat`.
5. The batch file preserves the CAP file, comments out the CLI updater, and
   starts `windows.exe`.
6. `windows.exe` is a 32-bit PyInstaller/Tk GUI with the Python 3.7 runtime.
7. `QCFirmwareUpdate.exe` is the ARM64 UEFI FMP capsule staging tool.
8. It copies `qcfirmwarePK850116.cap` to `EFI\UpdateCapsule\`, enables the
   mass-storage capsule flag through UEFI variables, and requests a reboot.
9. The platform firmware processes the staged capsule on the next boot.

`QCFirmwareUpdate.exe` imports `Get/SetFirmwareEnvironmentVariableW`,
`DeviceIoControl`, and EFI partition discovery APIs. Its PDB exposes symbols
such as `CopyFMPCapsulesToESP`, `ValidateAndCopyFMPCapsuleToESP`,
`GetFirmwareEnvironmentVariableAccess`, and `ReadLastUpdateResult`.

## Launcher Overlay

The `FE&FR&SH` table at file offset `0x1f14000` contains five entries:

| Entry | Offset | Size | Name |
|---|---:|---:|---|
| 0 | `0x78a00` | 23,221,587 | `qcfirmwarePK850116.cap` |
| 1 | `0x169e000` | 147,136 | `QCFirmwareUpdate.exe` |
| 2 | `0x16c2000` | 1,290,240 | `QCFirmwareUpdate.pdb` |
| 3 | `0x17fd000` | 167 | `s_default.bat` |
| 4 | `0x17fd200` | 7,433,708 | `windows.exe` |

Run `extract_payload.py` to reproduce these files.

## FMP Capsule

The CAP is a standard UEFI Firmware Management Protocol capsule:

| Field | Value |
|---|---|
| Capsule GUID | `6dcbd5ed-e82d-4c44-bda1-7194199ad92a` |
| Header size | `0x20` |
| Flags | `0x00050000` |
| Capsule size | `0x01625553` |
| FMP version | `1` |
| Embedded drivers | `0` |
| Payload images | `1` |
| Image type GUID | `ac9c5007-a27e-4cc8-b031-63354f926f56` |
| Image index | `1` |
| Capsule support | `2` |
| Payload offset | `0x60` |

The payload contains a UEFI Firmware Volume at `0xa53`, length
`0x01624b00`. The FV begins with filesystem GUID
`8c8ce578-8a3d-4f1c-9935-896185c32dd3`.

## Firmware Images

The FFS image-selection table in FFS file 10 maps the raw files to platform
partitions. Main names are listed below; corresponding backup names also exist.

| FFS | Partition name | Architecture/format | Payload size | Key version |
|---|---|---|---:|---|
| 0 | XBL | ELF64 AArch64 | 3,275,344 | `BOOT.XF.2.2-00080-SDM845WZB-1` |
| 1 | XBL_CONFIG | ELF64 container | 98,124 | XBL configuration |
| 2 | AOP | ELF32 ARM | 184,364 | AOP/PDC |
| 3 | ImageFv | ELF32 ARM | 20,480 | UEFI image data |
| 4 | QUP | ELF32 Qualcomm Hexagon | 65,303 | QUP firmware |
| 5 | HYP | ELF64 AArch64 | 390,096 | Qualcomm Hypervisor |
| 6 | DEVCFG | ELF64 AArch64 | 40,072 | Device configuration |
| 7 | TZ | ELF64 AArch64 | 2,060,288 | `TZ.XF.5.0.1-00146` |
| 8 | TZAPPS | FAT12 image | 16,711,680 | TrustZone applications |
| 9 | PLAT | ELF32 ARM | 360,448 | Platform/ACPI data |
| 10 | image table | Qualcomm table | 12,360 | Maps images to primary/backup partitions |

Notable XBL build fingerprints:

- `IMAGE_VARIANT_STRING=SDM845WP`
- `OEM_IMAGE_VERSION_STRING=tiange`
- `QC_IMAGE_VERSION_STRING=BOOT.XF.2.2-00080-SDM845WZB-1`
- UEFI label `UEFI.4.1`, build date `Jul 22 2019`
- `ECBootFlashApp = "BootFlashEc"`

Run `extract_ffs.py` to reproduce the 11 raw FFS payloads and `manifest.json`.

## TZAPPS Contents

The FAT12 image contains:

```text
TZAPPS/CMNLIB.MBN
TZAPPS/CMNLIB64.MBN
TZAPPS/HDCP1.MBN
TZAPPS/HDCP2P2.MBN
TZAPPS/HDCPSRM.MBN
TZAPPS/MSSECAPP.MBN
TZAPPS/PR_3_0.MBN
TZAPPS/STORSEC.MBN
TZAPPS/UEFISEC.MBN
TZAPPS/WINSECAP.MBN
TZAPPS/FINGERPR.MBN
```

Run `list_fat12.py` to reproduce the complete file listing.

## UEFI DXE Volume and Setup Applications

One XBL segment contains an LZMA-guided DXE firmware volume. Expanding it yields
an 11,117,000-byte firmware volume with 163 FFS modules, including:

- `SetupUtility`
- `BootMenu`
- `QcomBds`
- `BootFlashEc`
- `WinPE`
- `WinRE`
- `QcomChargerApp`
- `Fastboot` and `Ebl`

`SetupUtility` exposes the following major pages and settings:

| Page | Confirmed settings |
|---|---|
| Front Page | Continue, Select Language, Reset |
| Main | Platform Information, Bootable Device, Language |
| Platform Information | Product Name, Serial Number, UUID, BIOS Version, EC Version, CPU/Memory/Disk Information |
| Advanced | Date, Time, Bootup NumLock State, File Explorer, Out-Of-Band Mgmt Port |
| Security | Setup Password, POST Password, Secure Boot, BIOS Version Anti-rollback, Keep Setup Values after BIOS Update, Other Wakeup Source, Clear TPM |
| Boot Options | Boot Next, timeout, memory check type, UEFI Optimized Boot, boot/driver add-delete-order, console input/output/error, output mode, COM settings, legacy drive order |
| Exit | Save and Exit, Exit without Saving, Load Default |

The `QcomBds` module contains explicit hotkey paths:

| Key | Evidence/action |
|---|---|
| `F2` | `F2 is pressed.`; launches `SetupUtility` |
| `F12` | `F12 is pressed.`; launches `BootMenu` |
| `F10` | `F10 is pressed.`; invokes `Planck_F10_Function` and launches `BootFlashEc` |
| `F8` | Also logged by QcomBds; the exact target is not yet confirmed |

Additional boot-time behavior:

- `EnableShell = 0x1`; the internal UEFI Shell is enabled and may be selected
  from the boot manager when present.
- `DetectRetailUserAttentionHotkey = 0x0`; the configured special hotkey is
  `SCAN_ESC`, but that retail attention path is disabled.
- `EnableOEMSetupAppInRetail = 0x0`; the OEM setup application path is disabled.
- `EnablePXE = 0x0`; PXE boot is disabled even though PXE-related UI strings are
  present.

These are hidden or maintenance entries rather than ordinary setup pages.

## EC Firmware and Update Path

The DXE volume contains a standalone 256 KiB EC image:

- Path: `ec/PK850115.bin`
- SHA-256:
  `ae41a4270d9e63da3a0a8b4a603752eac91533560ec376b037ce5c02e76a23de`
- Version: `PK850115`
- Date: `2019/04/26`
- Board/build string: `HB30C4J7ECW-21`, `GM0`
- Architecture: embedded 8051-style EC firmware

The update chain is:

1. `QcomBds` detects F10 or the BIOS update flow selects `ECBootFlashApp`.
2. `BootFlashEc` reads the onboard EC version over I2C.
3. It locates `PK850115` in the BIOS image.
4. If versions differ, it prompts for Volume Up/Volume Down confirmation.
5. It transfers 4 KiB sectors through the EC I2C interface, erases, verifies,
   writes, sets the not-mirror command, and resets the EC.
6. A successful update ends with an EC/system reset.

Confirmed `BootFlashEc` CLI strings include:

```text
BootFlashEc -ver
BootFlashEc -f xxx.bin
```

This is a real EC update engine, not merely an EC version display. Static
reverse engineering can continue into the 8051 image and the BootFlashEc
protocol, but testing write behavior on hardware carries a high recovery risk.

## EC 8051 First-Pass Analysis

The extracted EC image is a valid 8051 program image:

- Reset entry is `LJMP 0070h`.
- Startup sets `SP=0C0h`, initializes XRAM through `MOVX`, and calls routines at
  `180Ah`, `1BEDh`, and `1722h`.
- The image has an extended interrupt-vector table in the first 64 bytes.
- The `UUITE EC-V14.6` marker and the `PK850115` metadata block identify the EC
  platform and version.
- A full first-pass disassembly is available as `ec/PK850115.asm`.

The host-side `BootFlashEc` implementation reveals these protocol details:

- I2C slave address: `76h`.
- I2C bus selector passed by the UEFI driver: `8`.
- The version/status path uses a two-byte command buffer whose first byte is
  `21h`, then reads three bytes back and validates them as decimal digits.
- Update data is processed in 4 KiB sectors with separate erase, write, and
  verify calls.
- A raw command pair `A5 5Ah` is sent through the EC protocol during the update
  sequence.
- The final stage programs the EC mirror-control/not-mirror flag and resets the
  EC.

The EC command string table also contains a USB Power Delivery stack, including:

```text
PWR_SRC_CAP, PWR_SNK_CAP, PWR_OBJ_REQ
DP_SNK_IDENTITY, DPALT_ENTER, DPALT_EXIT
TYPE_DP_CONFIGURE, TYPE_I2C_MASTER_WRITE
PD3_SRC_CAP, PD3_BATT_CAP, PD3_GET_SRC_CAP
PD3_FR_SWAP, PD3_GET_PPS_STS
```

This confirms that the EC also implements USB-PD, DisplayPort Alt Mode, and an
I2C-master bridge. Those paths can be mapped to the ACPI/I2C interfaces exposed
to Linux in a later pass.

## ACPI and Community Protocol Cross-Check

The platform ACPI was extracted from the `PLAT` image and from the DXE firmware
volume. It provides a second, independent description of the EC interface:

| File | Source |
|---|---|
| `acpi/DSDT.aml` | `ffs/09_...bin`, offset `0xd000`, length `0x41104` |
| `acpi/SSDT-SSDT1Tbl.aml` | DXE volume, offset `0x47c7b4`, length `0x36dc` |
| `acpi/SSDT-SSDT2Tbl.aml` | DXE volume, offset `0x490f64`, length `0x2bac` |
| `acpi/SSDT-UsbTCTbl.aml` | DXE volume, offset `0x4740f4`, length `0x653` |

ACPI confirms the hardware binding and the runtime protocol:

- EC is reached through GENI I2C8 at MMIO `0x0089c000`.
- The 7-bit slave address is `0x76` and the bus runs at 400 kHz.
- The event input is ACPI GIO token `0x140`, routed to `I2C8.INTC()`.
  The latest board DTS resolves that signal to TLMM GPIO 40 with
  `IRQ_TYPE_LEVEL_LOW`.
- `0x31` returns events; `0x21` is the common command/response mailbox;
  `0x20`, `0xa0`, `0xa1` and `0xa2` implement backlight and UCSI access.
- Battery commands `0x80`, `0x8c`, `0xdb` and `0xdd` have the same meaning as
  in the community driver.
- UCSI uses request selectors `0x00` for version/CCI/message data and `0x40`
  for HPD/port status.

The full mapping, byte layouts, event table, EC-space operations, DTS gap and
remaining 8051 limitations are in `EC-PROTOCOL.md`.

The newer New-Wheat board source contains:

```text
&i2c7 {
    embedded_controller: ec@76 {
        compatible = "huawei,planck-ec";
        reg = <0x76>;
        interrupts-extended = <&tlmm 40 IRQ_TYPE_LEVEL_LOW>;
    };
};
```

This agrees with the official ACPI `_AEI` entry, which describes the same event
line as level-triggered and active-low. The older DTB shipped with the local
battery module was missing this property, which explains the earlier
discrepancy.

Mainline v7.3.5 and current master still have only `/* ec@0x76 */` near `&i2c7`.
A downstream patch now adds the full node, GPIO 40 interrupt, pinctrl,
USB-C connector and HS/SS graph links:

`patches/0001-arm64-dts-qcom-sdm850-planck-add-ec.patch`.

The patch applies cleanly to the mainline v7.3.5 board DTS, and the result compiles
successfully with `dtc`. The generated interrupt cell decodes as GPIO 40 with
`IRQ_TYPE_LEVEL_LOW`.

## EC Bank and Far-Call Recovery

The extracted EC image is 256 KiB, but the initial disassembler silently read
only the first 64 KiB. Four physical 64 KiB slices are now recorded under
`ec/banks/`; the last slice is entirely erased. Slice 0 contains the boot code,
version block, strings and a far-call mechanism; slices 1 and 2 contain
additional code, including USB-PD logic.

The firmware far-call stub at `0x1800` saves registers and then uses `ret` with
DPTR to transfer execution. Supplying the discovered DPTR targets as explicit
entry points reaches substantial code that the reset-only pass treated as data,
including `0x8d58`, `0x9000`, `0xdd20`, `0xde13` and `0xdfaa`.

Generated disassembly:

- `ec/bank0.vectors.asm`: slice 0 with interrupt vectors.
- `ec/PK850115.far.asm`: slice 0 with 354 far entry points.
- `ec/slices/`: focused disassembly used to resolve code and data boundaries.

The host protocol is now well-supported by ACPI and the community driver. The
internal bank mapping, EC slave dispatch routine and all USB-PD handlers are
still not fully reconstructed, so these results remain static-analysis only.

## Mainline v7.3.5 Driver Port

The community EC, battery and UCSI sources have been ported to the mainline
v7.3.5 interfaces and split into an ordered patch series under `patches/`:

1. `0001-arm64-dts-qcom-sdm850-planck-add-ec.patch`
2. `0002-platform-arm64-huawei-planck-ec.patch`
3. `0003-power-supply-huawei-planck-battery.patch`
4. `0004-usb-typec-ucsi-huawei-planck.patch`

The port includes fixes beyond copying the community files:

- Updated the current UCSI `sync_control` callback to pass message-out data.
- Replaced the invalid 49-byte SMBus block write with a direct I2C transfer.
- Fixed EC event-read error propagation and command error handling.
- Added short-read detection for command responses.
- Corrected battery little-endian comparisons and capacity division by zero.
- Fixed adapter property error propagation and power-supply lifetime handling.
- Switched to `devm_auxiliary_device_create()`.
- Added the forward and reverse USB HS/SS graph links.

The patch series applies cleanly to the Linux 7.3.5 board source. All three
drivers compile and link as `aarch64` modules with `vermagic=7.3.5-dirty`.
The patched DTS also compiles successfully. Hardware probing is still pending.

Apply/build details are in `patches/README.md`.

## Interpretation

- BIOS 1.16 is a full platform firmware capsule, not only a UEFI code update.
- The next boot updates XBL, AOP, UEFI, Hypervisor, TrustZone, TrustZone
  applications, QUP and platform configuration together.
- EC flashing is referenced by the XBL boot configuration, so EC staging is
  part of the boot-time firmware update flow.
- The extracted artifacts can support offline inspection or research, but they
  are not a Linux-native flashing tool. Do not copy a capsule to the ESP or
  change Secure Boot variables manually on production hardware.
