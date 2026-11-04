#!/usr/bin/env bash
#
# Flash the Orange Pi 4 LTS U-Boot firmware to eMMC.
#
# The board must be in Rockchip Maskrom mode.  The OPI4 LTS has no
# Maskrom button: short the two test points near the TF slot before
# powering on.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="$ROOT/out/u-boot-rockchip.bin"
IDB="$ROOT/out/idbloader.img"
ITB="$ROOT/out/u-boot.itb"

LOADER_URL="https://dl.radxa.com/rockpi4/images/loader/rk3399_loader_v1.20.119.bin"
LOADER_SHA256="d38ed3ffb2a34626a2effdcf5c62ad8b986e14aa4b209ceabbb24494f05d9fa4"
LOADER="$ROOT/vendor/rkbin/rk3399_loader_v1.20.119.bin"

SPLIT=0
YES=0
DD_DEV=""

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  --image PATH    full image (default: out/u-boot-rockchip.bin)
  --split         write idbloader.img at LBA 64 and u-boot.itb at LBA 16384
                  (preserves the U-Boot environment; default is full image)
  --dd DEVICE     write with dd instead of rkdeveloptool (e.g. /dev/mmcblk0)
  --yes           do not ask for confirmation
  -h, --help      show this help

The board must be in Maskrom mode.  rkdeveloptool can be either the
Rockchip classic build (ld/db/wl/rd) or the Pine64/Debian build
(list/boot/write/reset); both are detected automatically.
EOF
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --split) SPLIT=1; shift ;;
        --dd) DD_DEV="$2"; shift 2 ;;
        --yes) YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[ -f "$IMAGE" ] || die "找不到镜像: $IMAGE"
[ -f "$IDB" ] && [ -f "$ITB" ] || die "缺少 out/idbloader.img 或 out/u-boot.itb"

if [ -n "$DD_DEV" ]; then
    [ -b "$DD_DEV" ] || die "$DD_DEV 不是块设备"
    cat <<EOF
即将用 dd 写入:
  镜像: $IMAGE
  设备: $DD_DEV
  偏移: 512 字节 * 64 = 32 KiB

这会覆盖目标设备前 9.3 MiB。确认 $DD_DEV 是 eMMC，不是你的系统盘。
EOF
    if [ "$YES" -ne 1 ]; then
        read -r -p "输入 YES 继续: " ans
        [ "$ans" = "YES" ] || exit 1
    fi
    dd if="$IMAGE" of="$DD_DEV" bs=512 seek=64 conv=fsync status=progress
    sync
    log "dd 完成"
    exit 0
fi

command -v rkdeveloptool >/dev/null 2>&1 || die "找不到 rkdeveloptool，请先安装"
command -v curl >/dev/null 2>&1 || die "找不到 curl"

mkdir -p "$(dirname "$LOADER")"
if [ ! -f "$LOADER" ] || ! echo "$LOADER_SHA256  $LOADER" | sha256sum -c --status; then
    log "下载 Maskrom loader"
    curl -fL --retry 3 -o "$LOADER.tmp" "$LOADER_URL"
    echo "$LOADER_SHA256  $LOADER.tmp" | sha256sum -c --status || {
        rm -f "$LOADER.tmp"
        die "loader 校验失败"
    }
    mv "$LOADER.tmp" "$LOADER"
fi

# Detect classic vs Pine64 command names.
if rkdeveloptool --help 2>&1 | grep -qE '^  write '; then
    LIST=(list)
    BOOT=(boot "$LOADER")
    WRITE_FULL=(write 64 "$IMAGE")
    WRITE_IDB=(write 64 "$IDB")
    WRITE_ITB=(write 16384 "$ITB")
    RESET=(reset)
else
    LIST=(ld)
    BOOT=(db "$LOADER")
    WRITE_FULL=(wl 0x40 "$IMAGE")
    WRITE_IDB=(wl 0x40 "$IDB")
    WRITE_ITB=(wl 0x4000 "$ITB")
    RESET=(rd)
fi

log "检测设备"
rkdeveloptool "${LIST[@]}" || true

cat <<EOF
即将写入:
  $IMAGE
  -> eMMC LBA 64 (32 KiB)
  $([ "$SPLIT" -eq 1 ] && echo '分写模式: idbloader LBA 64, u-boot.itb LBA 16384' || echo '整包模式')

请确认板子处于 Maskrom 模式，且目标 eMMC 的 64-24575 扇区是固件区。
EOF

if [ "$YES" -ne 1 ]; then
    read -r -p "输入 YES 继续: " ans
    [ "$ans" = "YES" ] || exit 1
fi

log "加载 Maskrom loader"
rkdeveloptool "${BOOT[@]}"

if [ "$SPLIT" -eq 1 ]; then
    log "写入 idbloader"
    rkdeveloptool "${WRITE_IDB[@]}"
    log "写入 u-boot.itb"
    rkdeveloptool "${WRITE_ITB[@]}"
else
    log "写入完整镜像"
    rkdeveloptool "${WRITE_FULL[@]}"
fi

log "复位"
rkdeveloptool "${RESET[@]}"
log "完成"
