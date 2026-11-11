#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_tools curl git gpg md5sum patch sha256sum
ensure_dirs

SOURCE_DIR="${WORK_DIR}/sources"
PATCH_DIR="${SOURCE_DIR}/patches"
KERNEL_DIR="${SOURCE_DIR}/linux"
ROOTFS_TARBALL="${CACHE_DIR}/ArchLinuxARM-aarch64-${ALARM_ROOTFS_MD5}.tar.gz"
ROOTFS_SIGNATURE="${ROOTFS_TARBALL}.sig"

safe_recreate_dir "${SOURCE_DIR}"
install -d -m 0755 "${PATCH_DIR}"

log "获取固定内核提交 ${LINUX_COMMIT}（上游 ${LINUX_REF}）"
git init --quiet "${KERNEL_DIR}"
git -C "${KERNEL_DIR}" remote add origin "${LINUX_REPO}"
git -C "${KERNEL_DIR}" fetch --quiet --depth=1 origin "${LINUX_COMMIT}"
git -C "${KERNEL_DIR}" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
actual_commit="$(git -C "${KERNEL_DIR}" rev-parse HEAD)"
[[ ${actual_commit} == "${LINUX_COMMIT}" ]] || die "内核提交不匹配：${actual_commit}"
git -C "${KERNEL_DIR}" fsck --no-dangling --no-progress >/dev/null

fetch_patch() {
  local relative expected destination
  relative="$1"
  expected="$2"
  destination="${PATCH_DIR}/$(basename -- "${relative}")"
  fetch_file "${NEW_WHEAT_RAW_BASE}/${NEW_WHEAT_COMMIT}/${relative}" "${destination}"
  verify_sha256 "${expected}" "${destination}"
}

fetch_patch "${UCSI_PATCH_PATH}" "${UCSI_PATCH_SHA256}"
fetch_patch "${EC_PATCH_PATH}" "${EC_PATCH_SHA256}"
fetch_patch "${QSEECOM_PATCH_PATH}" "${QSEECOM_PATCH_SHA256}"
fetch_patch "${DEVICETREE_PATCH_PATH}" "${DEVICETREE_PATCH_SHA256}"

# 顺序有依赖：UCSI API 先于 Planck EC/UCSI 驱动；设备树和 QSEECom 随后。
apply_patch_once "${KERNEL_DIR}" "${PATCH_DIR}/$(basename -- "${UCSI_PATCH_PATH}")"
apply_patch_once "${KERNEL_DIR}" "${PATCH_DIR}/$(basename -- "${EC_PATCH_PATH}")"
apply_patch_once "${KERNEL_DIR}" "${PATCH_DIR}/$(basename -- "${DEVICETREE_PATCH_PATH}")"
apply_patch_once "${KERNEL_DIR}" "${PATCH_DIR}/$(basename -- "${QSEECOM_PATCH_PATH}")"

# 兼容层：New-Wheat 的 Planck UCSI 驱动用 UCSI_SET_CCI_LENGTH() 构造合成 CCI，
# 而固定的 6.16 树只有读取用的 UCSI_CCI_LENGTH()。这里幂等地补上等价的写入宏；
# 若基线将来已提供该宏则不改动。语义与 UCSI CCI length 字段（bit 15:8）一致。
apply_ucsi_cci_length_shim() {
  local header="${KERNEL_DIR}/drivers/usb/typec/ucsi/ucsi.h" tmp
  [[ -f ${header} ]] || die "未找到 UCSI 头文件：${header}"
  if grep -q 'define UCSI_SET_CCI_LENGTH' "${header}"; then
    log "UCSI 基线已提供 UCSI_SET_CCI_LENGTH，跳过兼容层"
    return 0
  fi
  tmp="${header}.shim"
  awk '
    !done && /^#define UCSI_CCI_LENGTH\(/ {
      print "/* PAK-AL09 live 构建兼容层：6.16 CCI 只有读取宏。 */";
      print "#ifndef UCSI_SET_CCI_LENGTH";
      print "#define UCSI_SET_CCI_LENGTH(_len_) (((_len_) << 8) & GENMASK(15, 8))";
      print "#endif";
      done = 1;
    }
    { print }
  ' "${header}" >"${tmp}"
  mv -f -- "${tmp}" "${header}"
  grep -q 'define UCSI_SET_CCI_LENGTH' "${header}" || \
    die "UCSI_SET_CCI_LENGTH 兼容层写入失败"
  log "已为 6.16 基线补充 UCSI_SET_CCI_LENGTH 兼容宏"
}
apply_ucsi_cci_length_shim

fetch_file "${ALARM_ROOTFS_URL}" "${ROOTFS_TARBALL}"
actual_md5="$(md5sum --binary "${ROOTFS_TARBALL}" | awk '{print $1}')"
[[ ${actual_md5} == "${ALARM_ROOTFS_MD5}" ]] || \
  die "ALARM rootfs MD5 不匹配（锁定版本可能已从 latest URL 下线）"
fetch_file "${ALARM_ROOTFS_SIG_URL}" "${ROOTFS_SIGNATURE}"

GNUPGHOME="${CACHE_DIR}/gnupg-alarm"
export GNUPGHOME
install -d -m 0700 "${GNUPGHOME}"
fetch_alarm_key() {
  local attempt armor="${CACHE_DIR}/archlinuxarm-build-key.asc"
  if gpg --batch --list-keys "${ALARM_BUILD_KEY_FINGERPRINT}" >/dev/null 2>&1; then
    return 0
  fi
  for attempt in 1 2 3; do
    log "从 ${ALARM_KEYSERVER} 获取 ALARM 构建系统公钥（第 ${attempt} 次）"
    if gpg --batch --keyserver "${ALARM_KEYSERVER}" \
        --keyserver-options timeout=30 --recv-keys "${ALARM_BUILD_KEY_FINGERPRINT}" \
        >/dev/null 2>&1; then
      return 0
    fi
    # HKP 客户端/DNS 异常时回退到 keyserver 的 HTTPS 接口；导入后仍强制核对完整指纹。
    log "HKP 获取失败，改用 HTTPS keyserver 接口"
    if curl --fail --silent --location --retry 2 --output "${armor}" \
        "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${ALARM_BUILD_KEY_FINGERPRINT}" \
        && gpg --batch --import "${armor}" >/dev/null 2>&1 \
        && gpg --batch --list-keys "${ALARM_BUILD_KEY_FINGERPRINT}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "无法获取或导入 ALARM 构建系统公钥"
}
fetch_alarm_key
fingerprints="$(gpg --batch --with-colons --fingerprint "${ALARM_BUILD_KEY_FINGERPRINT}" | awk -F: '$1 == "fpr" {print $10}')"
grep -Fxq "${ALARM_BUILD_KEY_FINGERPRINT}" <<<"${fingerprints}" || die "ALARM 公钥指纹不匹配"

status_file="${SOURCE_DIR}/rootfs-gpg.status"
if ! gpg --batch --status-fd 1 --verify "${ROOTFS_SIGNATURE}" "${ROOTFS_TARBALL}" \
    >"${status_file}" 2>"${SOURCE_DIR}/rootfs-gpg.log"; then
  die "ALARM rootfs OpenPGP 签名验证失败"
fi
awk -v fp="${ALARM_BUILD_KEY_FINGERPRINT}" '
  $2 == "VALIDSIG" {
    for (i = 3; i <= NF; i++) if ($i == fp) found = 1
  }
  END { exit(found ? 0 : 1) }
' "${status_file}" || die "rootfs 签名不是由锁定的 ALARM 构建系统密钥生成"

printf '%s\n' "${ROOTFS_TARBALL}" >"${SOURCE_DIR}/rootfs.path"
printf '%s\n' "${actual_commit}" >"${SOURCE_DIR}/kernel.commit"
log "固定来源已全部获取并验证"
