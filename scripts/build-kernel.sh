#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_tools aarch64-linux-gnu-gcc bc bison flex make rsync
ensure_dirs

KERNEL_DIR="${WORK_DIR}/sources/linux"
BUILD_DIR="${WORK_DIR}/kernel-build"
STAGE_DIR="${WORK_DIR}/kernel-stage"
BOOT_DIR="${WORK_DIR}/boot"
[[ -d ${KERNEL_DIR}/.git ]] || die "内核源码不存在；请先运行 fetch-sources.sh"

safe_recreate_dir "${BUILD_DIR}"
safe_recreate_dir "${STAGE_DIR}"
safe_recreate_dir "${BOOT_DIR}"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=matebook-e2019-archlive
kbuild_timestamp="@$(git -C "${KERNEL_DIR}" show -s --format=%ct HEAD)"
export KBUILD_BUILD_TIMESTAMP="${kbuild_timestamp}"

log "合并 arm64 defconfig 与 Live/PAK-AL09 配置"
make -C "${KERNEL_DIR}" O="${BUILD_DIR}" defconfig
"${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -O "${BUILD_DIR}" \
  "${BUILD_DIR}/.config" "${CONFIG_DIR}/kernel.fragment"
make -C "${KERNEL_DIR}" O="${BUILD_DIR}" olddefconfig

required_configs=(
  'CONFIG_BLK_DEV_INITRD=y'
  'CONFIG_SQUASHFS=y'
  'CONFIG_OVERLAY_FS=y'
  'CONFIG_RD_ZSTD=y'
  'CONFIG_MODULE_COMPRESS_ZSTD=y'
  'CONFIG_USB_DWC3=y'
  'CONFIG_USB_DWC3_QCOM=y'
  'CONFIG_PHY_QCOM_QMP=y'
  'CONFIG_PHY_QCOM_QMP_USB=y'
  'CONFIG_PHY_QCOM_QUSB2=y'
  'CONFIG_USB_STORAGE=y'
  'CONFIG_USB_UAS=y'
  'CONFIG_EC_HUAWEI_PLANCK=m'
  'CONFIG_BATTERY_HUAWEI_PLANCK=m'
  'CONFIG_UCSI_HUAWEI_PLANCK=m'
  'CONFIG_QCOM_QSEECOM=y'
  'CONFIG_QCOM_QSEECOM_UEFISECAPP=y'
)
for setting in "${required_configs[@]}"; do
  grep -Fxq "${setting}" "${BUILD_DIR}/.config" || die "内核配置未满足：${setting}"
done

jobs="${JOBS:-$(nproc)}"
log "交叉编译 Image、modules 与 DTB（并行度 ${jobs}）"
make -C "${KERNEL_DIR}" O="${BUILD_DIR}" -j"${jobs}" Image modules dtbs
make -C "${KERNEL_DIR}" O="${BUILD_DIR}" -j"${jobs}" \
  INSTALL_MOD_PATH="${STAGE_DIR}" INSTALL_MOD_STRIP=1 modules_install

kernel_release="$(make -s -C "${KERNEL_DIR}" O="${BUILD_DIR}" kernelrelease)"
printf '%s\n' "${kernel_release}" >"${WORK_DIR}/kernel-release"
install -m 0644 "${BUILD_DIR}/arch/arm64/boot/Image" "${BOOT_DIR}/Image"
install -d -m 0755 "${BOOT_DIR}/dtb/qcom"
install -m 0644 "${BUILD_DIR}/arch/arm64/boot/dts/${DEVICE_DTB}" \
  "${BOOT_DIR}/dtb/${DEVICE_DTB}"
install -m 0644 "${BUILD_DIR}/.config" "${BOOT_DIR}/kernel.config"

[[ -s ${BOOT_DIR}/Image ]] || die "Image 未生成"
[[ -s ${BOOT_DIR}/dtb/${DEVICE_DTB} ]] || die "PAK-AL09 DTB 未生成"
[[ -d ${STAGE_DIR}/lib/modules/${kernel_release} ]] || die "内核模块未安装"
log "内核构建完成：${kernel_release}"
