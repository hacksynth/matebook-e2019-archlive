MATEBOOK E 2019 / PAK-AL09 -- local vendor firmware
===================================================

Source:
  Windows DriverStore on this PAK-AL09 device.

Primary QCOM firmware:
  qcom/sdm850/HUAWEI/AL09/

This directory matches the relative layout expected under Linux
/usr/lib/firmware. For a local Linux build, use:

  sudo VENDOR_FIRMWARE_DIR=/path/to/vendor-firmware bash scripts/build.sh

Windows WCN3990 data:
  windows-wcn3990/

The files under windows-wcn3990/board-data are Windows bdwlan calibration
variants. They are NOT a drop-in replacement for the Linux ath10k
ath10k/WCN3990/hw1.0/board-2.bin container. Keep them only for analysis or
conversion.

The qcom/sdm850/HUAWEI/AL09/alternates directory contains Windows alternate
blob variants and is not selected by the current device tree.

These files are proprietary and device-specific. Do not upload them to a
public repository, release, or artifact service.
