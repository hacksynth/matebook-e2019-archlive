#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_tools aarch64-linux-gnu-gcc bc bison flex make rsync sha256sum
ensure_dirs

KERNEL_DIR="${WORK_DIR}/sources/linux"
BUILD_DIR="${WORK_DIR}/kernel-build"
STAGE_DIR="${WORK_DIR}/kernel-stage"
BOOT_DIR="${WORK_DIR}/boot"
[[ -d ${KERNEL_DIR}/.git ]] || die "内核源码不存在；请先运行 fetch-sources.sh"

# 上游设备树必须仍与当前 PAK-AL09 基线一致。这样上游改树后会在耗时编译前失败关闭。
device_dts_source="${KERNEL_DIR}/arch/arm64/boot/dts/${DEVICE_DTB%.dtb}.dts"
[[ -s ${device_dts_source} ]] || \
  die "内核源码缺少 ${DEVICE_MODEL} 设备树：${device_dts_source}"
for expected_dts_line in \
  'compatible = "huawei,planck", "qcom,sdm845";' \
  'compatible = "innolux,p120zdg-bf1";' \
  'qcom,calibration-variant = "Huawei_Planck";' \
  "firmware-name = \"${DEVICE_FIRMWARE_ROOT}/qcadsp850.mbn\";"; do
  grep -Fq "${expected_dts_line}" "${device_dts_source}" || \
    die "${DEVICE_MODEL} 设备树缺少预期硬件描述：${expected_dts_line}"
done

safe_recreate_dir "${BUILD_DIR}"
safe_recreate_dir "${STAGE_DIR}"
safe_recreate_dir "${BOOT_DIR}"

# 内核构建缓存：键包含基线提交、补丁哈希、Kconfig fragment 与构建/取源脚本。
# 命中时跳过约 30 分钟的编译；任何会影响产物的输入变化都会改变键。
kernel_cache_root="${KERNEL_CACHE_DIR:-${CACHE_DIR}/kernel-cache}"
kernel_cache_key="$(cat "${CONFIG_DIR}/versions.env" "${CONFIG_DIR}/device.env" \
  "${CONFIG_DIR}/kernel.fragment" "${SCRIPT_DIR}/build-kernel.sh" \
  "${SCRIPT_DIR}/fetch-sources.sh" | sha256sum | awk '{print $1}')"
kernel_cache_dir="${kernel_cache_root}/${kernel_cache_key}"

restore_cached_kernel() {
  local cached_release
  [[ -f ${kernel_cache_dir}/ready ]] || return 1
  cached_release="$(<"${kernel_cache_dir}/kernel-release")"
  [[ -s ${kernel_cache_dir}/Image ]] || return 1
  [[ -s ${kernel_cache_dir}/dtb/${DEVICE_DTB} ]] || return 1
  [[ -d ${kernel_cache_dir}/modules/${cached_release} ]] || return 1
  install -m 0644 "${kernel_cache_dir}/Image" "${BOOT_DIR}/Image"
  install -D -m 0644 "${kernel_cache_dir}/dtb/${DEVICE_DTB}" \
    "${BOOT_DIR}/dtb/${DEVICE_DTB}"
  install -m 0644 "${kernel_cache_dir}/kernel.config" "${BOOT_DIR}/kernel.config"
  install -d -m 0755 "${STAGE_DIR}/lib/modules"
  rsync -aH "${kernel_cache_dir}/modules/${cached_release}/" \
    "${STAGE_DIR}/lib/modules/${cached_release}/"
  printf '%s\n' "${cached_release}" >"${WORK_DIR}/kernel-release"
  log "命中内核缓存 ${kernel_cache_key:0:12}：跳过编译，复用 ${cached_release}"
  return 0
}

store_kernel_cache() {
  local release="$1"
  install -d -m 0755 "${kernel_cache_root}"
  safe_remove_dir "${kernel_cache_dir}"
  install -d -m 0755 "${kernel_cache_dir}/dtb/qcom" \
    "${kernel_cache_dir}/modules/${release}"
  install -m 0644 "${BOOT_DIR}/Image" "${kernel_cache_dir}/Image"
  install -m 0644 "${BOOT_DIR}/dtb/${DEVICE_DTB}" \
    "${kernel_cache_dir}/dtb/${DEVICE_DTB}"
  install -m 0644 "${BOOT_DIR}/kernel.config" "${kernel_cache_dir}/kernel.config"
  printf '%s\n' "${release}" >"${kernel_cache_dir}/kernel-release"
  rsync -aH "${STAGE_DIR}/lib/modules/${release}/" \
    "${kernel_cache_dir}/modules/${release}/"
  printf 'ok %s\n' "${release}" >"${kernel_cache_dir}/ready"
  log "内核构建已写入缓存：${kernel_cache_dir}"
}

if restore_cached_kernel; then
  exit 0
fi

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=matebook-e2019-archlive
kbuild_timestamp="@$(git -C "${KERNEL_DIR}" show -s --format=%ct HEAD)"
export KBUILD_BUILD_TIMESTAMP="${kbuild_timestamp}"

log "合并 arm64 defconfig 与 Live/${DEVICE_MODEL} 配置"
make -C "${KERNEL_DIR}" O="${BUILD_DIR}" defconfig
"${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -O "${BUILD_DIR}" \
  "${BUILD_DIR}/.config" "${CONFIG_DIR}/kernel.fragment"
make -C "${KERNEL_DIR}" O="${BUILD_DIR}" olddefconfig

required_configs=(
  'CONFIG_BLK_DEV_INITRD=y'
  'CONFIG_SQUASHFS=y'
  'CONFIG_OVERLAY_FS=y'
  'CONFIG_EXFAT_FS=y'
  'CONFIG_NLS_UTF8=y'
  'CONFIG_CFG80211=m'
  'CONFIG_MAC80211=m'
  'CONFIG_ATH10K=m'
  'CONFIG_ATH10K_SNOC=m'
  'CONFIG_RD_ZSTD=y'
  'CONFIG_MODULE_COMPRESS_ZSTD=y'
  'CONFIG_USB_DWC3=y'
  'CONFIG_USB_DWC3_QCOM=y'
  'CONFIG_PHY_QCOM_QMP=y'
  'CONFIG_PHY_QCOM_QMP_USB=y'
  'CONFIG_PHY_QCOM_QUSB2=y'
  'CONFIG_USB_STORAGE=y'
  'CONFIG_USB_UAS=y'
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
[[ -s ${BOOT_DIR}/dtb/${DEVICE_DTB} ]] || die "${DEVICE_MODEL} DTB 未生成"
[[ -d ${STAGE_DIR}/lib/modules/${kernel_release} ]] || die "内核模块未安装"
store_kernel_cache "${kernel_release}"
log "内核构建完成：${kernel_release}"
