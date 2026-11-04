# Orange Pi 4 LTS — U-Boot UEFI 固件

把 mainline U-Boot 作为 RK3399 的平台固件（思路类似 Tow-Boot），烧进板载
eMMC。U-Boot 打开 UEFI loader / boot manager 后，可以启动
`/EFI/BOOT/BOOTAA64.EFI`（GRUB、systemd-boot、UKI 等），也兼容 extlinux。

本项目已在 Orange Pi 4 LTS（RK3399，16GB eMMC）上实际启动 Armbian 验证。
TF 卡槽损坏不影响 eMMC 启动。

## 当前状态

- U-Boot：`2026.10-rc5`
- 启动顺序：**USB → eMMC**
- 固件位置：eMMC LBA 64（`idbloader`）+ LBA 16384（`u-boot.itb`）
- 串口：UART2，`115200 8N1`
- USB：Type-C 固定为 **USB2 peripheral**，用于 ACM；Type-A host 口不受影响
- PD / DP alt mode：**关闭**（OPI4 LTS 本身是 5V 供电，不做 PD 高压）

## 启动链

```text
RK3399 BootROM
  SPI NOR (无) → eMMC → SD (坏) → USB Maskrom
        │
        └─ eMMC LBA 64: idbloader (TPL + SPL)
             └─ eMMC LBA 16384: u-boot.itb (TF-A + U-Boot + DTB)
                  └─ U-Boot bootstd
                       boot_targets = usb mmc0
                       ├─ USB: EFI/BOOT/BOOTAA64.EFI (GRUB) → kernel
                       └─ eMMC: EFI/extlinux → kernel
```

U-Boot 会把自己的控制 DTB 通过 **EFI Configuration Table** 传给 GRUB/内核。
因此 OS 里没有 `/boot/dtb` 也能启动；GRUB 的 `linux` 行不需要 `devicetree`。

## eMMC 布局

当前推荐布局（已实测）：

```text
p3: LBA 64      – 24575      12 MiB    Firmware (raw U-Boot)
p1: LBA 32768   – 1048575   496 MiB    ESP / FAT32
p2: LBA 1050624 – ...        15 GiB    rootfs
```

- `u-boot-rockchip.bin` 写在 LBA 64，占用约 9.3 MiB，落在 p3 内；
- p1 从 16 MiB 开始，不会被 U-Boot 覆盖；
- p1/p2 的编号不变，GRUB 的 `(hd0,gpt1)` 前缀不受影响。

> 如果 eMMC 的 boot 分区从 1 MiB 开始（没有给 U-Boot 留 12 MiB），
> **不要直接刷整包**：`u-boot.itb` 在 8 MiB，会落进 FAT boot 分区。

## 快速开始

### 1. 进入 Maskrom

OPI4 LTS 没有真正的 Maskrom 按键；“upgrade” 键只是 GPIO。需要短接 TF 卡座
旁边的两个测试点：

1. 断电，取出 TF 卡。
2. 用金属镊子短接两个测试点，保持。
3. 插 DC 电源，等 2–3 秒，松开镊子。
4. 用 USB-C 数据线连接电脑。
5. 检查：

```bash
lsusb | grep 2207
# 2207:330c  Fuzhou Rockchip ... RK3399 in Mask ROM mode
rkdeveloptool list
```

参考图：<http://www.orangepi.org/orangepiwiki/index.php/Orange_Pi_4_LTS#How_to_enter_MaskRom_mode>

### 2. 烧写

```bash
sudo apt install rkdeveloptool
sudo ./scripts/flash.sh
```

脚本会自动识别两种 `rkdeveloptool` 命令风格：

- Pine64/Debian 版：`list` / `boot` / `write` / `reset`
- 经典 Rockchip 版：`ld` / `db` / `wl` / `rd`

默认整包写入 LBA 64。想保留 U-Boot 环境时用分写：

```bash
sudo ./scripts/flash.sh --split
```

等价的底层命令（Pine64 版）：

```bash
sudo rkdeveloptool boot vendor/rkbin/rk3399_loader_v1.20.119.bin
sudo rkdeveloptool write 64 out/u-boot-rockchip.bin
sudo rkdeveloptool reset
```

### 3. LED 状态

固件用板载 `status_led`（GPIO0_11）做启动探针：

```text
3 短闪 + 1 长闪 → 熄灭 → 心跳
     U-Boot 正常，正在启动 OS；心跳 = Linux 已起来

3 短闪 + 1 长闪 → 常亮
     U-Boot 正常，但没有找到可启动系统

3 短闪 + 1 长闪 循环
     内核 panic / 复位
```

### 4. USB ACM

当前 DTS 已把 Type-C 从 Rockchip 的 `typec-extcon` 依赖链里摘出来：

- `dwc3` 固定 `peripheral`；
- 只用 `u2phy0_otg`，USB2 high-speed；
- `tcphy0`、`cdn_dp`、`fusb302` 关闭。

启动后板子上应出现：

```bash
ls /sys/class/udc
# fe800000.usb
```

OS 侧可以用 configfs 建 ACM：

```bash
sudo modprobe libcomposite
cd /sys/kernel/config/usb_gadget
sudo mkdir g1 && cd g1
echo 0x1d6b | sudo tee idVendor
echo 0x0104 | sudo tee idProduct
sudo mkdir -p strings/0x409 configs/c.1/strings/0x409 functions/acm.usb0
echo "OPi4LTS" | sudo tee strings/0x409/serialnumber
echo "OrangePi" | sudo tee strings/0x409/manufacturer
echo "USB Serial" | sudo tee strings/0x409/product
echo "CDC ACM" | sudo tee configs/c.1/strings/0x409/configuration
sudo ln -s functions/acm.usb0 configs/c.1/
echo fe800000.usb | sudo tee UDC
```

主机侧出现 `/dev/ttyACM0`，板子侧出现 `/dev/ttyGS0`。

## PD 与 Type-C

OPI4 LTS 官方供电是 **DC 5V/3A 或 Type-C 5V/4A**，不是 PD 高压快充。
FUSB302 主要做 CC/role/DP alt mode，不负责 9V/12V/20V。

- 不要用 PD 充电器/充电宝长时间供电，可能出现重启 loop；
- 用 DC 5V/3A 或固定 5V/4A 的 Type-C 电源；
- 当前固件关闭 PD/DP，只保留 USB2 ACM。

如果以后要做 DP alt mode，需要重新打开 `fusb302`、`tcphy0`、`cdn_dp`，
并补 Type-C mux/orientation switch 驱动；这和 USB2 ACM 是两套配置。

## 构建

要求：Linux x86_64、`aarch64-linux-gnu-` 工具链、Python 3、`swig`、`dtc`、
`bison`、`flex`、`libssl-dev`、`uuid-dev`。

```bash
sudo apt install build-essential gcc-aarch64-linux-gnu bison flex \
  python3 python3-venv swig device-tree-compiler libssl-dev uuid-dev

./scripts/build.sh
```

脚本会：

1. 下载 U-Boot `v2026.10-rc5`；
2. 覆盖 `configs/orangepi-4-lts-rk3399_defconfig` 和两个 DTS；
3. 下载 DDR blob 和 BL31（`vendor/rkbin`，已 gitignore）；
4. 构建 `u-boot-rockchip.bin`；
5. 写入 `out/` 并生成 `SHA256SUMS`。

可覆盖：

```bash
UBOOT_TAG=v2026.10-rc5 \
CROSS_COMPILE=/path/to/aarch64-linux-gnu- \
JOBS=8 \
./scripts/build.sh
```

## 安装系统时的注意事项

`armbian-install` 如果做下面任意一件事，会覆盖固件：

- 重写 GPT，把第一个分区放到 32 KiB/1 MiB/4 MiB；
- 安装/更新 bootloader 到 eMMC（写 LBA 64/16384）。

建议：

1. 安装时**跳过 “Install/Update bootloader”**；
2. 保留 `64–24575` 的 Firmware 分区；
3. 安装后检查：

```bash
sudo sgdisk -p /dev/mmcblk0
```

4. 如果 GPT 被重写，重新写 U-Boot：

```bash
sudo dd if=out/u-boot-rockchip.bin of=/dev/mmcblk0 bs=512 seek=64 conv=fsync
```

## 许可

本项目（脚本、文档、DTS 修改）使用 **GPL-3.0-or-later**，见 `LICENSE`。

第三方组件：

- U-Boot：GPL-2.0+，构建时下载；
- Armbian OPI4 LTS defconfig/DTS：GPL-2.0+ / MIT，见文件头；
- Rockchip rkbin（DDR/BL31/loader）：Rockchip 原始许可，**不包含在本仓库**，
  由构建/刷写脚本按需下载；不要当作 GPL 代码再分发。

详见 `NOTICE`。

## 参考

- U-Boot UEFI：<https://docs.u-boot.org/en/latest/develop/uefi/uefi.html>
- RK3399 boot sequence：<https://pine64.org/documentation/General/RK3399_boot_sequence>
- Tow-Boot：<https://tow-boot.org/>
- Armbian build：<https://github.com/armbian/build>
- OPI4 LTS wiki：<http://www.orangepi.org/orangepiwiki/index.php/Orange_Pi_4_LTS>
