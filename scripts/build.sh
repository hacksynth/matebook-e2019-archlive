#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_tools bsdtar sha256sum zstd

log "清理旧工作目录（保留经过验证的下载缓存）"
ensure_dirs
safe_recreate_dir "${WORK_DIR}"
safe_recreate_dir "${OUT_DIR}"

clean_intermediates="${CLEAN_INTERMEDIATES:-0}"
case "${clean_intermediates,,}" in
  1|true|yes) clean_intermediates=1 ;;
  *) clean_intermediates=0 ;;
esac

bash "${SCRIPT_DIR}/fetch-sources.sh"
bash "${SCRIPT_DIR}/build-kernel.sh"

# GitHub Release 公开分发内核/模块时，同时提供应用全部固定补丁后的完整 GPL 对应源码。
source_archive="${OUT_DIR}/${LINUX_SOURCE_ARCHIVE}"
log "生成完整已补丁内核对应源码：${LINUX_SOURCE_ARCHIVE}"
bsdtar -cf - --exclude 'linux/.git' --exclude 'linux/.git/*' \
  -C "${WORK_DIR}/sources" linux | \
  zstd --threads=0 -10 --output "${source_archive}"
[[ -s ${source_archive} ]] || die "内核对应源码归档未生成"
archive_list="${WORK_DIR}/linux-source.list"
bsdtar -tf "${source_archive}" >"${archive_list}"
if grep -Eq '(^|/)\.git(/|$)' "${archive_list}"; then
  die "内核对应源码归档意外包含 .git"
fi
grep -Fxq 'linux/drivers/platform/arm64/huawei-planck-ec.c' "${archive_list}" || \
  die "内核对应源码归档缺少已应用的 Planck EC 源码"
rm -f -- "${archive_list}"

if ((clean_intermediates)); then
  log "低磁盘模式：删除 kernel-build 与内核 worktree（保留补丁、来源锁和模块 staging）"
  safe_remove_dir "${WORK_DIR}/kernel-build"
  safe_remove_dir "${WORK_DIR}/sources/linux"
fi
bash "${SCRIPT_DIR}/prepare-rootfs.sh"
if ((clean_intermediates)); then
  log "低磁盘模式：squashfs/initramfs 完成，删除展开 rootfs 与模块 staging"
  safe_remove_dir "${WORK_DIR}/rootfs"
  safe_remove_dir "${WORK_DIR}/kernel-stage"
fi
bash "${SCRIPT_DIR}/build-media.sh"

install -m 0644 "${WORK_DIR}/iso-root/BUILD-INFO.txt" "${OUT_DIR}/BUILD-INFO.txt"
install -m 0644 "${WORK_DIR}/live/packages.txt" "${OUT_DIR}/packages.txt"
install -m 0644 "${WORK_DIR}/boot/kernel.config" "${OUT_DIR}/kernel.config"
install -m 0644 "${CONFIG_DIR}/versions.env" "${OUT_DIR}/SOURCE-LOCK.env"

(
  cd "${OUT_DIR}"
  checksum_tmp="${WORK_DIR}/SHA256SUMS.tmp"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | \
    xargs -r sha256sum --binary >"${checksum_tmp}"
  mv -f -- "${checksum_tmp}" SHA256SUMS
)
[[ -s ${OUT_DIR}/SHA256SUMS ]] || die "SHA256SUMS 未生成"
if ((clean_intermediates)); then
  log "低磁盘模式：发布元数据已复制，删除剩余工作目录"
  safe_remove_dir "${WORK_DIR}"
fi
log "全部完成；产物位于 ${OUT_DIR}"
