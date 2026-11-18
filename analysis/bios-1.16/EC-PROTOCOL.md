# Huawei MateBook E 2019 EC Host Protocol

Static-analysis findings from the official BIOS 1.16 image. No command was sent
to a real EC and no firmware was flashed.

## Evidence

The strongest evidence is the platform ACPI, not the Linux driver alone:

- `acpi/SSDT-SSDT1Tbl.dsl` defines `I2C8.ECI2`, all EC mailbox fields,
  battery methods, event dispatch, UCSI notification and HPD handling.
- `acpi/SSDT-UsbTCTbl.dsl` defines the Windows UCSI mailbox that forwards
  commands through the EC.
- `reference/huawei_planck_ec.patch` provides the community Linux interface.
- `reference/sdm850-huawei-matebook-e-2019.dts` is the decompiled community
  DTB used by the existing battery module.

The current community source was cross-checked from
`New-Wheat/Linux-for-HUAWEI-MateBook-E-2019` at commit
`499401e36f17b463b633aef1283d2ed82eebbc52`. The saved board source has
SHA-256 `b03b21888dcf88bc9dc9ae1e6295daada5c5665497e0c397dc067b8d09ebbc85`.
Mainline v7.3 and current master have the same board DTS
(`117e69c4938340446be4b72b554ffdc7dd34e5f00ae310c60435183aad98328b`).

Relevant AML hashes:

| File | SHA-256 |
|---|---|
| `acpi/DSDT.aml` | `90d66877622a09be3175e9111bcb886793a6b52ef976b2e8aeba4e4810d70a11` |
| `acpi/SSDT-SSDT1Tbl.aml` | `f85cd2fed9dce96856599206610c16c65769052aa01e33c2cb57be89d2a08f93` |
| `acpi/SSDT-SSDT2Tbl.aml` | `59c8468e93aec0e60fae457bdb6ed989ae2a7018745c141c3a39d7b17311e235` |
| `acpi/SSDT-UsbTCTbl.aml` | `e19d2dd7a1cab6c8201c4e7417ee9c136d3b63edfae11315ca795bf6311ee7b1` |

## Hardware Binding

| Item | Value | Evidence |
|---|---|---|
| I2C controller | GENI I2C8, MMIO `0x0089c000`, 16 KiB | DSDT `Device (I2C8)` and DTS |
| Parent QUP | `geniqup@8c0000` | community DTS |
| EC 7-bit address | `0x76` | ACPI `I2cSerialBusV2` and DTS `ec@76` |
| Bus frequency | 400 kHz (`0x61a80`) | ACPI connection and DTS `clock-frequency` |
| EC event input | ACPI GIO token `0x140` -> TLMM GPIO 40 | ACPI `_AEI`, community/mainline DTS |
| EC interrupt type | Level-low | ACPI `GpioInt` and Linux DTS |
| Event route | `GIO0._EVT` -> `I2C8.INTC()` | SSDT1 |

`0x140` is the ACPI GPIO numbering used by the firmware and does not mean Linux
TLMM hwirq 320. The latest New-Wheat device tree resolves the same event line as:

```text
interrupts-extended = <&tlmm 40 IRQ_TYPE_LEVEL_LOW>;
```

The ACPI `_AEI` entry independently confirms a level-triggered, active-low,
exclusive-and-wake GPIO:

```text
GpioInt (Level, ActiveLow, ExclusiveAndWake, PullUp, ...) { 0x0140 }
```

The trigger type therefore agrees exactly. ACPI requests an internal pull-up,
while the latest community DTS uses `bias-disable` on `gpio40`. The latter has
been used by the community kernel; if the IRQ proves unstable, the
`bias-pull-up` variant is the first firmware-backed alternative to test.

The latest New-Wheat source has the complete node:

```text
&i2c7 {
    embedded_controller: ec@76 {
    compatible = "huawei,planck-ec";
    reg = <0x76>;

        interrupts-extended = <&tlmm 40 IRQ_TYPE_LEVEL_LOW>;
        pinctrl-0 = <&ec_int_default>;
        pinctrl-names = "default";

        connector {
            compatible = "usb-c-connector";
            ...
        };
    };
};
```

The local DTB shipped with the existing battery-only module is older and lacks
the IRQ. Mainline v7.3 still contains only the placeholder:

```text
&i2c7 {
    /* ec@0x76 */
};
```

A tested patch for mainline v7.3/master is provided at:

```text
patches/0001-arm64-dts-qcom-sdm850-planck-add-ec.patch
```

It adds the EC node, GPIO 40 level-low IRQ, pinctrl state, USB-C connector and
the reverse HS/SS graph links. The patch applies cleanly to the mainline v7.3
board DTS and the resulting DTS compiles with `dtc`. The ELF paths in the final
DTB decode as GPIO 40 with flag `8` (`IRQ_TYPE_LEVEL_LOW`).

## Register Interface

Boot-time EC flashing and the ACPI runtime interface independently agree on the
slave address and command-oriented mailbox:

| Register | Direction | Purpose |
|---|---|---|
| `0x20` | write block | Backlight control; observed form `[0xff, brightness]` |
| `0x21` | write byte/block | Common command request |
| `0x21` | read block | Common command response |
| `0x31` | read byte | Queued event/notification ID |
| `0x40` | write block | EC-space operation request |
| `0x41` | read block | EC-space operation response |
| `0xa2` | write byte | UCSI request selector (`0x00` data, `0x40` HPD) |
| `0xa0` | read block | UCSI request result |
| `0xa1` | write block | UCSI control/command buffer |

Both the ACPI path and community driver insert a 13 ms delay around frequent
transfers. The ACPI erase path waits 50 ms.

## Events

ACPI `INTC()` reads `0x31` and maps the returned ID as follows:

| Event | Meaning | Action in stock ACPI |
|---:|---|---|
| `0x10` | UCSI event | Read UCSI CCI/message and notify `UBTC` |
| `0x20` | Lid open | Report lid state 1 |
| `0x21` | Lid close | Report lid state 0 |
| `0x22` | Adapter state change | Notify adapter and battery |
| `0x23` | Adapter state change | Notify adapter and battery |
| `0x30` | Battery status | Notify battery |
| `0x31` | Battery status/info | Notify battery status and information |
| `0x32` | Battery status | Notify battery |
| `0x40` | DisplayPort HPD | Read 8-byte port status and notify `UCP0` |

The lid direction agrees with the community driver's `0x20 = open`,
`0x21 = close` interpretation.

## Battery

Commands used by ACPI and the community battery driver:

| Command | Payload | Meaning |
|---:|---:|---|
| `0x80` | 26 bytes | Battery information/telemetry |
| `0x8c` | 1 byte | Battery OEM code |
| `0xdb` | 1 byte | Online/presence flags |
| `0xdd` | 1 byte | Charging/discharging state |

The `0x80` payload is 13 little-endian 16-bit values:

| Word | Field |
|---:|---|
| 0 | Padding/reserved |
| 1 | Serial number |
| 2 | Design capacity |
| 3 | Design voltage |
| 4-7 | Reserved |
| 8 | Present voltage |
| 9 | Signed present current |
| 10 | Last full capacity |
| 11 | Present capacity |
| 12 | Cycle count |

ACPI uses different byte offsets in its raw generic-serial-bus buffer, but the
fields and ordering match this structure.

`0xdb` and `0xdd` flags:

```text
0xdb bit 0: adapter online
0xdb bit 1: battery present
0xdd bit 0: discharging
0xdd bit 1: charging
```

OEM codes match the community driver: `1 = DYNAPACK`, `2 = Sunwoda-S`.

ACPI also references several additional WMI/thermal/charging commands,
including `0x21`, `0x22`, `0x25`, `0x27`, `0x29`, `0x2b`, `0x2c`, `0x2d`,
`0x33`, `0x35`, `0x36`, `0x3a`, `0x3c`, `0x88`, `0x90`, `0x92`, `0x9a`,
`0xd5`, and `0xd7`. Their complete semantics are not yet needed by the mainline
battery, lid and UCSI drivers.

## EC Address Space

Stock ACPI routes EC memory operations through registers `0x40` and `0x41`:

- Read request: operation `0x02`, requested length, and a 24-bit address.
- Erase request: operation `0x02`, sub-operation `0x20`, and a 24-bit address.
- Write request: operation `0x02`, write length, 24-bit address, then data.

ACPI reads and writes the EC update area around `0x00082000`. This agrees with
the separate `BootFlashEc` finding that the UEFI updater uses 4 KiB sectors.

## UCSI and DisplayPort

The EC does not expose a standard UCSI MMIO mailbox directly. It proxies UCSI
through a block interface:

1. Write request selector to `0xa2`.
2. Read the result from `0xa0`.
3. Write UCSI control data to `0xa1`.

Supported request selectors:

```text
0x00: UCSI version/CCI/message-in
0x40: DisplayPort/HPD port status
```

ACPI confirms this data layout:

| UCSI data | Offset |
|---|---:|
| Version, little-endian `u16` | `0x00` |
| Padding | `0x02` |
| CCI, 4 bytes | `0x04` |
| Padding | `0x08` |
| Message-in, 16 bytes | `0x10` |

The UCSI control buffer is 49 bytes in the community driver:

```text
[0..8] padding, [9..16] 64-bit UCSI command, [17..32] padding,
[33..48] message-out
```

The 8-byte HPD/port-status payload maps to:

| Payload byte | Field |
|---:|---|
| 0 | CC status/orientation (`ccst`) |
| 1 | Mux configuration (`muxc`) |
| 2 | DP pin assignment (`dppn`) |
| 3 | HPD flag used by the community DRM bridge path |
| 4-6 | Additional DP status bytes |
| 7 | High-speed flag (`hsfl`) |

ACPI maps bytes 0, 1, 2 and 7 to `CCST`, `MUXC`, `DPPN` and `HSFL`. The
community driver additionally uses byte 3 as its connected/disconnected HPD
decision and selects reverse orientation when CC status is `1`.

## EC Image Layout

`ec/PK850115.bin` is 256 KiB, but `disasm51` has a hard 64 KiB input limit.
The image therefore consists of four physical 64 KiB slices:

| Slice | Content |
|---:|---|
| 0 | Boot/main code, version metadata at `0x8000`, strings and far targets |
| 1 | Populated code |
| 2 | Populated code, including USB-PD work |
| 3 | All `0xff`; no code or data found |

Slice 0 has large erased gaps at `0x3e00..0x7fff` and `0xe700..0xfeff`.

The first-pass disassembly also missed code reached through the firmware's far
call convention. At `0x1800`, the firmware pushes saved state plus DPH/DPL and
uses `ret` to transfer control to a 16-bit address supplied in DPTR. Passing
those far targets back into `disasm51` reaches additional code such as `0x8d58`,
`0x9000`, `0xdd20`, `0xde13` and `0xdfaa`.

Generated artifacts:

| File | Purpose |
|---|---|
| `ec/PK850115.asm` | Initial reset-rooted disassembly |
| `ec/bank0.vectors.asm` | Slice 0 with interrupt-vector entries |
| `ec/PK850115.far.asm` | Slice 0 with 354 discovered far entry points |
| `ec/banks/bank0.bin` ... `bank3.bin` | Four physical slices |
| `ec/slices/*.asm` | Focused bounded disassembly used to resolve code/data boundaries |

The host protocol above is confirmed by independent ACPI and driver evidence.
The internal function-by-function implementation in all EC slices is not yet
fully recovered. SFR names, bank selectors, indirect tables and USB-PD command
handlers remain the main reverse-engineering gap.

## Safety

The EC erase/write path is statically recoverable, but experimentally invoking
it can brick the embedded controller or leave the machine unable to power on.
Do not use these findings as a write recipe on production hardware.
