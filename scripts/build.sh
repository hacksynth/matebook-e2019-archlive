#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_tools bsdtar sha256sum zstd

# STAGE 允许把耗时最长的内核编译与 rootfs/介质打包拆成独立 CI 步骤，
# 这样内核产物可以先写入 actions/cache，后续步骤失败时下一轮无需重编译。
stage="${STAGE:-all}"
case "${stage}" in
  all|kernel|media) ;;
  *) die "STAGE 必须是 all、kernel 或 media，当前为：${stage}" ;;
esac

clean_intermediates="${CLEAN_INTERMEDIATES:-0}"
case "${clean_intermediates,,}" in
  1|true|yes) clean_intermediates=1 ;;
  *) clean_intermediates=0 ;;
esac

prepare_workspace() {
  log "清理旧工作目录（保留经过验证的下载缓存）"
  ensure_dirs
  safe_recreate_dir "${WORK_DIR}"
  safe_recreate_dir "${OUT_DIR}"
}

build_kernel_stage() {
  bash "${SCRIPT_DIR}/fetch-sources.sh"
  bash "${SCRIPT_DIR}/build-kernel.sh"

  # GitHub Release 公开分发内核/模块时，同时提供应用全部固定补丁后的完整 GPL 对应源码。
  source_archive="${OUT_DIR}/${LINUX_SOURCE_ARCHIVE}"
  log "生成完整已补丁内核对应源码：${LINUX_SOURCE_ARCHIVE}"
  bsdtar -cf - --exclude 'linux/.git' --exclude 'linux/.git/*' \
    -C "${WORK_DIR}/sources" linux | \
    zstd --threads=0 -10 -o "${source_archive}"
  [[ -s ${source_archive} ]] || die "内核对应源码归档未生成"
  archive_list="${WORK_DIR}/linux-source.list"
  bsdtar -tf "${source_archive}" >"${archive_list}"
  if grep -Eq '(^|/)\.git(/|$)' "${archive_list}"; then
    die "内核对应源码归档意外包含 .git"
  fi
  device_dts="${DEVICE_DTB%.dtb}.dts"
  grep -Fxq "linux/arch/arm64/boot/dts/${device_dts}" "${archive_list}" || \
    die "内核对应源码归档缺少 ${DEVICE_MODEL} 上游设备树：${device_dts}"
  rm -f -- "${archive_list}"

  if ((clean_intermediates)); then
    log "低磁盘模式：删除 kernel-build 与内核 worktree（保留补丁、来源锁和模块 staging）"
    safe_remove_dir "${WORK_DIR}/kernel-build"
    safe_remove_dir "${WORK_DIR}/sources/linux"
  fi
}

build_media_stage() {
  [[ -s ${WORK_DIR}/kernel-release ]] || die "缺少内核构建结果；请先以 STAGE=kernel 构建"
  # 私有仓库可在 vendor-firmware/ 保存当前设备固件；显式环境变量仍可覆盖该目录。
  if [[ -z ${VENDOR_FIRMWARE_DIR:-} && -d ${REPO_ROOT}/vendor-firmware ]]; then
    export VENDOR_FIRMWARE_DIR="${REPO_ROOT}/vendor-firmware"
    log "使用私有仓库内的设备固件：${VENDOR_FIRMWARE_DIR}"
  fi
  bash "${SCRIPT_DIR}/prepare-rootfs.sh"
  if ((clean_intermediates)); then
    log "低磁盘模式：删除展开 rootfs；保留内核 staging 供其他 flavor 复用"
    safe_remove_dir "${WORK_DIR}/rootfs"
    if [[ ${stage} == all ]]; then
      safe_remove_dir "${WORK_DIR}/kernel-stage"
    fi
  fi
  bash "${SCRIPT_DIR}/build-media.sh"

  install -m 0644 "${WORK_DIR}/iso-root/BUILD-INFO.txt" \
    "${OUT_DIR}/BUILD-INFO${LIVE_FLAVOR_SUFFIX}.txt"
  install -m 0644 "${WORK_DIR}/live/packages.txt" \
    "${OUT_DIR}/packages${LIVE_FLAVOR_SUFFIX}.txt"
  install -m 0644 "${WORK_DIR}/boot/kernel.config" "${OUT_DIR}/kernel.config"
  install -m 0644 "${CONFIG_DIR}/versions.env" "${OUT_DIR}/SOURCE-LOCK.env"
  install -m 0644 "${CONFIG_DIR}/device.env" "${OUT_DIR}/DEVICE-PROFILE.env"

  (
    cd "${OUT_DIR}"
    checksum_tmp="${WORK_DIR}/SHA256SUMS.tmp"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | \
      xargs -r sha256sum --binary >"${checksum_tmp}"
    mv -f -- "${checksum_tmp}" SHA256SUMS
  )
  [[ -s ${OUT_DIR}/SHA256SUMS ]] || die "SHA256SUMS 未生成"
  # 所有 flavor 共用同一份 WORK_DIR 的内核产物，因此这里不删除 WORK_DIR；
  # GitHub runner 是一次性的，本地可自行清理 .work/。
  log "介质阶段完成（flavor=${LIVE_FLAVOR}）：${LIVE_IMAGE_BASENAME}"
}

case "${stage}" in
  kernel)
    prepare_workspace
    build_kernel_stage
    log "内核阶段完成；中间产物保留在 ${WORK_DIR}"
    ;;
  media)
    build_media_stage
    log "介质阶段完成；产物位于 ${OUT_DIR}"
    ;;
  all)
    prepare_workspace
    build_kernel_stage
    build_media_stage
    log "全部完成；产物位于 ${OUT_DIR}"
    ;;
esac
