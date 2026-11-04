# Rockchip binaries

This directory is intentionally **not** populated in git.  The files are
downloaded on demand and are **not** GPL-licensed.

`../scripts/build.sh` downloads:

| File | SHA256 |
|---|---|
| `rk3399_bl31_v1.36.elf` | `3be6cdf32462d7f676d109bb2a97af9a1f469f058674ef0a5cb20941af2923d5` |
| `rk3399_ddr_933MHz_v1.30.bin` | `aab3b04166c098c8ba1d9a734c509cdf75b47b64c37c49196c7242526ce32179` |

`../scripts/flash.sh` downloads:

| File | SHA256 |
|---|---|
| `rk3399_loader_v1.20.119.bin` | `d38ed3ffb2a34626a2effdcf5c62ad8b986e14aa4b209ceabbb24494f05d9fa4` |

Sources:

- <https://github.com/rockchip-linux/rkbin>
- <https://dl.radxa.com/rockpi4/images/loader/>

The Rockchip loader is a USB plug used only in Maskrom mode.  It is
required to make eMMC visible to `rkdeveloptool`.
