# Huawei MateBook E 2019 Mainline v7.3 Patch Series

Base tree: `torvalds/linux` tag `v7.3`, commit
`c03c1a14507dfaf8b856c2608f9ac216021fc222`.

Apply in numerical order:

```sh
patch -p1 < 0001-arm64-dts-qcom-sdm850-planck-add-ec.patch
patch -p1 < 0002-platform-arm64-huawei-planck-ec.patch
patch -p1 < 0003-power-supply-huawei-planck-battery.patch
patch -p1 < 0004-usb-typec-ucsi-huawei-planck.patch
```

The series contains:

| Patch | Content |
|---|---|
| `0001` | EC node, GPIO 40 level-low IRQ, USB-C connector and DT graph links |
| `0002` | EC transport, lid input, backlight, auxiliary devices and Kconfig |
| `0003` | Battery/adapter power supplies |
| `0004` | UCSI and DisplayPort HPD |

All four patches pass `patch --dry-run -p1` against a clean v7.3 archive.
The resulting drivers compile as ARM64 modules:

```text
drivers/platform/arm64/huawei-planck-ec.ko
drivers/power/supply/huawei-planck-battery.ko
drivers/usb/typec/ucsi/ucsi_huawei_planck.ko
```

The local compile used a modules-only tree, so `modpost` was invoked with
`KBUILD_MODPOST_WARN=1`: unresolved core-kernel symbols are expected without a
built `vmlinux`. No C compiler warning was emitted for the three drivers.

The patched board DTS also compiles with `dtc`; its EC interrupt cells resolve
to GPIO 40 and `IRQ_TYPE_LEVEL_LOW`.

No hardware access or EC write was performed.
