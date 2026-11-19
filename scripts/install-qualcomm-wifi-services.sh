#!/usr/bin/env bash
set -Eeuo pipefail

QMIC_COMMIT="4574736afce75aa5eec1e1069a19563410167c9f"
QRTR_COMMIT="29e36ae164389580a0f8ea7a7fdb728140ae978d"
TQFTP_COMMIT="eb4b9a04ff92d2753ededf32cc3b6ed287f6e29b"
PD_MAPPER_COMMIT="5ecd2fe926aca7abfe40724177f63b942cff3947"
WCN3990_FIRMWARE_CHANNEL="${WCN3990_FIRMWARE_CHANNEL:-legacy}"
WCN3990_FIRMWARE_COMMIT="72f3b81c89fbc52677b9dbbfa92cde0ae00a36e2"
WCN3990_WLANMDSP_SHA256="ea1787533f969c084c24292defdcc88d75d71955bea7e12ffee2b5fb16248350"
WCN3990_FIRMWARE_API_SHA256="7f35f16380124ceff31a4c3064fb6f66b366ccd76b517b271a53e4c9029fe41b"

work_dir="$(mktemp -d /tmp/qualcomm-wifi.XXXXXX)"
trap 'rm -rf -- "${work_dir}"' EXIT

download_source() {
  local repo="$1"
  local commit="$2"
  local destination="$3"

  curl --fail --location --retry 5 --retry-all-errors \
    --connect-timeout 30 \
    --output "${destination}" \
    "https://codeload.github.com/linux-msm/${repo}/tar.gz/${commit}"
}

pacman --noconfirm -S --needed \
  gcc make meson ninja pkgconf xz zstd

download_source qmic "${QMIC_COMMIT}" "${work_dir}/qmic.tar.gz"
download_source qrtr "${QRTR_COMMIT}" "${work_dir}/qrtr.tar.gz"
download_source tqftpserv "${TQFTP_COMMIT}" "${work_dir}/tqftpserv.tar.gz"
download_source pd-mapper "${PD_MAPPER_COMMIT}" "${work_dir}/pd-mapper.tar.gz"

for source in qmic qrtr tqftpserv pd-mapper; do
  install -d -m 0755 "${work_dir}/${source}"
  tar -xzf "${work_dir}/${source}.tar.gz" \
    --strip-components=1 -C "${work_dir}/${source}"
done

make -C "${work_dir}/qmic" -j"$(nproc)"
make -C "${work_dir}/qmic" prefix=/usr install

arch-meson "${work_dir}/qrtr" "${work_dir}/qrtr/build" \
  --prefix=/usr --buildtype=release
meson compile -C "${work_dir}/qrtr/build"
meson install -C "${work_dir}/qrtr/build"

# rmtfs-git depends on the manually built qrtr library above. Avoid installing
# qrtr-git, whose files would conflict with the pinned source build.
pacman --noconfirm -S --needed --assume-installed qrtr rmtfs-git

arch-meson "${work_dir}/tqftpserv" "${work_dir}/tqftpserv/build" \
  --prefix=/usr --buildtype=release \
  -Dsystemd-unit-prefix=/usr/lib/systemd/system
meson compile -C "${work_dir}/tqftpserv/build"
meson install -C "${work_dir}/tqftpserv/build"

make -C "${work_dir}/pd-mapper" -j"$(nproc)"
make -C "${work_dir}/pd-mapper" prefix=/usr install
ldconfig

wcn3990_firmware_dir=/usr/lib/firmware/ath10k/WCN3990/hw1.0
wlanmdsp_target=/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/wlanmdsp.mbn
firmware_api_target="${wcn3990_firmware_dir}/firmware-5.bin"
firmware_source_base="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/ath10k/WCN3990/hw1.0/shikra"

[[ -s "${wcn3990_firmware_dir}/board-2.bin" ]] || {
  echo "missing WCN3990 board-2.bin" >&2
  exit 1
}

install -d -m 0755 "${wlanmdsp_target%/*}"
case "${WCN3990_FIRMWARE_CHANNEL}" in
  legacy)
    wlanmdsp_source=
    for candidate in \
      "${wcn3990_firmware_dir}/wlanmdsp.mbn" \
      /usr/lib/firmware/windows-wcn3990/wlanmdsp.mbn; do
      if [[ -s ${candidate} ]]; then
        wlanmdsp_source="${candidate}"
        break
      fi
    done
    [[ -n ${wlanmdsp_source} ]] || {
      echo "missing legacy WCN3990 wlanmdsp.mbn" >&2
      exit 1
    }
    install -m 0644 "${wlanmdsp_source}" "${wlanmdsp_target}"
    ;;
  shikra-experimental)
    # WLAN.HL.3.3.7.c5-00226 is board-specific. It currently fails cold boot
    # on PAK-AL09 with "wlan_process" grace timer timeouts, so this channel is
    # opt-in until MSS/QMI compatibility is resolved.
    for firmware in wlanmdsp.mbn firmware-5.bin; do
      curl --fail --location --retry 5 --retry-all-errors \
        --connect-timeout 30 \
        --output "${work_dir}/${firmware}" \
        "${firmware_source_base}/${firmware}?id=${WCN3990_FIRMWARE_COMMIT}"
    done
    printf '%s  %s\n%s  %s\n' \
      "${WCN3990_WLANMDSP_SHA256}" "${work_dir}/wlanmdsp.mbn" \
      "${WCN3990_FIRMWARE_API_SHA256}" "${work_dir}/firmware-5.bin" |
      sha256sum --check --strict -
    install -m 0644 "${work_dir}/wlanmdsp.mbn" "${wlanmdsp_target}"
    install -m 0644 "${work_dir}/firmware-5.bin" "${firmware_api_target}"
    ;;
  *)
    echo "unknown WCN3990_FIRMWARE_CHANNEL: ${WCN3990_FIRMWARE_CHANNEL}" >&2
    exit 1
    ;;
esac

for binary in /usr/bin/tqftpserv /usr/bin/pd-mapper /usr/bin/qrtr-lookup; do
  [[ -x ${binary} ]] || {
    echo "missing Qualcomm Wi-Fi helper: ${binary}" >&2
    exit 1
  }
done
for unit in tqftpserv.service pd-mapper.service rmtfs.service \
  ath10k-wcn3990.service qcom-mss.service; do
  [[ -f /usr/lib/systemd/system/${unit} ]] || {
    echo "missing Qualcomm Wi-Fi unit: ${unit}" >&2
    exit 1
  }
done

systemctl enable tqftpserv.service pd-mapper.service rmtfs.service \
  ath10k-wcn3990.service qcom-mss.service

# dracut 依赖 pkgconf，不能在 chroot 中删掉它；这里仅清理编译期工具链。
pacman --noconfirm -Rns gcc make meson ninja
