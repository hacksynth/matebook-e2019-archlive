#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0
build_workflow="${REPO_ROOT}/.github/workflows/build.yml"
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

[[ ${VOLUME_LABEL} =~ ^[A-Z0-9_]{1,11}$ ]] || \
  fail 'VOLUME_LABEL must be 1-11 characters for FAT32 compatibility'

mapfile -d '' scripts < <(find "${REPO_ROOT}/scripts" -type f -name '*.sh' -print0 | LC_ALL=C sort -z)
for script in "${scripts[@]}"; do
  bash -n "${script}" || fail "bash -n: ${script}"
  if ! grep -Fxq 'set -Eeuo pipefail' "${script}"; then
    fail "缺少 set -Eeuo pipefail：${script}"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --external-sources --severity=style "${scripts[@]}" || fail 'shellcheck'
elif [[ ${STRICT_TOOLS:-0} == 1 ]]; then
  fail 'STRICT_TOOLS=1 但 shellcheck 不在 PATH'
else
  printf 'WARN: 未找到 shellcheck；仅完成 bash -n。\n' >&2
fi

mapfile -d '' workflows < <(find "${REPO_ROOT}/.github/workflows" -type f \
  \( -name '*.yml' -o -name '*.yaml' \) -print0 | LC_ALL=C sort -z)
if command -v ruby >/dev/null 2>&1; then
  ruby -e "require 'yaml'; ARGV.each { |f| YAML.parse_file(f) }" "${workflows[@]}" || fail 'YAML 语法'
elif [[ ${STRICT_TOOLS:-0} == 1 ]]; then
  fail 'STRICT_TOOLS=1 但 ruby 不在 PATH，无法独立解析 YAML'
else
  printf 'WARN: 未找到 ruby；跳过独立 YAML 解析。\n' >&2
fi

if command -v actionlint >/dev/null 2>&1; then
  actionlint "${workflows[@]}" || fail 'actionlint'
elif [[ ${STRICT_TOOLS:-0} == 1 ]]; then
  fail 'STRICT_TOOLS=1 但 actionlint 不在 PATH'
else
  printf 'WARN: 未找到 actionlint；跳过 GitHub Actions 语义检查。\n' >&2
fi

[[ ${LINUX_COMMIT} =~ ^[0-9a-f]{40}$ ]] || fail 'LINUX_COMMIT 不是完整 SHA-1'
[[ ${ALARM_BUILD_KEY_FINGERPRINT} =~ ^[0-9A-F]{40}$ ]] || fail 'ALARM 构建密钥不是完整指纹'
[[ ${LINUX_REF} == v7.3.4 ]] || fail 'LINUX_REF 不是预期的稳定版 tag v7.3.4'
[[ ${LINUX_MIRROR} == *git.kernel.org* ]] || fail '缺少 kernel.org 回退镜像'
grep -Fq 'LINUX_MIRROR' "${REPO_ROOT}/scripts/fetch-sources.sh" || \
  fail 'fetch-sources 未实现内核镜像回退'
grep -Fq 'fetch --quiet --depth=1 origin' \
  "${REPO_ROOT}/scripts/fetch-sources.sh" || fail 'fetch-sources 未按 tag 抓取并校验内核'
grep -Fq '内核提交不匹配' "${REPO_ROOT}/scripts/fetch-sources.sh" || \
  fail 'fetch-sources 未校验锁定内核提交'

expected_files=(
  README.md LICENSE .gitignore
  configs/versions.env configs/device.env configs/kernel.fragment configs/dracut.conf
  configs/grub.cfg configs/grub-embedded.cfg configs/packages.aarch64
  configs/ath10k-wcn3990.service
  configs/pd-mapper-retry.conf
  scripts/fetch-sources.sh scripts/build-kernel.sh scripts/prepare-rootfs.sh
  scripts/install-qualcomm-wifi-services.sh
  scripts/build-media.sh scripts/build.sh scripts/validate.sh
  .github/workflows/build.yml .github/workflows/validate.yml
)
for relative in "${expected_files[@]}"; do
  [[ -f ${REPO_ROOT}/${relative} ]] || fail "缺少文件：${relative}"
done

grep -Fq 'permissions:' "${REPO_ROOT}/.github/workflows/build.yml" || fail 'build workflow 未声明权限'
grep -Fq 'contents: read' "${REPO_ROOT}/.github/workflows/build.yml" || fail 'build workflow 缺少只读默认权限'
grep -Fq 'contents: write' "${REPO_ROOT}/.github/workflows/build.yml" || fail 'build job 缺少发布 Release 的写权限'
if grep -Fq 'upload-artifact' "${REPO_ROOT}/.github/workflows/build.yml"; then
  fail '构建不应再用 upload-artifact 打包 zip；应逐产物上传 Release asset'
fi
grep -Fq 'gh release upload' "${REPO_ROOT}/.github/workflows/build.yml" || \
  fail '未逐文件上传 Release asset'
grep -Fq -- '--clobber' "${REPO_ROOT}/.github/workflows/build.yml" || \
  fail 'Release asset 上传未启用覆盖'
grep -Fq 'tag="latest"' "${REPO_ROOT}/.github/workflows/build.yml" || \
  fail 'main 构建未更新 latest 预发布'
grep -Fq 'devicetree /boot/dtb/qcom/sdm850-huawei-matebook-e-2019.dtb' \
  "${CONFIG_DIR}/grub.cfg" || fail 'GRUB 未加载 PAK-AL09 设备树'
grep -Fq 'rd.live.image' "${CONFIG_DIR}/grub.cfg" || fail 'GRUB 缺少 dracut live 参数'
grep -Fq 'rd.overlay' "${CONFIG_DIR}/grub.cfg" || fail 'GRUB 缺少 dracut 111 的 rd.overlay 参数'
if grep -Fq 'rd.live.overlay.overlayfs' "${CONFIG_DIR}/grub.cfg"; then
  fail 'GRUB 仍使用 dracut 111 已重命名的 overlay 参数'
fi
grep -Fq 'pd_ignore_unused' "${CONFIG_DIR}/grub.cfg" || fail 'GRUB 缺少 pd_ignore_unused'
grep -Fq 'clk_ignore_unused' "${CONFIG_DIR}/grub.cfg" || fail 'GRUB 缺少 clk_ignore_unused'
grep -Fq 'dmsquash-live' "${CONFIG_DIR}/dracut.conf" || fail 'dracut 未启用 dmsquash-live'
grep -Fq '70dmsquash-live' "${REPO_ROOT}/scripts/prepare-rootfs.sh" || \
  fail 'prepare-rootfs 未兼容 dracut-ng 的 70dmsquash-live 目录'
for setting in CONFIG_EXFAT_FS=y CONFIG_EXFAT_DEFAULT_IOCHARSET='"utf8"' CONFIG_NLS_UTF8=y; do
  grep -Fxq "${setting}" "${CONFIG_DIR}/kernel.fragment" || \
    fail "kernel fragment missing exFAT config: ${setting}"
done
for setting in 'CONFIG_EXFAT_FS=y' 'CONFIG_NLS_UTF8=y'; do
  grep -Fq "'${setting}'" "${REPO_ROOT}/scripts/build-kernel.sh" || \
    fail "build-kernel does not assert exFAT dependency: ${setting}"
done
grep -Fq 'exfat' "${CONFIG_DIR}/dracut.conf" || \
  fail 'dracut does not include exFAT support'
grep -Fxq 'exfatprogs' "${CONFIG_DIR}/packages.aarch64" || \
  fail 'Live rootfs does not include exfatprogs'
for setting in CONFIG_CFG80211=m CONFIG_MAC80211=m CONFIG_ATH10K=m CONFIG_ATH10K_SNOC=m; do
  grep -Fxq "${setting}" "${CONFIG_DIR}/kernel.fragment" || \
    fail "kernel fragment missing WCN3990 dependency: ${setting}"
  grep -Fq "'${setting}'" "${REPO_ROOT}/scripts/build-kernel.sh" || \
    fail "build-kernel does not assert WCN3990 dependency: ${setting}"
done
grep -Fxq 'ExecStart=/usr/bin/modprobe ath10k_snoc' \
  "${CONFIG_DIR}/ath10k-wcn3990.service" || \
  fail 'WCN3990 service does not load ath10k_snoc'
grep -Fq 'After=pd-mapper.service tqftpserv.service' \
  "${CONFIG_DIR}/ath10k-wcn3990.service" || \
  fail 'WCN3990 service does not wait for firmware services'
grep -Fq 'systemctl is-active --quiet pd-mapper.service' \
  "${CONFIG_DIR}/ath10k-wcn3990.service" || \
  fail 'WCN3990 service does not wait for active pd-mapper'
grep -Fq 'install-qualcomm-wifi-services.sh' \
  "${REPO_ROOT}/scripts/prepare-rootfs.sh" || \
  fail 'prepare-rootfs does not build the Qualcomm Wi-Fi services'
grep -Fq '/usr/bin/tqftpserv' \
  "${REPO_ROOT}/scripts/install-qualcomm-wifi-services.sh" || \
  fail 'Qualcomm Wi-Fi service build does not verify tqftpserv'
for jsn in adspr.jsn adspua.jsn cdspr.jsn modemuw.jsn slpir.jsn slpius.jsn; do
  [[ -s "${REPO_ROOT}/vendor-firmware/qcom/sdm850/HUAWEI/AL09/${jsn}" ]] || \
    fail "missing Qualcomm PD map: ${jsn}"
done
grep -Fq 'pd-mapper-retry.conf' "${REPO_ROOT}/scripts/prepare-rootfs.sh" || \
  fail 'prepare-rootfs does not install pd-mapper retry policy'
for setting in CONFIG_RD_ZSTD=y CONFIG_MODULE_COMPRESS_ZSTD=y; do
  grep -Fxq "${setting}" "${CONFIG_DIR}/kernel.fragment" || \
    fail "内核 fragment 缺少 initramfs/模块压缩配置：${setting}"
  grep -Fq "'${setting}'" "${REPO_ROOT}/scripts/build-kernel.sh" || \
    fail "build-kernel 未断言：${setting}"
done
grep -Fq 'INSTALL_MOD_STRIP=1' "${REPO_ROOT}/scripts/build-kernel.sh" || \
  fail 'modules_install 未剥离调试符号'
grep -Fq 'linux-firmware-qcom' "${CONFIG_DIR}/packages.aarch64" || \
  fail 'Live rootfs 缺少 linux-firmware-qcom'
if grep -Fq 'EC_HUAWEI_PLANCK' "${CONFIG_DIR}/kernel.fragment"; then
  fail 'stable 7.3.4 profile 不应再断言已移除的 6.16 Planck EC 驱动'
fi
if grep -En 'zstd[^|]*--output' "${REPO_ROOT}/scripts/build.sh" \
    "${REPO_ROOT}/scripts/build-media.sh" >/dev/null 2>&1; then
  fail 'zstd 不支持 --output 长选项，必须使用 -o'
fi
grep -Fq 'zstd --threads=0 -10 -o' "${REPO_ROOT}/scripts/build.sh" || \
  fail 'GPL 源码归档的 zstd 输出参数不正确'
grep -Fq 'zstd --force --threads=0 -19 --long=27 -o' "${REPO_ROOT}/scripts/build-media.sh" || \
  fail 'raw 镜像压缩的 zstd 输出参数不正确'
grep -Fq 'kernel-cache' "${REPO_ROOT}/scripts/build-kernel.sh" || \
  fail 'build-kernel 未实现内核构建缓存'
grep -Fq "\"\${CONFIG_DIR}/device.env\"" "${REPO_ROOT}/scripts/build-kernel.sh" || \
  fail '内核缓存键未包含设备配置'
grep -Fq "configs/device.env" "${build_workflow}" || \
  fail 'build workflow 内核缓存键未包含设备配置'
grep -Fq 'actions/cache/restore@5a3ec84eff668545956fd18022155c47e93e2684' "${build_workflow}" || \
  fail 'build workflow 未固定 actions/cache/restore SHA'
grep -Fq 'actions/cache/save@5a3ec84eff668545956fd18022155c47e93e2684' "${build_workflow}" || \
  fail 'build workflow 未固定 actions/cache/save SHA'
grep -Fq 'STAGE: kernel' "${build_workflow}" || fail 'workflow 未拆分内核阶段'
grep -Fq 'STAGE: media' "${build_workflow}" || fail 'workflow 未拆分介质阶段'
grep -Fq 'STAGE:-all' "${REPO_ROOT}/scripts/build.sh" || \
  fail 'build.sh 未支持 STAGE 分阶段构建'
grep -Fq 'DisableSandbox' "${REPO_ROOT}/scripts/prepare-rootfs.sh" || \
  fail 'chroot 未关闭 pacman 7 下载沙箱（Landlock 在 qemu-user 下不可用）'
grep -Fq '#CheckSpace' "${REPO_ROOT}/scripts/prepare-rootfs.sh" || \
  fail 'chroot 未规避 pacman CheckSpace 误报'
grep -Fq 'linux-firmware-amdgpu' "${REPO_ROOT}/scripts/prepare-rootfs.sh" || \
  fail 'chroot 未移除无关平台固件拆分包'
grep -Fxq 'grub' "${CONFIG_DIR}/packages.aarch64" || fail 'ALARM rootfs 未安装原生 grub'
grep -Fq 'grub-mkstandalone --format=arm64-efi' \
  "${REPO_ROOT}/scripts/prepare-rootfs.sh" || fail '未在 ALARM chroot 生成 AA64 GRUB'
grep -Fq 'configfile fdt"' "${REPO_ROOT}/scripts/prepare-rootfs.sh" || \
  fail 'AA64 GRUB standalone 未显式包含提供 devicetree 命令的 fdt.mod'
if grep -Fq 'configfile devicetree"' "${REPO_ROOT}/scripts/prepare-rootfs.sh"; then
  fail 'ALARM grub/arm64-efi 没有 devicetree.mod；应使用 fdt.mod'
fi
grep -Fq "validate_aa64_efi \"\${BOOT_DIR}/BOOTAA64.EFI\"" \
  "${REPO_ROOT}/scripts/build-media.sh" || fail 'build-media 未校验 BOOTAA64.EFI 架构'
grep -Fq 'bsdtar -xpf' "${REPO_ROOT}/scripts/prepare-rootfs.sh" || fail 'rootfs 未使用 bsdtar -xpf'
build_workflow="${REPO_ROOT}/.github/workflows/build.yml"
grep -Fq 'libarchive-tools' "${build_workflow}" || fail 'build workflow 未安装 bsdtar/libarchive-tools'
grep -Fq 'CLEAN_INTERMEDIATES' "${build_workflow}" || fail 'build workflow 未启用低磁盘清理'
if grep -Fq 'grub-efi-arm64-bin' "${build_workflow}"; then
  fail 'x86 runner 不可安装 arm64 ports 的 grub-efi-arm64-bin'
fi
grep -Fq 'LINUX_SOURCE_ARCHIVE=' "${CONFIG_DIR}/versions.env" || fail '缺少 GPL 对应源码资产名'
grep -Fq 'bsdtar -cf -' "${REPO_ROOT}/scripts/build.sh" || fail '未生成完整已补丁内核源码归档'
grep -Fq "linux/arch/arm64/boot/dts/\${device_dts}" \
  "${REPO_ROOT}/scripts/build.sh" || fail '源码归档未检查目标设备树'
if grep -Fq 'huawei-planck-ec.c' "${REPO_ROOT}/scripts/build.sh"; then
  fail 'stable 7.3.4 构建不应再检查已移除的 Planck EC 源码'
fi
grep -Fq 'DEVICE_MODEL="PAK-AL09"' "${CONFIG_DIR}/device.env" || \
  fail '设备配置不是当前 PAK-AL09 基线'
grep -Fq 'DEVICE_DTB="qcom/sdm850-huawei-matebook-e-2019.dtb"' \
  "${CONFIG_DIR}/device.env" || fail '设备配置未指向 PAK-AL09 上游设备树'
grep -Fq 'DEVICE-PROFILE.env' "${REPO_ROOT}/scripts/build.sh" || \
  fail '构建产物未包含设备配置'
grep -Fq "export VENDOR_FIRMWARE_DIR=\"\${REPO_ROOT}/vendor-firmware\"" \
  "${REPO_ROOT}/scripts/build.sh" || fail '构建未自动使用私有仓库固件目录'
for firmware_file in qcadsp850.mbn qccdsp850.mbn qcdsp1v2850.mbn qcdsp2850.mbn \
  qcslpi850.mbn qcdxkmsuc850.mbn ipa_fws.elf qcvss850.mbn; do
  [[ -s ${REPO_ROOT}/vendor-firmware/qcom/sdm850/HUAWEI/AL09/${firmware_file} ]] || \
    fail "缺少 PAK-AL09 专有固件：${firmware_file}"
done
grep -Fq 'qcom,calibration-variant = "Huawei_Planck";' \
  "${REPO_ROOT}/scripts/build-kernel.sh" || fail '构建前未校验 PAK-AL09 Wi-Fi 校准名'
grep -Fq 'compatible = "innolux,p120zdg-bf1";' \
  "${REPO_ROOT}/scripts/build-kernel.sh" || fail '构建前未校验 PAK-AL09 面板兼容字符串'
for setting in CONFIG_USB_DWC3=y CONFIG_USB_DWC3_QCOM=y CONFIG_PHY_QCOM_QMP=y \
  CONFIG_PHY_QCOM_QMP_USB=y CONFIG_PHY_QCOM_QUSB2=y CONFIG_USB_STORAGE=y CONFIG_USB_UAS=y; do
  grep -Fxq "${setting}" "${CONFIG_DIR}/kernel.fragment" || fail "USB-C 启动配置缺失：${setting}"
  grep -Fq "'${setting}'" "${REPO_ROOT}/scripts/build-kernel.sh" || \
    fail "build-kernel 未断言 USB-C 启动配置：${setting}"
done

if [[ ${STRICT_TOOLS:-0} == 1 ]] && ! command -v file >/dev/null 2>&1; then
  fail 'STRICT_TOOLS=1 但 file 不在 PATH，无法校验 PE/COFF 架构'
fi
efi_to_check="${AA64_EFI_PATH:-${WORK_DIR}/boot/BOOTAA64.EFI}"
if [[ -n ${AA64_EFI_PATH:-} || -f ${efi_to_check} ]]; then
  validate_aa64_efi "${efi_to_check}"
fi

large_file="$(find "${REPO_ROOT}" \
  \( -path "${REPO_ROOT}/.git" -o -path "${REPO_ROOT}/.work" \
    -o -path "${REPO_ROOT}/.cache" -o -path "${REPO_ROOT}/out" \
    -o -path "${REPO_ROOT}/vendor-firmware" \) -prune -o \
  -type f -size +1M -print -quit)"
[[ -z ${large_file} ]] || fail "仓库含大文件：${large_file}"
artifact_file="$(find "${REPO_ROOT}" \
  \( -path "${REPO_ROOT}/.git" -o -path "${REPO_ROOT}/.work" \
    -o -path "${REPO_ROOT}/.cache" -o -path "${REPO_ROOT}/out" \) -prune -o \
  -type f \( -name '*.iso' -o -name '*.img' -o -name '*.img.zst' -o -name '*.dtb' -o -name '*.efi' \) \
  -print -quit)"
[[ -z ${artifact_file} ]] || fail "仓库误提交构建产物：${artifact_file}"

if ((failures > 0)); then
  printf '静态验证失败：%d 项。\n' "${failures}" >&2
  exit 1
fi
printf '静态验证通过：%d 个 shell 脚本，%d 个 workflow。\n' \
  "${#scripts[@]}" "${#workflows[@]}"
