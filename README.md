# HUAWEI MateBook E 2019（PAK-AL09）Arch Linux ARM Live 构建器

> **实验性、非官方、可能无法启动。** 目标仅为 Snapdragon 850 / AArch64 的
> HUAWEI MateBook E 2019（PAK-AL09）。它不是华为、Arch Linux、Arch Linux
> ARM 或 sdm845-mainline 的官方产品。

本仓库只保存文本构建配方，不保存内核二进制、固件、ISO 或磁盘镜像。GitHub
Actions 在 Ubuntu x86_64 runner 上交叉编译固定内核，基于 Generic AArch64
Arch Linux ARM rootfs 制作 dracut `dmsquash-live` 系统，并输出：

- `matebook-e2019-archlive-6.16-dev-ed6098a.iso`：AA64 UEFI El Torito ISO；
- `matebook-e2019-archlive-6.16-dev-ed6098a.img.zst`：**推荐**的 GPT raw 镜像，
  含 128 MiB ESP 和 ext4 Live 分区；
- `linux-source-6.16-dev-ed6098a.tar.zst`：与已发布内核/模块完全对应、已应用
  固定补丁且移除 `.git` 的 GPL 完整源码；
- `SHA256SUMS`、`BUILD-INFO.txt`、`SOURCE-LOCK.env`、`packages.txt`、
  `kernel.config` 和 ISO El Torito 检查报告。

ISO 和 raw 镜像都使用未签名的 GRUB AA64 (`EFI/BOOT/BOOTAA64.EFI`)。EFI 由
ALARM AArch64 chroot 内的原生 `grub-mkstandalone` 生成，并用 `file` 强制验证为
AArch64 PE32+（拒绝 x86/x86_64），随后显式加载
`sdm850-huawei-matebook-e-2019.dtb`，再启动同一份 `Image`、dracut initramfs 与
squashfs。真机默认参数包含 `pd_ignore_unused clk_ignore_unused`；单独的故障排查菜单
可追加 `efi=novamap`，但不默认启用。raw 镜像更符合此设备的 UEFI/USB 启动路径；
部分固件不会把 USB ISO 当作光驱枚举。

## 必须先读的安全警告

1. **完整备份内部 UFS 与恢复资料。** 写错 `/dev/sdX` 会立即破坏其他磁盘；
   本项目无法恢复数据。Live 系统默认不会自动安装或写入内部 UFS，但 root/sudo
   用户仍然可以手工破坏它。
2. **关闭 Secure Boot。** 产物没有 Microsoft/设备所有者签名，本项目不生成、
   托管或请求任何签名密钥。不要用来源不明的预签名 EFI 文件替换它。
3. **QSEECom 有安全边界。** 固定的 New-Wheat 补丁给 Planck 默认配置只读 UEFI
   变量，但它仍是实验性的安全世界接口。GRUB 提供“禁用 QSEECom”菜单项，等价于
   `qcom_scm.qseecom=off`；异常时优先使用该项。
4. **EC/UCSI/充电、显示、相机、音频与休眠均可能不稳定。** 测试时保持可恢复电源，
   不要把该介质用于唯一的生产设备。

## 锁定上游、URL 与验证模型

锁定值集中在 [`configs/versions.env`](configs/versions.env)，下载逻辑在
[`scripts/fetch-sources.sh`](scripts/fetch-sources.sh)。任何更新都应作为人工审查的
供应链变更提交。

| 输入 | 固定版本 / URL | 构建时验证 |
|---|---|---|
| sdm845-mainline Linux | `sdm845/6.16-dev` 上的 `ed6098a37a4c59789a1103739d6e703b03a2804b`；`https://gitlab.com/sdm845-mainline/linux.git` | 只 fetch 该对象；比较完整 commit ID；`git fsck`。上游提交本身没有在本项目中另建信任签名。 |
| MateBook 支持资源 | New-Wheat `499401e36f17b463b633aef1283d2ed82eebbc52`；`raw.githubusercontent.com` | EC/UCSI、QSEECom、设备树四个补丁分别固定 SHA-256，下载后逐个验证。 |
| Generic AArch64 ALARM rootfs | `http://fl.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz`，上游时间 `2026-08-05T12:41:36Z` | MD5 `23eec86365b24f7913c403e8f4e8719b` 用来锁定字节（**不**作为抗攻击哈希）；同时强制验证 detached OpenPGP 签名，签名者完整指纹必须为 `68B3537F39A313B3E574D06777193F152BDBE6A6`。 |
| ALARM 公钥 | `hkps://keyserver.ubuntu.com` | 取得后比较 40 位完整指纹。信任锚应与 [Arch Linux ARM Package Signing](https://archlinuxarm.org/about/package-signing) 页面通过另一可信通道核对。 |
| 构建产物 | 本次 `out/` | 对所有发布文件生成 `SHA256SUMS`；workflow 上传与 Release 前再次 `sha256sum --check`。 |

ALARM 的下载镜像只提供 HTTP，传输层本身不可信；完整 OpenPGP 验证才是 rootfs 的
真实性/完整性检查，MD5 只承担“锁定 latest 指向的那一版”和发现普通损坏的作用。
若 `latest` 更新，旧 MD5 会使构建**失败关闭**，维护者必须先审查新版签名与内容再
更新锁文件。

### 可重复性边界

内核提交、补丁内容和基础 rootfs 字节已固定。Arch Linux ARM 是滚动发行版，
[`configs/packages.aarch64`](configs/packages.aarch64) 中的软件在 `pacman -Syu` 时从
当前已签名仓库安装，仓库不提供本项目可依赖的公开历史快照，所以完整镜像目前**不
保证逐字节可重复**。每次构建会把实际包版本写入 `packages.txt`；Release 审计时应
连同 `SOURCE-LOCK.env` 和 `SHA256SUMS` 保存。pacman 使用 rootfs 中的
`archlinuxarm-keyring` 并要求包签名。

## 内核补丁与启动链

构建顺序为：

1. 固定 sdm845-mainline 提交；
2. 固定并校验 `2-8-usb-typec-ucsi-add-recipient-arg...patch`；
3. 固定并校验 `huawei_planck_ec.patch`（EC、电池、背光、UCSI）；
4. 固定并校验 `huawei_planck_devicetree.patch`；
5. 固定并校验 `huawei_planck_qseecom.patch`；
6. 合并 [`configs/kernel.fragment`](configs/kernel.fragment)，交叉编译 `Image`、
   modules 与 PAK-AL09 DTB，并生成包含全部已应用补丁的 GPL 对应源码归档；
7. 用 `bsdtar -xpf`（保留 owner/mode/ACL/xattr）展开 rootfs，在 qemu-aarch64
   chroot 中安装原生 AArch64 `grub`，把提供 `devicetree` 命令的 `fdt.mod` 嵌入
   `BOOTAA64.EFI`，并由 dracut 的 `dmsquash-live` 生成 initramfs（dracut-ng ≥ 103
   的模块目录是 `70dmsquash-live`，更早版本是 `90dmsquash-live`，脚本两者都接受）；
   Generic rootfs 自带且不会启动的 `linux-aarch64`
   包会在升级前移除，避免保留第二套内核/模块；
8. GRUB AA64 通过设备树启动 squashfs + `rd.overlay` 临时 overlay；制作 ISO 和
   GPT raw 镜像。USB-C 根介质所需 DWC3/QCOM glue、QMP/QUSB2 PHY、USB Storage/UAS
   都强制内建，不依赖 initramfs 猜测模块。

内核补丁若既不能正向应用、也不是已经应用状态，脚本立即失败，不会使用 fuzz 后的
未知结果。关键 Kconfig 值也会在编译前逐项断言。

## 固件：缺失影响与法律边界

**本仓库及默认 GitHub Actions 绝不下载、提取或发布华为/高通/Windows/Android
设备专有固件。** 为控制体积，镜像只安装可再分发的
`linux-firmware-qcom` 与 `linux-firmware-atheros` 拆分包（而不是含 AMD/NVIDIA/Intel
固件的 `linux-firmware` 全量元包），但它们不能替代 PAK-AL09 设备专用 blob。
New-Wheat 设备树引用的典型路径包括：

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

缺少这些文件时，GPU、音频 DSP、传感器 DSP、调制解调器、IPA 网络加速、视频编解码
等功能可能不可用；Wi-Fi/蓝牙还可能需要设备校准数据。启动到文本控制台并不代表
全部硬件可用。

仅在你**已经合法取得且许可证允许自己使用**这些文件时，才可从本地目录注入：

```bash
sudo VENDOR_FIRMWARE_DIR=/absolute/path/to/firmware-tree bash scripts/build.sh
```

目录内容按 `/usr/lib/firmware/` 的相对路径复制；构建中会生成
`/usr/share/matebook-live/vendor-firmware.sha256`。脚本不会绕过加密、访问控制或
许可证，也不会从设备/恢复镜像自动提取内容。你有责任确认所在地法律、设备 EULA、
著作权和再分发权；**即使个人使用合法，把含专有固件的 ISO/镜像上传到 Release 也
可能违法。** 官方 workflow 未设置该变量，因此 Release 默认不含这些 blob。

## GitHub Actions

- [`validate.yml`](.github/workflows/validate.yml)：`bash -n`、ShellCheck、Ruby YAML
  解析、固定版本的 actionlint，以及仓库自带的锁定/产物检查；默认权限仅
  `contents: read`。
- [`build.yml`](.github/workflows/build.yml)：普通 build job 仅有
  `contents: read`；tag 为 `v*` 时，独立 release job 才获得下载同一工作流产物所需的
  `actions: read` 与发布所需的 `contents: write`。
  所有 GitHub 官方 action 都固定为完整 commit SHA。
- push、PR 与手工触发会构建 artifact；tag 构建在校验哈希后自动创建/更新 GitHub
  Release。

GitHub-hosted runner 通常只有约 14 GiB 可用空间。workflow 会先清理临时 runner 的
Android/.NET/GHC 缓存，记录 `df -h`，并设置 `CLEAN_INTERMEDIATES=1`：内核完成后
删除 build tree/worktree，squashfs 完成后删除展开 rootfs，最终删除其余 `.work/`。
补丁、来源锁、发布产物和 GPL 对应源码均保留。磁盘、网络或六小时上限仍可能使完整
构建失败；这不是启动成功的硬件证明。

## 本地构建

建议使用干净的 Ubuntu 24.04 x86_64、8 GiB 内存。默认保留调试中间文件时准备约
35 GiB；空间受限时使用 `CLEAN_INTERMEDIATES=1` 分阶段释放中间文件（仍建议在开始
前确保约 14 GiB 可用）。依赖与 CI 保持一致：

```bash
sudo apt-get update
sudo apt-get install --yes --no-install-recommends \
  bc bison build-essential ca-certificates cpio curl device-tree-compiler \
  dirmngr dosfstools e2fsprogs file flex gcc-aarch64-linux-gnu gdisk git gnupg \
  kmod libarchive-tools libelf-dev libssl-dev mtools patch qemu-user-static \
  rsync squashfs-tools xorriso zstd
sudo CLEAN_INTERMEDIATES=1 bash scripts/build.sh  # 省空间；调试时可去掉该变量
(cd out && sha256sum --check SHA256SUMS)
```

脚本使用 `set -Eeuo pipefail`；`.work/` 和 `out/` 会幂等重建，`.cache/` 保留已验证的
下载。`CLEAN_INTERMEDIATES=1` 只改变中间文件保留策略，不改变发布资产。清理函数
只接受仓库内这三个工作路径。不要在不受信任的 fork 上直接使用 sudo 运行构建脚本。

## 写入与启动

先验证下载，然后再次确认目标盘。下面的 `/dev/sdX` **必须替换为整个可移动设备，
不能是分区，也绝不能是内部 UFS/NVMe**：

```bash
sha256sum --check SHA256SUMS
zstd -dc matebook-e2019-archlive-6.16-dev-ed6098a.img.zst \
  | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync
sync
```

也可以把 ISO 写到整盘，但优先使用 `.img.zst`。在设备固件设置中关闭 Secure Boot，
选择 USB 的 AA64 UEFI 启动项。Live 账号为 `live`，密码为 `live`，wheel/sudo 无密码；
root 密码锁定。该弱密码只适合临时、受控的 Live 环境；`sshd` 已安装但默认禁用，
需要时请在改密或配置密钥后手工启动。

## 静态检查

安装 `shellcheck`、Ruby 和 actionlint 后运行：

```bash
STRICT_TOOLS=1 bash scripts/validate.sh
# 构建后还可显式重验 EFI 架构：
AA64_EFI_PATH=.work/boot/BOOTAA64.EFI STRICT_TOOLS=1 bash scripts/validate.sh
```

没有这些工具时，脚本仍会运行 `bash -n` 与内建检查，但会明确警告跳过项。

## 已知未验证风险

- 本仓库的静态检查不等于完整内核/镜像构建，更不等于 PAK-AL09 真机启动测试；
- 固定内核上游对应的 GitLab pipeline 曾显示失败状态，本项目只能以自己的编译结果
  为准；
- New-Wheat EC/UCSI/QSEECom 补丁仍属板级实验代码；
- dracut、GRUB AA64、qemu-user-static 与 ALARM 滚动包未来可能产生接口变化；
- 相机、音频、外接显示、蜂窝、挂起/恢复以及专有固件组合尚需逐机验证。

## 许可证

本仓库自有脚本和文档采用 [`LICENSE`](LICENSE) 中的 MIT License。构建时下载的 Linux
内核、New-Wheat 补丁、Arch Linux ARM 包和固件分别受其各自许可证约束；MIT License
不会改变或授予这些上游内容的权利。自动构建会把
`linux-source-6.16-dev-ed6098a.tar.zst` 与内核/模块一同发布并纳入
`SHA256SUMS`，用于提供本次已补丁内核的完整对应源码；发布者仍须履行其余 GPL 条款、
软件包许可证与任何固件条款。
