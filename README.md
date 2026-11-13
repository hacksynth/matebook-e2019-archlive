# HUAWEI MateBook E 2019（PAK-AL09）Arch Linux ARM Live 构建器

> **实验性、非官方、可能无法启动。** 目标仅为 Snapdragon 850 / AArch64 的
> HUAWEI MateBook E 2019（PAK-AL09）。它不是华为、Arch Linux、Arch Linux
> ARM 或 Linux 内核的官方产品。

本仓库只保存文本构建配方，不保存内核二进制、固件、ISO 或磁盘镜像。GitHub
Actions 在 Ubuntu x86_64 runner 上交叉编译 **Linux stable v7.3.4**，基于
Generic AArch64 Arch Linux ARM rootfs 制作 dracut `dmsquash-live` 系统，并输出：

- `matebook-e2019-archlive-7.3.4.img.zst`：**推荐**的 GPT raw 镜像，
  含 128 MiB ESP 和 ext4 Live 分区；
- `matebook-e2019-archlive-7.3.4.iso`：AA64 UEFI El Torito ISO；
- `SHA256SUMS`、`BUILD-INFO.txt`、`SOURCE-LOCK.env`、`DEVICE-PROFILE.env`、
  `packages.txt`、`kernel.config`、`linux-source-7.3.4.tar.zst`（完整对应源码）
  和 ISO El Torito 检查报告。

ISO 和 raw 镜像都使用未签名的 GRUB AA64 (`EFI/BOOT/BOOTAA64.EFI`)，显式加载
`qcom/sdm850-huawei-matebook-e-2019.dtb`，再启动同一份 `Image`、dracut initramfs
与 squashfs。raw 镜像更符合此设备的 UEFI/USB 启动路径；部分固件不会把 USB ISO
当作光驱枚举。

## 必须先读的安全警告

1. **完整备份内部 UFS 与恢复资料。** 写错 `/dev/sdX` 会立即破坏其他磁盘；
   本项目无法恢复数据。Live 系统默认不会自动安装或写入内部 UFS，但 root/sudo
   用户仍然可以手工破坏它。
2. **关闭 Secure Boot。** 产物没有 Microsoft/设备所有者签名，本项目不生成、
   托管或请求任何签名密钥。不要用来源不明的预签名 EFI 文件替换它。
3. **显示、触控、键盘、存储、Wi-Fi 与休眠仍需真机验证。** 测试时保持可恢复电源，
   不要把该介质用于唯一的生产设备。

## 版本与板级支持现状

| 项目 | v0.2.0（本仓库当前默认） | v0.1.0（历史 Release） |
|---|---|---|
| 内核 | Linux stable **v7.3.4** | sdm845-mainline 6.16-dev @ `ed6098a` |
| 设备树 | **上游已合入** `sdm850-huawei-matebook-e-2019.dts` | New-Wheat 外部补丁 |
| 显示链路 | 上游 `sn65dsi86` + `panel-edp` + Panfrost | 同左（补丁树） |
| 触控/键盘 | 上游 i2c-HID、USB HID | 同左 |
| UFS / SD / USB-C | 上游 QCOM UFS、SDHCI、DWC3/QMP/QUSB2 | 同左（含 UCSI 补丁） |
| Wi-Fi / 蓝牙 | 上游 `ath10k`（WCN3990），校准名 `Huawei_Planck` | 校准名 `Lenovo_C630` |
| EC（电池/背光/合盖/Fn/UCSI） | **暂未包含**（需把 6.16 的 huawei-planck-ec 补丁移植到 7.3） | 已包含 New-Wheat EC/UCSI/QSEECom 补丁 |

v0.2.0 的目标是“**干净地跟踪最新稳定内核**”：只使用上游树与上游设备树，不再
依赖 6.16 专用的板级补丁。代价是 EC 相关功能（电池百分比、EC 背光、合盖事件、
Fn 键、部分 USB-C 角色切换）在 v0.2.0 中可能不可用；这些功能仍保留在 v0.1.0。
如果你需要 EC 功能优先，请使用 v0.1.0 或等待后续把 EC 驱动移植到 7.3。

## 当前实机硬件基线

2026-11-13 在目标设备上核对到以下配置；不含序列号、UUID 等唯一标识：

| 项目 | 当前设备 |
|---|---|
| 型号 | HUAWEI MateBook E 2019 PAK-AL09，产品版本 M1010 |
| SoC / 内存 | Snapdragon 850，8 GiB |
| 显示 | 2160 × 1440，Adreno 630，上游 `innolux,p120zdg-bf1` + `sn65dsi86` 链路 |
| 内部存储 | 256 GB UFS；另有一个 SD 读卡器 |
| 触摸 | Goodix GT7380，I2C-HID（ACPI/HID ID `GXTP7380`） |
| Wi‑Fi / 蓝牙 | Qualcomm WCN3990，`ath10k` + QCA UART |
| BIOS 验证基线 | 1.15（2019-04-26），UEFI |

设备型号、设备树和固件根目录集中在
[`configs/device.env`](configs/device.env)。内核缓存键包含该文件；最终介质还会附带
`DEVICE-PROFILE.env`，便于确认产物对应的目标设备。

## 锁定上游、URL 与验证模型

网络输入锁定在 [`configs/versions.env`](configs/versions.env)，目标设备基线在
[`configs/device.env`](configs/device.env)，下载逻辑在
[`scripts/fetch-sources.sh`](scripts/fetch-sources.sh)。任何更新都应作为人工审查的
供应链或设备配置变更提交。

| 输入 | 固定版本 / URL | 构建时验证 |
|---|---|---|
| Linux 内核 | `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`，tag `v7.3.4`，提交 `7595a62d45ee1a2297eafa5f2ef5d0a45142d84d` | 只 fetch 该 tag（depth=1），比较完整 commit ID；分支/tag 被移动会导致构建失败关闭 |
| Generic AArch64 ALARM rootfs | `http://fl.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz`，上游时间 `2026-08-05T12:41:36Z` | MD5 `23eec86365b24f7913c403e8f4e8719b` 锁定字节（**不**作为抗攻击哈希）；同时强制验证 detached OpenPGP 签名，签名者完整指纹必须为 `68B3537F39A313B3E574D06777193F152BDBE6A6` |
| ALARM 公钥 | `hkps://keyserver.ubuntu.com`，失败时回退 HTTPS keyserver | 取得后比较 40 位完整指纹 |
| 构建产物 | 本次 `out/` | 对所有发布文件生成 `SHA256SUMS`；workflow 上传与 Release 前再次 `sha256sum --check` |

ALARM 的下载镜像只提供 HTTP，完整 OpenPGP 验证才是 rootfs 的真实性/完整性检查。
若 `latest` 更新，旧 MD5 会使构建**失败关闭**，维护者必须先审查新版签名与内容再
更新锁文件。Arch Linux ARM 是滚动发行版，`pacman -Syu` 安装当时的已签名包，
因此完整镜像目前**不保证逐字节可重复**；每次构建会把实际包版本写入
`packages.txt`。

## 构建流程

1. fetch 并校验 stable `v7.3.4` 与 ALARM rootfs；
2. 合并 arm64 `defconfig` 与 [`configs/kernel.fragment`](configs/kernel.fragment)
   （Live/OverlayFS/SquashFS、initramfs zstd 解压、模块压缩、USB-C 根设备所需
   DWC3/QCOM glue、QMP/QUSB2 PHY、USB Storage/UAS、显示/触控驱动）；
3. 交叉编译 `Image`、modules 与设备配置指定的 PAK-AL09 DTB，剥离调试符号并
   zstd 压缩模块；
4. 生成包含上游 PAK-AL09 设备树的完整 GPL 对应源码归档；
5. 在 qemu-aarch64 chroot 中展开 rootfs、安装 ALARM 包，用 ALARM 原生 AArch64
   GRUB 生成 `BOOTAA64.EFI`（内嵌提供 `devicetree` 命令的 `fdt.mod`），由 dracut
   的 `dmsquash-live` 生成 live initramfs（dracut-ng ≥ 103 的目录是
   `70dmsquash-live`，脚本同时兼容旧的 `90dmsquash-live`）；
6. 制作 ISO 与 GPT raw 镜像（ESP + ext4 Live 分区），生成校验和。

chroot 内会关闭 pacman 7 的下载 Landlock 沙箱（qemu-user 不支持）并规避
`CheckSpace` 误报，但**包签名校验保持启用**；同时移除全量固件元包与
AMD/NVIDIA/Intel 等无关平台的固件拆分包，只保留 Qualcomm/Atheros。

## 固件：缺失影响与法律边界

**本仓库及默认 GitHub Actions 绝不下载、提取或发布华为/高通/Windows/Android
设备专有固件。** 镜像只安装可再分发的 `linux-firmware-qcom` 与
`linux-firmware-atheros`，它们不能替代 PAK-AL09 设备专用 blob。上游设备树引用的
典型路径包括：

```text
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/qcadsp850.mbn
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/qccdsp850.mbn
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/qcdsp1v2850.mbn
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/qcdsp2850.mbn
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/qcslpi850.mbn
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/qcdxkmsuc850.mbn
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/ipa_fws.elf
/usr/lib/firmware/qcom/sdm850/HUAWEI/AL09/qcvss850.mbn
```

缺少这些文件时，GPU 加速、音频 DSP、传感器 DSP、调制解调器、IPA 网络加速、视频
编解码等功能可能不可用；Wi-Fi/蓝牙还可能需要设备校准数据。仅在你**已经合法取得
且许可证允许自己使用**这些文件时，才可从本地目录注入：

```bash
sudo VENDOR_FIRMWARE_DIR=/absolute/path/to/firmware-tree bash scripts/build.sh
```

目录内容按 `/usr/lib/firmware/` 的相对路径复制；构建中会生成
`/usr/share/matebook-live/vendor-firmware.sha256`。**即使个人使用合法，把含专有
固件的 ISO/镜像上传到 Release 也可能违法。**

## GitHub Actions

- [`validate.yml`](.github/workflows/validate.yml)：`bash -n`、ShellCheck、Ruby YAML
  解析、固定版本的 actionlint，以及仓库自带的锁定/产物检查；默认权限仅
  `contents: read`。
- [`build.yml`](.github/workflows/build.yml)：普通 build job 仅有 `contents: read`；
  tag 为 `v*` 时，独立 release job 才获得 `download-artifact` 所需的 `actions: read`
  与发布所需的 `contents: write`。所有 GitHub 官方 action 都固定为完整 commit SHA。
  构建分为内核阶段和介质阶段：内核阶段完成后立即 `actions/cache/save` 保存按输入
  哈希命名的内核缓存，介质阶段失败时下一轮可直接复用内核。
- [`publish-release.yml`](.github/workflows/publish-release.yml)：手动从某次成功构建的
  artifact 下载、校验 `SHA256SUMS` 并发布/更新 Release，用于本地上传大文件不稳定时。

推 `v*` tag 会重新构建并自动发布 Release。

## 本地构建

建议使用干净的 Ubuntu 24.04 x86_64、8 GiB 内存。默认保留调试中间文件时准备约
35 GiB；空间受限时使用 `CLEAN_INTERMEDIATES=1` 分阶段释放中间文件：

```bash
sudo apt-get update
sudo apt-get install --yes --no-install-recommends \
  bc bison build-essential ca-certificates cpio curl device-tree-compiler \
  dirmngr dosfstools e2fsprogs file flex gcc-aarch64-linux-gnu gdisk git gnupg \
  kmod libarchive-tools libelf-dev libssl-dev mtools patch qemu-user-static \
  rsync squashfs-tools xorriso zstd
sudo CLEAN_INTERMEDIATES=1 bash scripts/build.sh
(cd out && sha256sum --check SHA256SUMS)
```

也可以像 CI 一样分阶段构建，便于复用内核产物或只重跑介质阶段：

```bash
sudo STAGE=kernel CLEAN_INTERMEDIATES=1 bash scripts/build.sh  # 取源 + 编译内核 + GPL 源码
sudo STAGE=media  CLEAN_INTERMEDIATES=1 bash scripts/build.sh  # rootfs + ISO + raw
```

脚本使用 `set -Eeuo pipefail`；`.work/` 和 `out/` 会幂等重建，`.cache/` 保留已验证的
下载与内核缓存。清理函数只接受仓库内这三个工作路径。不要在不受信任的 fork 上直接
使用 sudo 运行构建脚本。

## 写入与启动

先验证下载，然后再次确认目标盘。下面的 `/dev/sdX` **必须替换为整个可移动设备，
不能是分区，也绝不能是内部 UFS/NVMe**：

```bash
sha256sum --check SHA256SUMS
zstd -dc matebook-e2019-archlive-7.3.4.img.zst \
  | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync
sync
```

也可以把 ISO 写到整盘，但优先使用 `.img.zst`。在设备固件设置中关闭 Secure Boot，
选择 USB 的 AA64 UEFI 启动项。Live 账号为 `live`，密码为 `live`，wheel/sudo 无密码；
root 密码锁定。该弱密码只适合临时、受控的 Live 环境；`sshd` 已安装但默认禁用。

### 首次启动排错

GRUB 菜单提供三个条目，按以下顺序尝试：

1. 默认条目（`qcom_scm.qseecom=auto`，OverlayFS 临时 overlay）；
2. **禁用 QSEECom**（`qcom_scm.qseecom=off`）：UEFI 变量/安全世界相关崩溃时使用；
3. **`efi=novamap`**：设备 UEFI 在 `SetVirtualAddressMap` 后异常（重启、黑屏、卡死）时使用。

如果没有任何输出，先用外接 USB 键盘确认是否已进入 GRUB；再检查固件是否把该 U 盘
识别为 UEFI 可移动设备。系统内可用
`dmesg | grep -Ei 'panic|oops|firmware|dwc3|panel|touch'` 收集信息。

## 静态检查

安装 `shellcheck`、Ruby 和 actionlint 后运行：

```bash
STRICT_TOOLS=1 bash scripts/validate.sh
AA64_EFI_PATH=.work/boot/BOOTAA64.EFI STRICT_TOOLS=1 bash scripts/validate.sh
```

没有这些工具时，脚本仍会运行 `bash -n` 与内建检查，但会明确警告跳过项。

## 已知未验证风险

- 本仓库的静态检查不等于完整内核/镜像构建，更不等于 PAK-AL09 真机启动测试；
- v0.2.0 使用上游 7.3.4 设备树，但**未在真机验证**；显示/触控/Wi-Fi/休眠需逐项测试；
- 7.3.4 不含 huawei-planck-ec / Planck UCSI / QSEECom 板级补丁，EC 相关功能缺失；
- 上游 `ath10k` 使用 `Huawei_Planck` 校准名，缺少设备专有 BDF 时 Wi-Fi 不可用；
- 相机（gc5025 / s5k3l6xx）在该机型上有已知硬件侧限制；外接 USB-C 显示表现一般；
- ALARM 滚动包、dracut、GRUB AA64 与 qemu-user-static 未来可能产生接口变化。

## 许可证

本仓库自有脚本和文档采用 [`LICENSE`](LICENSE) 中的 MIT License。构建时下载的 Linux
内核、Arch Linux ARM 包和固件分别受其各自许可证约束；自动构建会把
`linux-source-7.3.4.tar.zst` 与内核/模块一同发布并纳入 `SHA256SUMS`，用于提供本次
内核的完整对应源码；发布者仍须履行其余 GPL 条款、软件包许可证与固件条款。
