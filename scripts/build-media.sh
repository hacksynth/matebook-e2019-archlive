#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_tools file losetup mkfs.ext4 mkfs.vfat mcopy mformat mmd mount mountpoint \
  rsync sgdisk truncate udevadm umount xorriso zstd
ensure_dirs

BOOT_DIR="${WORK_DIR}/boot"
LIVE_DIR="${WORK_DIR}/live"
ISO_ROOT="${WORK_DIR}/iso-root"
EFI_IMAGE="${ISO_ROOT}/EFI/efiboot.img"
RAW_IMAGE="${WORK_DIR}/${IMAGE_BASENAME}.img"
ISO_OUTPUT="${OUT_DIR}/${IMAGE_BASENAME}.iso"
IMG_OUTPUT="${OUT_DIR}/${IMAGE_BASENAME}.img.zst"
KERNEL_RELEASE="$(<"${WORK_DIR}/kernel-release")"

[[ -s ${BOOT_DIR}/Image ]] || die "缺少内核 Image"
[[ -s ${BOOT_DIR}/initramfs-live.img ]] || die "缺少 live initramfs"
[[ -s ${BOOT_DIR}/dtb/${DEVICE_DTB} ]] || die "缺少 PAK-AL09 DTB"
[[ -s ${LIVE_DIR}/airootfs.sfs ]] || die "缺少 squashfs"
[[ -s ${LIVE_DIR}/firmware-mode ]] || die "缺少固件构建模式记录"
validate_aa64_efi "${BOOT_DIR}/BOOTAA64.EFI"

safe_recreate_dir "${ISO_ROOT}"
install -d -m 0755 "${ISO_ROOT}/boot/grub" "${ISO_ROOT}/boot/dtb/qcom" \
  "${ISO_ROOT}/arch" "${ISO_ROOT}/EFI/BOOT"
install -m 0644 "${BOOT_DIR}/Image" "${ISO_ROOT}/boot/Image"
install -m 0644 "${BOOT_DIR}/initramfs-live.img" "${ISO_ROOT}/boot/initramfs-live.img"
install -m 0644 "${BOOT_DIR}/dtb/${DEVICE_DTB}" "${ISO_ROOT}/boot/dtb/${DEVICE_DTB}"
install -m 0644 "${CONFIG_DIR}/grub.cfg" "${ISO_ROOT}/boot/grub/grub.cfg"
install -m 0644 "${LIVE_DIR}/airootfs.sfs" "${ISO_ROOT}/arch/airootfs.sfs"
install -m 0644 "${LIVE_DIR}/packages.txt" "${ISO_ROOT}/packages.txt"
install -m 0644 "${BOOT_DIR}/BOOTAA64.EFI" "${ISO_ROOT}/EFI/BOOT/BOOTAA64.EFI"
install -m 0644 "${REPO_ROOT}/README.md" "${ISO_ROOT}/README.md"

firmware_mode="未注入 PAK-AL09 专有固件"
if [[ $(<"${LIVE_DIR}/firmware-mode") == injected ]]; then
  firmware_mode="已从构建者指定的 VENDOR_FIRMWARE_DIR 注入；见 squashfs 内 vendor-firmware.sha256"
fi
cat >"${ISO_ROOT}/BUILD-INFO.txt" <<BUILD_INFO
介质：HUAWEI MateBook E 2019 PAK-AL09 Arch Linux ARM Live
内核：${KERNEL_RELEASE}
内核仓库：${LINUX_REPO}
内核 ref：${LINUX_REF}
内核提交：${LINUX_COMMIT}
设备树：上游 arch/arm64/boot/dts/qcom/${DEVICE_DTB}
GPL 完整对应源码资产：${LINUX_SOURCE_ARCHIVE}
ALARM rootfs URL：${ALARM_ROOTFS_URL}
ALARM rootfs MD5：${ALARM_ROOTFS_MD5}
ALARM rootfs 签名密钥：${ALARM_BUILD_KEY_FINGERPRINT}
固件：${firmware_mode}
安全启动：未签名，不支持 Secure Boot
BUILD_INFO

# 再校验复制后的文件，防止介质 staging 中被错误架构文件替换。
validate_aa64_efi "${ISO_ROOT}/EFI/BOOT/BOOTAA64.EFI"
truncate -s 64M "${EFI_IMAGE}"
mformat -i "${EFI_IMAGE}" -F -v PAKESP ::
mmd -i "${EFI_IMAGE}" ::/EFI ::/EFI/BOOT
mcopy -i "${EFI_IMAGE}" "${ISO_ROOT}/EFI/BOOT/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI

log "生成 UEFI El Torito ISO"
rm -f -- "${ISO_OUTPUT}"
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "${VOLUME_LABEL}" \
  -eltorito-alt-boot -e EFI/efiboot.img -no-emul-boot -isohybrid-gpt-basdat \
  -output "${ISO_OUTPUT}" "${ISO_ROOT}"
xorriso -indev "${ISO_OUTPUT}" -report_el_torito plain \
  >"${OUT_DIR}/${IMAGE_BASENAME}.iso.el-torito.txt" 2>&1

loop_device=""
mounts=()
cleanup_media() {
  local index path
  set +e
  for ((index=${#mounts[@]}-1; index>=0; index--)); do
    path="${mounts[index]}"
    if mountpoint -q "${path}"; then
      umount "${path}"
    fi
  done
  if [[ -n ${loop_device} ]]; then
    losetup --detach "${loop_device}" 2>/dev/null || true
  fi
}
trap cleanup_media EXIT INT TERM

payload_mib="$(du -sm --apparent-size "${ISO_ROOT}" | awk '{print $1}')"
raw_mib=$((payload_mib + 768))
assert_repo_path "${RAW_IMAGE}"
rm -f -- "${RAW_IMAGE}"
truncate -s "${raw_mib}M" "${RAW_IMAGE}"
sgdisk --clear \
  --new=1:1MiB:+128MiB --typecode=1:EF00 --change-name=1:EFI \
  --new=2:0:0 --typecode=2:8300 --change-name=2:PAKAL09_LIVE \
  "${RAW_IMAGE}"
loop_device="$(losetup --find --show --partscan "${RAW_IMAGE}")"
udevadm settle
[[ -b ${loop_device}p1 && -b ${loop_device}p2 ]] || die "raw 镜像分区节点未出现"
mkfs.vfat -F 32 -n PAKESP "${loop_device}p1"
mkfs.ext4 -F -L "${VOLUME_LABEL}" -m 0 "${loop_device}p2"

ESP_MOUNT="${WORK_DIR}/mnt-esp"
LIVE_MOUNT="${WORK_DIR}/mnt-live"
install -d -m 0755 "${ESP_MOUNT}" "${LIVE_MOUNT}"
mount "${loop_device}p1" "${ESP_MOUNT}"
mounts+=("${ESP_MOUNT}")
mount "${loop_device}p2" "${LIVE_MOUNT}"
mounts+=("${LIVE_MOUNT}")
install -D -m 0644 "${ISO_ROOT}/EFI/BOOT/BOOTAA64.EFI" \
  "${ESP_MOUNT}/EFI/BOOT/BOOTAA64.EFI"
rsync -aH --exclude='/EFI/efiboot.img' "${ISO_ROOT}/" "${LIVE_MOUNT}/"
sync
cleanup_media
mounts=()
loop_device=""
sgdisk --verify "${RAW_IMAGE}"

log "压缩推荐的 GPT raw 镜像"
rm -f -- "${IMG_OUTPUT}"
zstd --force --threads=0 -19 --long=27 -o "${IMG_OUTPUT}" "${RAW_IMAGE}"

[[ -s ${ISO_OUTPUT} && -s ${IMG_OUTPUT} ]] || die "介质产物不完整"
log "ISO 与 raw .img.zst 已生成"
