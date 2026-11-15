#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

SCRIPT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_LIB_DIR}/../.." && pwd -P)"
CONFIG_DIR="${REPO_ROOT}/configs"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/.work}"
CACHE_DIR="${CACHE_DIR:-${REPO_ROOT}/.cache}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/out}"

# shellcheck source=../../configs/versions.env
source "${CONFIG_DIR}/versions.env"
# shellcheck source=../../configs/device.env
source "${CONFIG_DIR}/device.env"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  log "错误：$*"
  exit 1
}

# Live 介质 flavor：minimal（文本控制台）或 gui（KDE Plasma 桌面）。
LIVE_FLAVOR="${LIVE_FLAVOR:-minimal}"
case "${LIVE_FLAVOR}" in
  minimal) LIVE_FLAVOR_SUFFIX="" ;;
  gui) LIVE_FLAVOR_SUFFIX="-gui" ;;
  *) die "LIVE_FLAVOR 必须是 minimal 或 gui，当前为：${LIVE_FLAVOR}" ;;
esac
LIVE_IMAGE_BASENAME="${IMAGE_BASENAME}${LIVE_FLAVOR_SUFFIX}"

require_root() {
  [[ ${EUID} -eq 0 ]] || die "此步骤需要 root（GitHub Actions 中使用 sudo）。"
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || die "缺少命令：${tool}"
  done
}

ensure_dirs() {
  install -d -m 0755 "${WORK_DIR}" "${CACHE_DIR}" "${OUT_DIR}"
}

assert_repo_path() {
  local candidate resolved_parent
  candidate="$1"
  resolved_parent="$(cd -- "$(dirname -- "${candidate}")" && pwd -P)"
  case "${resolved_parent}/$(basename -- "${candidate}")" in
    "${REPO_ROOT}"/.work|"${REPO_ROOT}"/.work/*|\
    "${REPO_ROOT}"/.cache|"${REPO_ROOT}"/.cache/*|\
    "${REPO_ROOT}"/out|"${REPO_ROOT}"/out/*) ;;
    *) die "拒绝操作仓库工作目录以外的路径：${candidate}" ;;
  esac
}

safe_remove_dir() {
  local directory
  directory="$1"
  assert_repo_path "${directory}"
  [[ -e ${directory} ]] || return 0
  rm -rf --one-file-system -- "${directory}"
}

safe_recreate_dir() {
  local directory
  directory="$1"
  install -d -m 0755 "$(dirname -- "${directory}")"
  safe_remove_dir "${directory}"
  install -d -m 0755 "${directory}"
}

fetch_file() {
  local url output
  url="$1"
  output="$2"
  install -d -m 0755 "$(dirname -- "${output}")"
  if [[ -s ${output} ]]; then
    log "使用缓存：${output}"
    return
  fi
  log "下载：${url}"
  curl --fail --location --retry 5 --retry-all-errors \
    --connect-timeout 30 --output "${output}.part" "${url}"
  mv -f -- "${output}.part" "${output}"
}

verify_sha256() {
  local expected file actual
  expected="$1"
  file="$2"
  actual="$(sha256sum --binary "${file}" | awk '{print $1}')"
  [[ ${actual} == "${expected}" ]] || die "SHA-256 不匹配：${file}（期望 ${expected}，实际 ${actual}）"
}

validate_aa64_efi() {
  local efi_file description
  efi_file="$1"
  command -v file >/dev/null 2>&1 || die "缺少命令：file（无法校验 EFI 架构）"
  [[ -s ${efi_file} ]] || die "BOOTAA64.EFI 不存在或为空：${efi_file}"
  description="$(LC_ALL=C file --brief "${efi_file}")"
  if ! grep -Eqi 'PE32\+.*(Aarch64|ARM64)' <<<"${description}"; then
    die "拒绝非 AA64 PE/COFF EFI：${efi_file}（file: ${description}）"
  fi
  if grep -Eqi '(x86-64|80386)' <<<"${description}"; then
    die "拒绝 x86/x86_64 EFI：${efi_file}（file: ${description}）"
  fi
  log "已确认 AA64 PE/COFF EFI：${description}"
}

apply_patch_once() {
  local source_tree patch_file strip
  source_tree="$1"
  patch_file="$2"
  strip="${3:-1}"

  if patch --directory "${source_tree}" --strip "${strip}" --batch --forward \
      --dry-run <"${patch_file}" >/dev/null; then
    patch --directory "${source_tree}" --strip "${strip}" --batch --forward <"${patch_file}"
  elif patch --directory "${source_tree}" --strip "${strip}" --batch --reverse \
      --dry-run <"${patch_file}" >/dev/null; then
    log "补丁已包含，跳过：$(basename -- "${patch_file}")"
  else
    die "补丁既不能应用，也不是已应用状态：${patch_file}"
  fi
}
