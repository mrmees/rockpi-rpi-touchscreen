# Rock Pi 4B+ Raspberry Pi Touch Display

This project enables the **original** Raspberry Pi 7-inch 800x480 Touch
Display on a Radxa Rock Pi 4B+ running Armbian
`6.18.43-current-rockchip64`. It installs a board-specific device-tree overlay
and a DKMS touchscreen driver while retaining HDMI as a recovery display.

Touch Display 2 is not supported. Hardware validation remains pending until the physical display is connected and checked.

## What is installed

- The Rock Pi MIPI DSI graph and Raspberry Pi panel controller at I2C `0x45`.
- A GPL-2.0 polling driver for the FT5426 touch controller at I2C `0x38` and
  a board-specific DRM panel driver for the TC358762 bridge.
- A DKMS package named `rockpi-rpi-touchscreen` and a user overlay named
  `rockpi-4b-plus-rpi-touchscreen`.

DKMS release `0.2.0` installs two modules: `raspits_ft5426` owns touch input,
and `panel_rockpi_rpi_touchscreen` owns the original panel compatibility path.
The compatibility driver moves TC358762 initialization to panel enable, when
the RK3399 DesignWare DSI host can accept bridge commands; the upstream driver
sent those commands during panel prepare. On the previously tested boot, the
controller, backlight, touch, and 800x480 connector were detected, but the
screen remained lit black and the kernel logged eleven `failed to write
command FIFO` errors. Desktop layout changes reproduced the errors because
they could not correct this driver-lifecycle ordering.

DSI0 stays disabled; the overlay routes the little VOP only to DSI1 and leaves
HDMI enabled. The project-specific panel compatible prevents the generic
Raspberry Pi panel module from owning this RK3399-only path.

The touch driver is derived from [Radxa's exact GPL-2.0-only source at commit
`c681d6a31c2289dbaca2e1f822bab41530fc0f68`](https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/input/touchscreen/raspits_ft5426.c).
It preserves the original ASUSTek Computer Inc. and Linux Foundation notices;
see [the upstream attribution](LICENSES/UPSTREAM.md). The 2026 modifications
support current kernels, bounded parsing, and safe polling lifecycle handling.
It reports five multitouch slots with 800x480 coordinate bounds; no interrupt
is available through this connector. After three consecutive read or parse failures
(about 51 ms), it releases every active slot to prevent stuck touches.

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
Release `0.2.0` treats `/usr/src/rockpi-rpi-touchscreen-0.2.0` as immutable: a
same-version content mismatch fails instead of silently replacing registered
source. The installer checksum-compares the source, both DKMS-built/installed
modules, and DTBO. A `0.1.1` installation owned by this project is removed only
after `0.2.0`, both modules, the source, boot backup, single overlay token, and
DTBO all verify. A failed migration retains or restores the old release and
reports any recovery paths. The installer never changes
`/etc/X11/xorg.conf.d/20-dfrobot-display.conf`.

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
five-slot `Raspberry Pi 7-inch Touchscreen` input device. A successful project
panel probe should log `registered RK3399-safe Raspberry Pi touchscreen panel`;
the touch probe should log an `FT5426 firmware` line. Treat any `failed to
initialize TC358762`, `TC358762 write failed`, or `failed to write command
FIFO` line as a failed checkpoint. Recheck that HDMI still works when attached.

Brightness is exposed as 0 through 255 by the project backlight. After the
hardware checkpoint finds the device, a direct test is:

```sh
backlight=/sys/class/backlight/rockpi-rpi-touchscreen
cat "$backlight/max_brightness"
printf '%s\n' 128 | sudo tee "$backlight/brightness"
```

Display rotation and touch mapping are userspace concerns, not device-tree or
driver settings. Under an X11 session, map the touch device to DSI1 with:

```sh
touch_id=$(xinput list --id-only 'Raspberry Pi 7-inch Touchscreen')
xinput map-to-output "$touch_id" DSI-1
```

Use the desktop's display/input settings instead under Wayland. Hardware
validation remains pending until video, brightness, touch mapping, HDMI, a
reboot, and a shutdown/cold-start have all passed.

## Limitations

The overlay is specific to this board, connector route, and kernel/device-tree
symbols. It does not support the Touch Display 2, other Rock Pi models, or
other panels. A missing panel should leave HDMI usable, but kernel upgrades can
require a compatible compiler or overlay review. The repository is ready for
publication before physical validation only when clearly marked draft or hardware-unverified;
do not describe hardware support as complete until the
checks above and a shutdown/start cycle have passed.
