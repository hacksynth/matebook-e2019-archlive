# HUAWEI MateBook E 2019（PAK-AL09）Arch Linux ARM Live 构建器

> **实验性、非官方项目，可能无法启动。** 目标设备为 Snapdragon 850 / AArch64 的 HUAWEI MateBook E 2019（PAK-AL09）。显示、触控、键盘、存储、无线网络及休眠功能都需要在真机上验证；请勿把本项目作为唯一生产系统或恢复手段。

本项目在 Ubuntu x86_64 环境中交叉编译 Linux stable 内核，并基于 Arch Linux ARM Generic AArch64 rootfs 构建可启动的 Live 介质。当前配置使用 Linux stable **v7.3.4** 和上游设备树 `qcom/sdm850-huawei-matebook-e-2019.dtb`。

## 构建产物

每次构建同时生成两个 flavor（内核只编译一次）：

| flavor | 产物 | 桌面 |
|---|---|---|
| `minimal` | `matebook-e2019-archlive-7.3.4.img.zst` / `.iso` | 文本控制台（multi-user） |
| `gui` | `matebook-e2019-archlive-7.3.4-gui.img.zst` / `.iso` | KDE Plasma，`sddm` 自动登录 `live` |

两种介质都附带 `SHA256SUMS`、`BUILD-INFO*.txt`、`SOURCE-LOCK.env`、`DEVICE-PROFILE.env`、
`packages*.txt`、`kernel.config`、`linux-source-7.3.4.tar.zst` 与 ISO El Torito 检查报告。

GUI 包列表在 `configs/packages-gui.aarch64`，只安装精简 Plasma 6（桌面、屏幕、网络、音频、
Dolphin/Konsole、Noto/CJK 字体、PipeWire、Mesa freedreno），避免 `plasma-meta` 的整套应用。

镜像使用未签名的 ARM64 GRUB，不支持 Secure Boot。GRUB 显式加载设备树、内核 `Image`、dracut initramfs 与 SquashFS Live 根文件系统。部分设备固件无法将 USB ISO 当作光驱枚举，通常优先尝试 raw 镜像。

## 项目结构

```text
configs/                 内核、设备、GRUB、dracut 与 ALARM 包配置
scripts/                 来源验证、内核、rootfs、介质构建与静态检查
  lib/common.sh          路径保护、日志、依赖检查和 AA64 EFI 校验
vendor-firmware/         PAK-AL09 专有 Qualcomm 固件及相关设备数据
.github/workflows/       Linux 构建、验证与发布工作流
```

## 设备基线与功能范围

`configs/device.env` 记录目标设备硬件基线：PAK-AL09 / 产品版本 M1010、Snapdragon 850、8 GiB 内存、2160 × 1440 显示屏、Goodix GT7380 I2C-HID 触摸屏及 Qualcomm WCN3990。内核配置在 `configs/kernel.fragment`，包括 Live 所需的 SquashFS/OverlayFS、压缩 initramfs、USB/UFS/SD、USB-C QCOM PHY、eDP 显示、触控及 WCN3990 `ath10k_snoc` 支持。

`configs/grub.cfg` 提供三个启动项：默认启动、禁用 QSEECom 排错，以及添加 `efi=novamap` 的 UEFI 排错。三个启动项都使用 dracut 的 `rd.live.ram=1`，在启动阶段把 SquashFS 根文件系统复制到 RAM；等待进入 Live 系统后即可拔掉 U 盘。该方式会额外占用约一份 SquashFS 大小的内存，目标设备的 8 GiB 内存应能满足要求，但启动会比直接从 U 盘读取更慢。当前上游内核配置不含 6.16 的 Planck EC/UCSI/QSEECom 板级补丁，因此电池状态、EC 背光、合盖、Fn 键和部分 USB-C 角色切换功能可能不可用。

WCN3990 Wi-Fi 已在 PAK-AL09 的持久 UFS 安装会话中验证可创建 `wlan0` 并扫描热点。Live 镜像使用相同链路：先禁止 udev 按设备别名过早加载驱动，再启动 `rmtfs`、`pd-mapper`、`tqftpserv` 和 MSS remoteproc，随后显式加载 `ath10k_snoc`，等待 `wlan0` 出现后才启动 NetworkManager。安装脚本优先使用 `linux-firmware-atheros` 的 WCN3990 `wlanmdsp.mbn`，仅在缺失时回退到设备目录中的 Windows 文件。发行版 `board-2.bin` 已包含 `Huawei_Planck` 校准项；Windows `bdwlan.*` 不能直接替代它。Live 中包含 `nmcli`/`nmtui`、`iw`、`rfkill`，GUI flavor 还包含 Plasma NetworkManager 面板。

持久安装的 initramfs 必须在根分区切换前找到 ADSP/CDSP/SLPI 固件；`configs/dracut-qcom-firmware.conf` 列出了需要携带的设备固件。当前 RTC 驱动不能写回硬件时钟，系统时间应在联网后由 NTP 客户端校正。

## 来源锁定与验证

网络输入锁定在 `configs/versions.env`，设备基线在 `configs/device.env`，取源逻辑在 `scripts/fetch-sources.sh`。构建脚本获取固定内核 tag 并校验完整提交 SHA；对 Arch Linux ARM Generic AArch64 rootfs 校验锁定 MD5、分离 OpenPGP 签名及 ALARM 构建密钥完整指纹。上游 `latest` rootfs 内容变化时构建会失败关闭；维护者应审查来源后更新锁文件，不要绕过校验。

Arch Linux ARM 使用滚动软件包。最终包版本随构建时仓库状态变化并记录在 `packages.txt`，所以即使内核和 rootfs 输入已锁定，完整镜像仍不保证逐字节可重复。

## 构建流程

1. 获取并校验内核源码与 ALARM rootfs；
2. 合并 `configs/kernel.fragment`，构建 arm64 `Image`、模块和 PAK-AL09 DTB，并检查关键内核配置；
3. 在 qemu-aarch64 chroot 中更新 ALARM 包、配置 Live 用户与服务、生成 AA64 GRUB 和 dracut `dmsquash-live` initramfs；
4. 生成 SquashFS、ISO、GPT raw 镜像及 SHA-256 校验和。

chroot 内为适配 qemu-user 会关闭 pacman 7 下载沙箱并规避 `CheckSpace` 误报，但包签名校验保持启用。Qualcomm Wi-Fi 用户空间服务由 `scripts/install-qualcomm-wifi-services.sh` 从固定提交构建。该脚本会清理编译工具链，但**保留 `pkgconf`**：`dracut` 生成 initramfs 时依赖它，卸载会导致 pacman 事务失败。

## 专有固件注意事项

`vendor-firmware/` 包含从目标设备提取的 PAK-AL09 专有 Qualcomm 固件。构建脚本检测到该目录时会自动注入，也可以通过环境变量指定本地固件树：

```bash
sudo VENDOR_FIRMWARE_DIR=/absolute/path/to/firmware-tree bash scripts/build.sh
```

固件按 `/usr/lib/firmware/` 的相对路径复制，镜像内会生成 SHA-256 清单。缺少设备专有固件或校准数据时，部分 SoC 功能及无线网络可能不可用。固件受硬件厂商许可约束；请确保有权使用，并且不要公开仓库或向无权限的第三方分发固件、含固件镜像或相关构建产物。

## 本地构建

建议在 Ubuntu 24.04 x86_64、至少 8 GiB 内存的干净环境构建；默认保留中间文件时准备约 35 GiB 空间。安装宿主依赖并运行：

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

也可以分开运行内核与介质阶段；两个阶段须使用同一工作目录中的构建数据：

```bash
sudo STAGE=kernel CLEAN_INTERMEDIATES=1 bash scripts/build.sh
# 两个 flavor 共用内核产物，介质阶段不要开 CLEAN_INTERMEDIATES
for flavor in minimal gui; do
  sudo STAGE=media CLEAN_INTERMEDIATES=0 LIVE_FLAVOR="${flavor}" bash scripts/build.sh
done
```

只构建文本版或只构建 GUI 版时，单独设置 `LIVE_FLAVOR=minimal` 或 `LIVE_FLAVOR=gui` 即可。

构建脚本需要 root 执行。不要在不受信任的 fork 上用 sudo 执行。

## GitHub Actions 与静态检查

- `validate.yml` 运行 `scripts/validate.sh`，检查 Shell 语法、ShellCheck、workflow YAML/actionlint、来源锁、配置、设备树以及预期文件；也可检查已构建 EFI 的 AA64 PE/COFF 架构。
- `build.yml` 在 Ubuntu runner 上将内核与介质阶段分开，按构建输入哈希缓存内核并校验产物。
  **不再使用 `actions/upload-artifact`（它总会打包成 zip）**，而是把 `out/` 下每个产物
  逐个作为独立 Release asset 直接上传：`v*` tag 构建发布对应正式 Release，`main` 构建
  更新滚动预发布 `latest`，PR 构建只校验不上传。

安装 ShellCheck、Ruby、actionlint 等验证工具后运行：

```bash
STRICT_TOOLS=1 bash scripts/validate.sh
AA64_EFI_PATH=.work/boot/BOOTAA64.EFI STRICT_TOOLS=1 bash scripts/validate.sh
```

第二条命令需要已生成的 EFI 文件。静态检查不等同于完整镜像构建或目标设备启动测试。

## 写入与启动

先验证校验和，再确认写入目标是**整个可移动设备**。将 `/dev/sdX` 替换为正确设备；写错目标会破坏数据，绝不能指向内部 UFS/NVMe：

```bash
sha256sum --check SHA256SUMS
zstd -dc matebook-e2019-archlive-7.3.4.img.zst \
  | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync
sync
```

写入前备份内部存储与恢复资料，并在设备固件设置中关闭 Secure Boot，选择 USB 的 AA64 UEFI 启动项。Live 用户为 `live`，密码为 `live`，wheel/sudo 无密码；root 密码锁定，`sshd` 默认禁用。该弱密码只适合临时、受控的 Live 环境。系统默认不安装到内部 UFS，但 root 用户仍可手动破坏磁盘。

## 已知风险与许可

- 本项目处于实验阶段，显示、触控、键盘、存储、Wi-Fi、蓝牙和休眠均需在 PAK-AL09 真机验证；
- 上游 ALARM 滚动软件包、dracut、GRUB AA64 与 qemu-user-static 可能发生接口变化；
- 构建并不自动代表介质已经过真机启动测试。

本仓库自有脚本和文档采用 MIT License。Linux 内核、Arch Linux ARM 包及设备固件分别受其各自许可约束；使用者和构建者应自行确认使用及分发权限。
