#!/usr/bin/env bash
set -Eeuo pipefail

QMIC_COMMIT="4574736afce75aa5eec1e1069a19563410167c9f"
QRTR_COMMIT="29e36ae164389580a0f8ea7a7fdb728140ae978d"
TQFTP_COMMIT="eb4b9a04ff92d2753ededf32cc3b6ed287f6e29b"
PD_MAPPER_COMMIT="5ecd2fe926aca7abfe40724177f63b942cff3947"

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

install -d -m 0755 /usr/lib/firmware/qcom/sdm850/HUAWEI/AL09
wlanmdsp_target=/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/wlanmdsp.mbn
if [[ ! -s ${wlanmdsp_target} ]]; then
  wlanmdsp_source=""
  for candidate in \
    /usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn \
    /usr/lib/firmware/windows-wcn3990/wlanmdsp.mbn; do
    if [[ -s ${candidate} ]]; then
      wlanmdsp_source="${candidate}"
      break
    fi
  done
  [[ -n ${wlanmdsp_source} ]] || {
    echo "missing WCN3990 wlanmdsp.mbn firmware" >&2
    exit 1
  }
  install -m 0644 "${wlanmdsp_source}" "${wlanmdsp_target}"
fi
[[ -s ${wlanmdsp_target} ]] || {
  echo "WCN3990 firmware mapping is empty: ${wlanmdsp_target}" >&2
  exit 1
}
[[ -s /usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin ]] || {
  echo "missing WCN3990 Linux board-2.bin" >&2
  exit 1
}

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
