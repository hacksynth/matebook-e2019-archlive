#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_tools bsdtar chroot find mksquashfs mount mountpoint qemu-aarch64-static rsync umount
ensure_dirs

ROOTFS_DIR="${WORK_DIR}/rootfs"
LIVE_DIR="${WORK_DIR}/live"
BOOT_DIR="${WORK_DIR}/boot"
STAGE_DIR="${WORK_DIR}/kernel-stage"
ROOTFS_TARBALL="$(<"${WORK_DIR}/sources/rootfs.path")"
KERNEL_RELEASE="$(<"${WORK_DIR}/kernel-release")"
[[ -s ${ROOTFS_TARBALL} ]] || die "rootfs tarball 不存在"
[[ -d ${STAGE_DIR}/lib/modules/${KERNEL_RELEASE} ]] || die "内核模块 staging 不存在"

safe_recreate_dir "${ROOTFS_DIR}"
safe_recreate_dir "${LIVE_DIR}"

mounted_paths=()
cleanup_mounts() {
  local index path
  set +e
  for ((index=${#mounted_paths[@]}-1; index>=0; index--)); do
    path="${mounted_paths[index]}"
    for _ in 1 2 3; do
      mountpoint -q "${path}" || break
      umount --recursive "${path}" 2>/dev/null || sleep 2
    done
    if mountpoint -q "${path}"; then
      # 兜底：延迟卸载，避免残留的 qemu/chroot 引用导致随后 squashfs 打包宿主 /dev。
      umount --lazy "${path}" 2>/dev/null || true
    fi
  done
}
trap cleanup_mounts EXIT INT TERM

log "解包已验证的 Generic AArch64 rootfs"
bsdtar -xpf "${ROOTFS_TARBALL}" -C "${ROOTFS_DIR}"

install -d -m 0755 "${ROOTFS_DIR}/usr/lib/modules"
rsync -aH "${STAGE_DIR}/lib/modules/" "${ROOTFS_DIR}/usr/lib/modules/"
install -D -m 0644 "${CONFIG_DIR}/dracut.conf" \
  "${ROOTFS_DIR}/etc/dracut.conf.d/99-matebook-live.conf"
install -D -m 0644 "${CONFIG_DIR}/ath10k-wcn3990.service" \
  "${ROOTFS_DIR}/usr/lib/systemd/system/ath10k-wcn3990.service"
install -D -m 0755 "${SCRIPT_DIR}/install-qualcomm-wifi-services.sh" \
  "${ROOTFS_DIR}/root/install-qualcomm-wifi-services.sh"
install -m 0755 "$(command -v qemu-aarch64-static)" \
  "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"
rm -f -- "${ROOTFS_DIR}/etc/resolv.conf"
install -m 0644 /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
printf '%s\n' "${KERNEL_RELEASE}" >"${ROOTFS_DIR}/root/kernel-release"
install -m 0644 "${CONFIG_DIR}/grub-embedded.cfg" \
  "${ROOTFS_DIR}/root/grub-embedded.cfg"

mapfile -t packages < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
  "${CONFIG_DIR}/packages.aarch64")
printf '%s\n' "${packages[@]}" >"${ROOTFS_DIR}/root/live-packages"

cat >"${ROOTFS_DIR}/root/configure-live.sh" <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

kernel_release="$(</root/kernel-release)"
mapfile -t packages </root/live-packages

# pacman 7 的下载沙箱依赖 Landlock（qemu-user chroot 不支持），且会切换到 alpm 用户。
# 关闭沙箱和下载用户切换；包签名校验（SigLevel）仍然启用，不受影响。
if ! grep -Eq '^[[:space:]]*DisableSandbox([[:space:]]|$)' /etc/pacman.conf; then
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi
sed -i -E 's/^[[:space:]]*(DownloadUser[[:space:]]*=)/#\1/' /etc/pacman.conf
# 精简 rootfs 的 /var/cache 可能是空目录；pacman 7 的 CheckSpace 会误报“磁盘不足”。
install -d -m 0755 /var/cache/pacman/pkg
sed -i -E 's/^[[:space:]]*CheckSpace/#CheckSpace/' /etc/pacman.conf

pacman-key --init
pacman-key --populate archlinuxarm
# 先升级 keyring，避免旧 rootfs 里的 keyring 无法验证 2026 年新包（签名仍由 ALARM 构建密钥校验）。
pacman -Sy --noconfirm --needed archlinuxarm-keyring
pacman-key --populate archlinuxarm
# Generic rootfs 的发行版内核不会用于此介质；先删除以免升级/保留第二套 Image 与 modules。
# 自编 kernel_release 使用不同目录名，不属于 linux-aarch64 包，不会被此操作删除。
if pacman -Q linux-aarch64 >/dev/null 2>&1; then
  pacman -Rdd --noconfirm linux-aarch64
fi
# 只保留 Qualcomm/Atheros 固件：移除全量元包与无关平台的拆分包，控制镜像体积。
for firmware_pkg in linux-firmware linux-firmware-amd linux-firmware-amdgpu \
  linux-firmware-broadcom linux-firmware-intel linux-firmware-mediatek \
  linux-firmware-nvidia linux-firmware-radeon linux-firmware-realtek \
  linux-firmware-ti; do
  if pacman -Q "${firmware_pkg}" >/dev/null 2>&1; then
    pacman -Rdd --noconfirm "${firmware_pkg}" >/dev/null
  fi
done
pacman --noconfirm -Syu --needed "${packages[@]}"

printf 'matebook-live\n' >/etc/hostname
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' >/etc/locale.conf

if ! id -u live >/dev/null 2>&1; then
  useradd --create-home --groups wheel --shell /bin/bash live
fi
printf 'live:live\n' | chpasswd
passwd --lock root
install -d -m 0750 /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/10-live
chmod 0440 /etc/sudoers.d/10-live

systemctl enable NetworkManager.service
systemctl disable sshd.service >/dev/null 2>&1 || true
systemctl set-default multi-user.target

# 在原生 AArch64 用户空间内生成 AA64 EFI，避免宿主架构 GRUB 工具混入。
command -v grub-mkstandalone >/dev/null 2>&1
grub-mkstandalone --format=arm64-efi --output=/boot/BOOTAA64.EFI \
  --locales="" --fonts="" \
  --modules="part_gpt part_msdos fat ext2 iso9660 normal linux search search_label configfile fdt" \
  "boot/grub/grub.cfg=/root/grub-embedded.cfg"

cat >/etc/motd <<'MOTD'
PAK-AL09 Arch Linux ARM Live（实验性）
用户/密码：live/live；sudo 无密码。默认不会安装系统或写入内部 UFS。
专有固件未随项目提供；请先阅读介质根目录的 README/BUILD-INFO。
MOTD

depmod -a "${kernel_release}"
modinfo -k "${kernel_release}" ath10k_snoc | grep -Fq 'qcom,wcn3990-wifi'
modprobe -S "${kernel_release}" --dry-run ath10k_snoc
/root/install-qualcomm-wifi-services.sh
# dracut-ng >= 103 把模块目录从 90dmsquash-live 改名为 70dmsquash-live。
dmsquash_found=0
for dmsquash_dir in /usr/lib/dracut/modules.d/70dmsquash-live \
  /usr/lib/dracut/modules.d/90dmsquash-live; do
  if [[ -d ${dmsquash_dir} ]]; then
    dmsquash_found=1
    echo "dracut dmsquash-live 模块：${dmsquash_dir}" >&2
  fi
done
if ((!dmsquash_found)); then
  echo 'dracut 缺少 dmsquash-live 模块（70dmsquash-live/90dmsquash-live）' >&2
  exit 1
fi
dracut --force --no-hostonly --kver "${kernel_release}" \
  "/boot/initramfs-${kernel_release}-live.img"
pacman -Q | LC_ALL=C sort >/root/packages.txt

rm -f /etc/machine-id
install -m 0644 /dev/null /etc/machine-id
rm -f /var/lib/dbus/machine-id
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/* /var/log/pacman.log /tmp/* /var/tmp/*
CHROOT_SCRIPT
chmod 0755 "${ROOTFS_DIR}/root/configure-live.sh"

if [[ -n ${VENDOR_FIRMWARE_DIR:-} ]]; then
  firmware_source="$(cd -- "${VENDOR_FIRMWARE_DIR}" && pwd -P)"
  [[ -d ${firmware_source} ]] || die "VENDOR_FIRMWARE_DIR 不是目录"
  log "注入用户自行提供的固件（项目不下载、不授权也不再分发这些文件）"
  install -d -m 0755 "${ROOTFS_DIR}/usr/lib/firmware"
  rsync -aH --safe-links "${firmware_source}/" "${ROOTFS_DIR}/usr/lib/firmware/"
  install -d -m 0755 "${ROOTFS_DIR}/usr/share/matebook-live"
  (
    cd "${firmware_source}"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) >"${ROOTFS_DIR}/usr/share/matebook-live/vendor-firmware.sha256"
  printf '%s\n' injected >"${LIVE_DIR}/firmware-mode"
else
  log "未设置 VENDOR_FIRMWARE_DIR：生成不含 PAK-AL09 专有固件的介质"
  printf '%s\n' none >"${LIVE_DIR}/firmware-mode"
fi

if command -v update-binfmts >/dev/null 2>&1; then
  update-binfmts --enable qemu-aarch64 >/dev/null 2>&1 || true
fi

for spec in "/dev:${ROOTFS_DIR}/dev" "/proc:${ROOTFS_DIR}/proc" "/sys:${ROOTFS_DIR}/sys"; do
  source_path="${spec%%:*}"
  target_path="${spec#*:}"
  install -d -m 0755 "${target_path}"
  mount --rbind "${source_path}" "${target_path}"
  mount --make-rslave "${target_path}"
  mounted_paths+=("${target_path}")
done

log "在 qemu-aarch64 chroot 中安装软件并生成 dracut live initramfs"
chroot "${ROOTFS_DIR}" /usr/bin/qemu-aarch64-static /bin/bash /root/configure-live.sh
cleanup_mounts
mounted_paths=()
for pseudo_path in "${ROOTFS_DIR}/dev" "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys"; do
  if mountpoint -q "${pseudo_path}"; then
    die "chroot 后仍挂载 ${pseudo_path}；拒绝把宿主文件系统打包进 squashfs"
  fi
done

install -m 0644 "${ROOTFS_DIR}/boot/initramfs-${KERNEL_RELEASE}-live.img" \
  "${BOOT_DIR}/initramfs-live.img"
install -m 0644 "${ROOTFS_DIR}/boot/BOOTAA64.EFI" "${BOOT_DIR}/BOOTAA64.EFI"
install -m 0644 "${ROOTFS_DIR}/root/packages.txt" "${LIVE_DIR}/packages.txt"

rm -f -- "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static" \
  "${ROOTFS_DIR}/root/configure-live.sh" "${ROOTFS_DIR}/root/live-packages" \
  "${ROOTFS_DIR}/root/kernel-release" "${ROOTFS_DIR}/root/grub-embedded.cfg" \
  "${ROOTFS_DIR}/root/packages.txt"
rm -rf -- "${ROOTFS_DIR:?}/boot/"*

log "生成 squashfs live 根文件系统"
mksquashfs "${ROOTFS_DIR}" "${LIVE_DIR}/airootfs.sfs" -noappend -comp zstd \
  -Xcompression-level 19
[[ -s ${LIVE_DIR}/airootfs.sfs ]] || die "squashfs 未生成"
log "Live rootfs 准备完成"
