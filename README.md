# HUAWEI MateBook E 2019（PAK-AL09）Arch Linux ARM Live 构建器

> **实验性、非官方项目，可能无法启动。** 目标设备为 Snapdragon 850 / AArch64 的 HUAWEI MateBook E 2019（PAK-AL09）。当前已经完成一次真机检测，结果见下文；新增镜像仍应回归测试。请勿把本项目作为唯一生产系统或恢复手段。

本项目在 Ubuntu x86_64 环境中交叉编译 Linux stable 内核，并基于 Arch Linux ARM Generic AArch64 rootfs 构建可启动的 Live 介质。当前配置使用 Linux stable **v7.3.5**，同时生成两个内核变体：

| 内核变体 | 内容 |
|---|---|
| `stock` | 纯上游 7.3.5 内核与设备树 |
| `planck` | 应用 `analysis/bios-1.16/patches/` 中的 EC/电池/UCSI 四补丁，并启用 Planck EC、电池、背光、Lid 与 USB-C UCSI 驱动 |

## 构建产物

每个内核变体都会生成四个桌面 flavor，因此完整 CI 共生成八个组合。文件名格式为
`matebook-e2019-archlive-7.3.5-<stock|planck>[-<desktop>]`：

| flavor | 产物 | 桌面 |
|---|---|---|
| `minimal` | `...-<variant>.img.zst` / `.iso` | 文本控制台（multi-user） |
| `kde` | `...-<variant>-kde.img.zst` / `.iso` | KDE Plasma，`sddm` 自动登录 `live` |
| `gnome` | `...-<variant>-gnome.img.zst` / `.iso` | GNOME，`gdm` 自动登录 `live` |
| `xfce` | `...-<variant>-xfce.img.zst` / `.iso` | XFCE，`lightdm` 自动登录 `live` |

每个变体附带独立的 `SHA256SUMS-stock` 或 `SHA256SUMS-planck`，以及带变体后缀的
`BUILD-INFO*.txt`、`SOURCE-LOCK*.env`、`DEVICE-PROFILE*.env`、`packages*.txt`、
`kernel-*.config`、GPL 源码归档和 ISO El Torito 检查报告。

GUI 共享包位于 `configs/packages-gui-common.aarch64`，桌面专属包分别为
`packages-kde.aarch64`、`packages-gnome.aarch64` 和 `packages-xfce.aarch64`。三种桌面都使用
Noto/CJK 字体、PipeWire、Mesa freedreno，并分别由 SDDM、GDM 和 LightDM 自动登录 `live`。
`LIVE_FLAVOR=gui` 仍作为 KDE 的历史兼容别名。

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

`configs/device.env` 记录目标设备硬件基线：PAK-AL09 / 产品版本 M1010、Snapdragon 850、8 GiB 内存、2160 × 1440 显示屏、Goodix GT7380 I2C-HID 触摸屏及 Qualcomm WCN3990。共享内核配置在 `configs/kernel.fragment`，包括 Live 所需的 SquashFS/OverlayFS、压缩 initramfs、USB/UFS/SD、USB-C QCOM PHY、eDP 显示、触控及 WCN3990 `ath10k_snoc` 支持；`configs/kernel.planck.fragment` 只增加 Planck EC、电池与 UCSI 驱动。

`configs/grub.cfg` 提供三个启动项：默认启动、禁用 QSEECom 排错，以及添加 `efi=novamap` 的 UEFI 排错。三个启动项都使用 dracut 的 `rd.live.ram=1`，在启动阶段把 SquashFS 根文件系统复制到 RAM；等待进入 Live 系统后即可拔掉 U 盘。该方式会额外占用约一份 SquashFS 大小的内存，目标设备的 8 GiB 内存应能满足要求，但启动会比直接从 U 盘读取更慢。`stock` 变体不含 Planck EC/UCSI 板级补丁，电池状态、EC 背光、合盖和部分 USB-C 功能可能不可用；`planck` 变体包含这些驱动，但仍需真机验证。

WCN3990 Wi-Fi 已在 PAK-AL09 的持久 UFS 安装会话中验证可创建 `wlan0` 并扫描热点。Live 镜像使用相同链路：先禁止 udev 按设备别名过早加载驱动，再启动 `rmtfs`、`pd-mapper`、`tqftpserv` 和 MSS remoteproc，随后显式加载 `ath10k_snoc`，等待 `wlan0` 出现后才启动 NetworkManager。安装脚本默认使用经过真机验证的旧版 `wlanmdsp.mbn`，可选择性地通过 `WCN3990_FIRMWARE_CHANNEL=shikra-experimental` 构建上游 `WLAN.HL.3.3.7.c5-00226` 配对固件；该实验版本会校验提交和 SHA-256，但在 PAK-AL09 冷启动时出现 `wlan_process` grace timer 超时，因此不能作为默认构建。发行版 `board-2.bin` 已包含 `Huawei_Planck` 校准项；Windows `bdwlan.*` 不能直接替代它。Live 中包含 `nmcli`/`nmtui`、`iw`、`rfkill`，三种桌面 flavor 都带网络管理面板。

同一 WCN3990 的蓝牙控制器在 PAK-AL09 上可能报告全零 BD_ADDR。Live 会由 `planck-bt-address.service` 根据 `/etc/machine-id` 生成本地管理蓝牙地址，使 BlueZ 完成控制器配置；系统同时显式安装 `bluez` 和 `bluez-utils`。

持久安装的 initramfs 必须在根分区切换前找到 ADSP/CDSP/SLPI 固件；`configs/dracut-qcom-firmware.conf` 列出了需要携带的设备固件。当前 RTC 驱动不能写回硬件时钟，系统时间应在联网后由 NTP 客户端校正。

## 真机检测状态（2026-11-18）

以下结果来自一次在 PAK-AL09 上启动 GNOME Live 镜像后的只读检测。测试内核为
Linux `7.3.5-g988117cc1bb1-dirty`，运行环境包含 Planck EC、电池和 UCSI 驱动。
本次没有接入充电器、外接显示器或物理键盘盖，因此未测试的功能不会据此推断为不可用。
该记录描述的是当前镜像和当前运行会话，不能替代后续构建的回归测试。

### 已验证可用

| 功能 | 检测结果 |
|---|---|
| CPU 与内存 | 8 个 CPU 核心在线，约 7.3 GiB 内存可用 |
| 内屏与桌面 | `card0-eDP-1` 已连接，模式为 `2160x1440`；GNOME Wayland 正常启动 |
| GPU 渲染 | Adreno 630 固件加载成功；Mutter 使用 `/dev/dri/card0` 和硬件 EGL 上下文 |
| 背光与合盖 | EC 背光和 eDP AUX 背光节点存在，EC Lid 输入设备已注册 |
| 触控与手写笔 | Goodix GT7380 被识别为内部触控屏，独立 Stylus 输入设备存在 |
| 按键与耳机检测 | 电源键、音量键和耳机插孔输入设备已注册 |
| UFS | 内部 UFS 及其 Windows NTFS 分区正常枚举，识别容量约 232.7 GiB |
| SD 卡 | 约 58.2 GiB exFAT SD 卡可挂载 |
| USB-C 主机模式 | Type-C 端口当前为 data-role host，可枚举 USB 设备 |
| 电池与温度 | Planck EC 电池状态可用；22 个热区均可读取且温度合理 |
| 蓝牙 | WCN3990 蓝牙控制器启动成功，实际扫描到附近 BLE 设备 |
| 视频编解码 | Venus 编码器提供 H.264、VP8、HEVC 接口，解码器提供 NV12 等格式接口 |

`/dev/video0` 和 `/dev/video1` 是 Venus 编解码设备，不代表摄像头已经可用。

### 部分可用或存在故障

| 功能 | 当前状态 |
|---|---|
| Wi-Fi | WCN3990 可连接热点、访问 HTTPS；但日志记录到两次 `ath10k_snoc` 固件崩溃并恢复，本次测试链路对公网 ICMP 约有 30% 丢包，稳定性不足 |
| 音频 | WCD9340、SDM845 声卡和 DSP 驱动已加载，但 PipeWire 仅暴露 `Dummy Output`；切换到 Pro Audio profile 后仍没有扬声器、耳机或麦克风节点，缺少可用 UCM/路由配置 |
| CPU 调频 | `qcom-cpufreq-hw` 注册失败，未生成 cpufreq policy；Linux 侧动态频率调节不可用 |
| 蜂窝网络 | 基带可由 QMI 查询，但当前处于关机模式，SIM 报 `no-atr-received` 且未注册网络；运行日志还提示缺少 MCFG 配置数据 |
| USB 以太网 | `r8152` 和 `cdc_ether` 驱动已包含；日志提示缺少 `rtl_nic/rtl8153b-2.fw`，部分 RTL8153B 网卡可能工作不稳定 |

### 没有驱动或尚未实现

| 硬件 | 当前状态 |
|---|---|
| 前后摄像头 | 设备树记录了 Samsung S5K3L6、GalaxyCore GC5025 和 CN3927E 对焦马达，但传感器节点仍为注释状态；系统没有 Media Controller 或摄像头 V4L2 设备 |
| 指纹识别 | ACPI 声明 ELAN7002/GXFP61A2 指纹模块，但当前没有对应 SPI 设备、`spidev` 或指纹驱动 |
| 方向与运动传感器 | IIO 中只有 PMIC ADC，没有加速度计、陀螺仪或方向传感器节点，自动旋转不可用 |
| 物理键盘与触控板 | 当前输入设备中未发现普通物理键盘或触控板；本次测试时键盘盖未连接，因此不能据此判断蓝牙或底座驱动是否可用 |

### 尚未验证

- 合盖进入 sleep 以及 `s2idle` 的唤醒路径；本次为避免中断 SSH 会话，没有触发休眠。
- USB-C 充电与 USB-PD 协商；本次测试时没有接入充电器，启动日志曾出现一次 UCSI 线缆属性查询超时。
- USB-C DisplayPort Alt Mode 外接显示；本次没有连接显示器或转换器。
- 蓝牙设备配对、A2DP 音频和 BLE 数据传输；本次只验证了控制器启动与扫描。
- 物理触摸、手写笔压感、亮度热键以及合盖事件的交互结果；本次只验证了设备注册。

最小复测入口：

```bash
uname -a
tr -d '\0' </proc/device-tree/model
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
for d in /sys/class/drm/card*/status; do cat "$d"; done
wpctl status
bluetoothctl show
v4l2-ctl --list-devices
for z in /sys/class/thermal/thermal_zone*; do
  printf '%s %s\n' "$(cat "$z/type")" "$(cat "$z/temp")"
done
sudo dmesg -T --level=err,warn
```

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

建议在 Ubuntu 24.04 x86_64、至少 8 GiB 内存的干净环境构建；两个内核变体、八个
flavor 加源码缓存建议准备约 90 GiB 空间。安装宿主依赖并按下面的分阶段流程运行：

```bash
sudo apt-get update
sudo apt-get install --yes --no-install-recommends \
  bc bison build-essential ca-certificates cpio curl device-tree-compiler \
  dirmngr dosfstools e2fsprogs file flex gcc-aarch64-linux-gnu gdisk git gnupg \
  kmod libarchive-tools libelf-dev libssl-dev mtools patch qemu-user-static \
  rsync squashfs-tools xorriso zstd

for variant in stock planck; do
  sudo KERNEL_VARIANT="${variant}" STAGE=kernel CLEAN_INTERMEDIATES=1 \
    bash scripts/build.sh
done

# 每个内核变体分别生成四个桌面 flavor，工作目录按变体隔离。
for variant in stock planck; do
  for flavor in minimal kde gnome xfce; do
    sudo KERNEL_VARIANT="${variant}" STAGE=media CLEAN_INTERMEDIATES=1 \
      LIVE_FLAVOR="${flavor}" bash scripts/build.sh
  done
done

(cd out && sha256sum --check SHA256SUMS-stock)
(cd out && sha256sum --check SHA256SUMS-planck)
```

只构建某个变体或桌面时，显式设置 `KERNEL_VARIANT=stock|planck` 与
`LIVE_FLAVOR=minimal|kde|gnome|xfce`。

构建脚本需要 root 执行。不要在不受信任的 fork 上用 sudo 执行。

## GitHub Actions 与静态检查

- `validate.yml` 运行 `scripts/validate.sh`，检查 Shell 语法、ShellCheck、workflow YAML/actionlint、来源锁、配置、设备树以及预期文件；也可检查已构建 EFI 的 AA64 PE/COFF 架构。
- `build.yml` 使用 `stock` / `planck` 矩阵并行构建两个内核，每个变体都生成四个桌面 flavor。
  内核缓存键包含变体、配置及 Planck 补丁哈希，并按变体独立缓存。
  **不再使用 `actions/upload-artifact`（它总会打包成 zip）**，而是把 `out/` 下每个产物
  逐个作为独立 Release asset 直接上传：`v*` tag 构建发布对应正式 Release，`main` 构建
  更新滚动预发布 `latest`，PR 构建只校验不上传。

安装 ShellCheck、Ruby、actionlint 等验证工具后运行：

```bash
STRICT_TOOLS=1 bash scripts/validate.sh
AA64_EFI_PATH=.work/planck/boot/BOOTAA64.EFI KERNEL_VARIANT=planck \
  STRICT_TOOLS=1 bash scripts/validate.sh
```

第二条命令需要已生成的 EFI 文件。静态检查不等同于完整镜像构建或目标设备启动测试。

## 写入与启动

先验证校验和，再确认写入目标是**整个可移动设备**。将 `/dev/sdX` 替换为正确设备；写错目标会破坏数据，绝不能指向内部 UFS/NVMe：

```bash
sha256sum --check SHA256SUMS-planck
zstd -dc matebook-e2019-archlive-7.3.5-planck.img.zst \
  | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync
sync
```

写入前备份内部存储与恢复资料，并在设备固件设置中关闭 Secure Boot，选择 USB 的 AA64 UEFI 启动项。Live 用户为 `live`，密码为 `live`，wheel/sudo 无密码；root 密码锁定，`sshd` 默认禁用。该弱密码只适合临时、受控的 Live 环境。系统默认不安装到内部 UFS，但 root 用户仍可手动破坏磁盘。

## 已知风险与许可

- 本项目处于实验阶段；当前真机检测已确认部分功能，但显示、输入、无线、音频、休眠等仍需按构建版本持续回归；
- 上游 ALARM 滚动软件包、dracut、GRUB AA64 与 qemu-user-static 可能发生接口变化；
- 构建并不自动代表介质已经过真机启动测试。

本仓库自有脚本和文档采用 MIT License。Linux 内核、Arch Linux ARM 包及设备固件分别受其各自许可约束；使用者和构建者应自行确认使用及分发权限。
