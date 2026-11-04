#!/usr/bin/env bash
#
# Build U-Boot for the Orange Pi 4 LTS (RK3399) as an EFI-capable
# platform firmware image.
#
# Tested with U-Boot v2026.10-rc5 on Debian sid x86_64.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"

UBOOT_TAG="${UBOOT_TAG:-v2026.10-rc5}"
UBOOT_COMMIT="${UBOOT_COMMIT:-a06e89ab05eaa2b8344d521319399333cd760ae5}"
RKBIN_COMMIT="${RKBIN_COMMIT:-3e288fe814e059dd06833495f845cab04ac20a5c}"

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

SRC="$BUILD_DIR/u-boot-${UBOOT_TAG#v}"
OBJ="$BUILD_DIR/obj"
VENV="$BUILD_DIR/venv"
RKBIN_DIR="$ROOT/vendor/rkbin"

BL31="$RKBIN_DIR/rk3399_bl31_v1.36.elf"
TPL="$RKBIN_DIR/rk3399_ddr_933MHz_v1.30.bin"

BL31_SHA256="3be6cdf32462d7f676d109bb2a97af9a1f469f058674ef0a5cb20941af2923d5"
TPL_SHA256="aab3b04166c098c8ba1d9a734c509cdf75b47b64c37c49196c7242526ce32179"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

need curl
need tar
need make
need python3
need sha256sum

if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
    cat >&2 <<EOF
找不到交叉编译器: ${CROSS_COMPILE}gcc

Debian/Ubuntu:
  sudo apt install gcc-aarch64-linux-gnu

或者指定工具链前缀:
  CROSS_COMPILE=/path/to/aarch64-linux-gnu- ./scripts/build.sh
EOF
    exit 1
fi

log "U-Boot:   $UBOOT_TAG ($UBOOT_COMMIT)"
log "rkbin:    $RKBIN_COMMIT"
log "交叉编译器: $(${CROSS_COMPILE}gcc --version | head -1)"
log "构建目录:  $BUILD_DIR"

mkdir -p "$BUILD_DIR" "$OUT_DIR" "$RKBIN_DIR"

# ---------------------------------------------------------------------------
# Python venv: U-Boot 2026.10 needs setuptools_scm (pylibfdt) and pyelftools
# (binman FIT generation).  Keep them out of the system Python.
# ---------------------------------------------------------------------------
if [ ! -x "$VENV/bin/python" ]; then
    log "创建 Python venv"
    python3 -m venv "$VENV"
fi
if ! "$VENV/bin/python" -c 'import setuptools_scm, elftools' >/dev/null 2>&1; then
    log "安装 Python 构建依赖 (setuptools_scm, pyelftools)"
    "$VENV/bin/pip" install --quiet --upgrade pip setuptools wheel
    "$VENV/bin/pip" install --quiet setuptools_scm pyelftools
fi
export PATH="$VENV/bin:$PATH"
export PYTHON="$VENV/bin/python"

# ---------------------------------------------------------------------------
# rkbin blobs (DDR init, BL31, Maskrom loader)
# ---------------------------------------------------------------------------
fetch_blob() {
    local name="$1" sha="$2"
    local path="$RKBIN_DIR/$name"
    if [ -f "$path" ] && echo "$sha  $path" | sha256sum -c --status; then
        return 0
    fi
    log "下载 rkbin/$name"
    curl -fL --retry 3 --connect-timeout 20 \
        -o "$path.tmp" \
        "https://raw.githubusercontent.com/rockchip-linux/rkbin/$RKBIN_COMMIT/bin/rk33/$name"
    echo "$sha  $path.tmp" | sha256sum -c --status || {
        rm -f "$path.tmp"
        die "rkbin/$name 校验失败"
    }
    mv "$path.tmp" "$path"
}

fetch_blob "rk3399_bl31_v1.36.elf" "$BL31_SHA256"
fetch_blob "rk3399_ddr_933MHz_v1.30.bin" "$TPL_SHA256"

# ---------------------------------------------------------------------------
# U-Boot source
# ---------------------------------------------------------------------------
if [ ! -f "$SRC/Makefile" ]; then
    log "下载 U-Boot $UBOOT_TAG"
    rm -rf "$SRC" "$BUILD_DIR/u-boot.tar.gz"
    curl -fL --retry 3 --connect-timeout 20 \
        -o "$BUILD_DIR/u-boot.tar.gz" \
        "https://codeload.github.com/u-boot/u-boot/tar.gz/$UBOOT_TAG"
    tar xzf "$BUILD_DIR/u-boot.tar.gz" -C "$BUILD_DIR"
    [ -f "$SRC/Makefile" ] || die "解压后找不到 $SRC/Makefile"
fi

# Optional: verify the tag resolves to the expected commit.  Tarballs do not
# carry git metadata, so this is informational only.
if [ -f "$SRC/.git" ]; then
    actual="$(git -C "$SRC" rev-parse HEAD)"
    [ "$actual" = "$UBOOT_COMMIT" ] || warn "U-Boot HEAD=$actual，期望 $UBOOT_COMMIT"
fi

# ---------------------------------------------------------------------------
# Board overlay
# ---------------------------------------------------------------------------
log "覆盖 OPI4 LTS defconfig / DTS"
install -D -m 0644 "$ROOT/configs/orangepi-4-lts-rk3399_defconfig" \
    "$SRC/configs/orangepi-4-lts-rk3399_defconfig"
install -D -m 0644 "$ROOT/dts/rk3399-orangepi-4-lts.dts" \
    "$SRC/dts/upstream/src/arm64/rockchip/rk3399-orangepi-4-lts.dts"
install -D -m 0644 "$ROOT/dts/arch/arm/dts/rk3399-orangepi-4-lts-u-boot.dtsi" \
    "$SRC/arch/arm/dts/rk3399-orangepi-4-lts-u-boot.dtsi"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
log "配置"
make -C "$SRC" O="$OBJ" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
    orangepi-4-lts-rk3399_defconfig

log "编译 (-j$JOBS)"
make -C "$SRC" O="$OBJ" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
    BL31="$BL31" ROCKCHIP_TPL="$TPL" -j"$JOBS"

for f in u-boot-rockchip.bin idbloader.img u-boot.itb u-boot.dtb; do
    [ -f "$OBJ/$f" ] || die "构建产物缺失: $OBJ/$f"
done

log "复制产物到 $OUT_DIR"
install -m 0644 "$OBJ/u-boot-rockchip.bin" "$OUT_DIR/u-boot-rockchip.bin"
install -m 0644 "$OBJ/idbloader.img"       "$OUT_DIR/idbloader.img"
install -m 0644 "$OBJ/u-boot.itb"          "$OUT_DIR/u-boot.itb"
install -m 0644 "$OBJ/u-boot.dtb"          "$OUT_DIR/u-boot.dtb"

(
    cd "$OUT_DIR"
    sha256sum u-boot-rockchip.bin idbloader.img u-boot.itb u-boot.dtb > SHA256SUMS
)

log "完成"
ls -lh "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"
