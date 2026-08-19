# Rock Pi 4B+ Raspberry Pi Touch Display

This project enables the **original** Raspberry Pi 7-inch 800x480 Touch
Display on a Radxa Rock Pi 4B+ running Armbian
`6.18.43-current-rockchip64`. It installs a board-specific device-tree overlay
and a DKMS touchscreen driver while retaining HDMI as a recovery display.

Touch Display 2 is not supported. Hardware validation remains pending until the physical display is connected and checked.

## What is installed

- The Rock Pi MIPI DSI graph and Raspberry Pi panel controller at I2C `0x45`.
- A GPL-2.0 polling driver for the FT5426 touch controller at I2C `0x38`.
- A DKMS package named `rockpi-rpi-touchscreen` and a user overlay named
  `rockpi-4b-plus-rpi-touchscreen`.

The touch driver is derived from Radxa's GPL-2.0 polling-driver approach and
updated for current kernels. It reports five multitouch slots with 800x480
coordinate bounds; no interrupt is available through this connector. Keep the
source SPDX/license notices intact when redistributing it.

## Requirements

Use this only with a `radxa,rockpi4b-plus` device tree and the supported
kernel/header pair. The installer requires root access, DKMS, matching kernel
headers, `make`, `dtc`, `fdtoverlay`, and `modinfo`. Its warning-free module
check uses the compiler recorded by the kernel; on this image that is the
Debian `aarch64-linux-gnu-gcc` 14.2.0 toolchain.

The working HDMI configuration is intentionally outside this project's scope:
the installer does not change `/etc/X11/xorg.conf.d/20-dfrobot-display.conf`.

## Install and remove

Clone this repository on the Rock Pi, review the hardware instructions, and
run the tested entry point from the repository root:

```sh
sudo sh scripts/install.sh
```

It validates the module and merged device tree before registering DKMS,
installs the DTBO in `/boot/overlay-user/`, backs up `/boot/armbianEnv.txt`,
and appends one overlay token without removing unrelated user overlays.

Preview removal with:

```sh
sudo sh scripts/uninstall.sh --dry-run
```

Remove the managed files and token with:

```sh
sudo sh scripts/uninstall.sh
```

Read [the wiring guide](docs/wiring.md) before powering down, and keep
[the recovery guide](docs/recovery.md) available over SSH or on another
machine.

## First boot: hardware checkpoint

Do not claim hardware support from an offline validation alone. Power down,
wire the panel, then boot with HDMI available. Check the current boot's panel
and touch probes, a DSI connector/mode, both I2C addresses, and the input
device:

```sh
sudo journalctl -b -k | grep -Ei 'raspberrypi|raspits|ft5426|dsi|panel'
cat /sys/class/drm/*/status
cat /sys/class/drm/*/modes
sudo i2cdetect -y 1
libinput list-devices
```

Expect panel `0x45`, touch `0x38`, an active 800x480 DSI mode, and a
five-slot `Raspberry Pi 7-inch Touchscreen` input device. Recheck that HDMI
still works when attached. Brightness is exposed by the panel backlight under
`/sys/class/backlight/`; use a suitable desktop or `brightnessctl` to adjust
it. Rotation is a userspace display/input configuration concern, not a
device-tree or driver setting.

## Limitations

The overlay is specific to this board, connector route, and kernel/device-tree
symbols. It does not support the Touch Display 2, other Rock Pi models, or
other panels. A missing panel should leave HDMI usable, but kernel upgrades can
require a compatible compiler or overlay review. Do not publish this project
or treat it as hardware-complete until the checks above and a shutdown/start
cycle have passed.
