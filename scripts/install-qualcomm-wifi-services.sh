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

arch-meson "${work_dir}/tqftpserv" "${work_dir}/tqftpserv/build" \
  --prefix=/usr --buildtype=release \
  -Dsystemd-unit-prefix=/usr/lib/systemd/system
meson compile -C "${work_dir}/tqftpserv/build"
meson install -C "${work_dir}/tqftpserv/build"

make -C "${work_dir}/pd-mapper" -j"$(nproc)"
make -C "${work_dir}/pd-mapper" prefix=/usr install
ldconfig

for binary in /usr/bin/tqftpserv /usr/bin/pd-mapper /usr/bin/qrtr-lookup; do
  [[ -x ${binary} ]] || {
    echo "missing Qualcomm Wi-Fi helper: ${binary}" >&2
    exit 1
  }
done
for unit in tqftpserv.service pd-mapper.service ath10k-wcn3990.service; do
  [[ -f /usr/lib/systemd/system/${unit} ]] || {
    echo "missing Qualcomm Wi-Fi unit: ${unit}" >&2
    exit 1
  }
done

systemctl enable tqftpserv.service pd-mapper.service ath10k-wcn3990.service

pacman --noconfirm -Rns gcc make meson ninja pkgconf
