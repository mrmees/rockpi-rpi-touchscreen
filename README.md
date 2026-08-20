# Rock Pi 4B+ Raspberry Pi Touch Display

This project enables the **original** Raspberry Pi 7-inch 800x480 Touch
Display on a Radxa Rock Pi 4B+ running Armbian
`6.18.43-current-rockchip64`. It installs a board-specific device-tree overlay
and DKMS display stack while retaining HDMI as a recovery display.

Touch Display 2 is not supported. The current live diagnostic session has
user-confirmed correct RGB desktop video and physically correct touch, but that
session still uses temporary helpers and a temporary 180-degree X transform.
The production cold-start and reboot acceptance remains pending for DKMS 0.2.4;
do not describe this release as production-hardware-validated yet.

## What is installed

- The Rock Pi MIPI DSI graph and Raspberry Pi panel controller at I2C `0x45`.
- A GPL-2.0 polling driver for the FT5426 touch controller at I2C `0x38`, a
  board-specific DRM panel driver for the TC358762 bridge, and an RK3399
  display compatibility provider.
- A DKMS package named `rockpi-rpi-touchscreen` and a user overlay named
  `rockpi-4b-plus-rpi-touchscreen`.

DKMS `0.2.4` installs all three production modules:
`rockpi_rk3399_display_compat`, `panel_rockpi_rpi_touchscreen`, and `raspits_ft5426`.
The provider owns the DSI0 PLL supplier and reversible VOP correction; the panel depends on that provider; the touch module owns touch input.
More specifically, `rockpi_rk3399_display_compat` owns the disabled-DSI0 PLL
supplier and reversible VOP correction; `panel_rockpi_rpi_touchscreen` owns the
original panel compatibility path and has a hard module dependency on the
provider; and `raspits_ft5426` owns touch input. The panel defers until the
provider is ready, so it cannot bind with an unprepared PLL source.
The panel driver initializes TC358762 during panel prepare, after the
Linux 6.18 DesignWare bridge has powered the host in command mode and after the
panel-controller power wait. It sets the DRM panel's `prepare_prev_first` flag
before publishing the panel, which makes the host enter LP-11 before those
bridge commands. The prior 0.2.2 hardware attempt omitted that flag, so the
screen remained black and the command FIFO timed out before the host PHY was
ready. The touch probe defers on `-ENXIO` while panel power is unavailable and
retries through the driver core instead of permanently losing touch input.

DSI0 is disabled in the DRM graph but supplies the DSI1 PLL through the compatibility provider.
It is not registered as a DRM output. The overlay prefers the little VOP for
DSI1, but the provider reads the live GRF DSI1 route only after the CRTC is
active, so it operates on exactly the GRF-selected active VOP. It applies a
reversible `data01_swap` and blue/green plus red/blue correction, then restores
only those fields during panel disable. The provider never uses `/dev/mem` and never reads or writes the inactive VOP.
HDMI remains enabled, and the project-specific panel compatible prevents the
generic Raspberry Pi panel module from owning this RK3399-only path.

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
`/etc/X11/xorg.conf.d/20-dfrobot-display.conf` is protected, and the installer does not change it.
Record its checksum before installation and compare it
afterward:

```sh
sha256sum /etc/X11/xorg.conf.d/20-dfrobot-display.conf
```

## Install and remove

Clone this repository on the Rock Pi, review the hardware instructions, and
run the tested entry point from the repository root:

```sh
sudo sh scripts/install.sh
```

It validates the modules and merged device tree before registering DKMS,
installs the DTBO in `/boot/overlay-user/`, backs up `/boot/armbianEnv.txt`,
and appends one overlay token without removing unrelated user overlays.
Release `0.2.4` treats `/usr/src/rockpi-rpi-touchscreen-0.2.4` as immutable: a
same-version content mismatch fails instead of silently replacing registered
source. The installer checksum-compares the source, all three DKMS-built and
installed modules, and DTBO. A `0.2.3` installation owned by this project is
removed only after `0.2.4`, all three modules, the source, boot backup, single
overlay token, and DTBO all verify. A failed migration retains or restores the
old release and reports any recovery paths. The installer does not reboot or shut down automatically, does not unload the live diagnostic helpers, and never changes `/etc/X11/xorg.conf.d/20-dfrobot-display.conf`.

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

## First authorized production boot: hardware checkpoint

Do not alter the currently live helpers or temporary X transform. After source
review, installation, and fresh authorization for a reboot, the new overlay and
all three production modules first bind on that new boot. Do not claim hardware
support from offline validation or the earlier temporary-helper evidence alone.

Start the authorized boot with the Raspberry Pi display connected and HDMI
disconnected. Check the current boot's modules, panel and touch probes, a DSI
connector/mode, both I2C addresses, and the input device:

The first authorized production boot starts with HDMI disconnected: validate DSI-1, RGB, and physical touch first, then hot-plug HDMI.

```sh
lsmod | grep -E '^(rockpi_rk3399_display_compat|panel_rockpi_rpi_touchscreen|raspits_ft5426)'
sudo journalctl -b -k | grep -Ei 'raspberrypi|raspits|ft5426|dsi|panel'
cat /sys/class/drm/*/status
cat /sys/class/drm/*/modes
sudo i2cdetect -y 1
libinput list-devices
```

Expect panel `0x45`, touch `0x38`, an active 800x480 DSI mode, and a five-slot
`Raspberry Pi 7-inch Touchscreen` input device. A successful project panel
probe should log `registered RK3399-safe Raspberry Pi touchscreen panel`; the
touch probe should log an `FT5426 firmware` line. Treat any `failed to
initialize TC358762`, `TC358762 write failed`, or `failed to write command
FIFO` line as a failed checkpoint. The warning `panel ready bit did not assert; continuing after bounded wait` is advisory on the tested original panel; actual I2C read failures remain fatal.

Brightness is exposed as 0 through 255 by the project backlight. After the
hardware checkpoint finds the device, a direct test is:

```sh
backlight=/sys/class/backlight/rockpi-rpi-touchscreen
cat "$backlight/max_brightness"
printf '%s\n' 128 | sudo tee "$backlight/brightness"
```

The overlay sets both `touchscreen-inverted-x` and `touchscreen-inverted-y`, so
the production boot must use kernel touch orientation and no longer apply the
temporary userspace 180-degree correction. Do not change the current live X
session. On the production boot, verify the X Coordinate Transformation Matrix must be identity:

```sh
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority \
  xinput list-props 'Raspberry Pi 7-inch Touchscreen'
```

The matrix must be `1 0 0 0 1 0 0 0 1`; a 180-degree matrix would invert the
already inverted axes a second time. Confirm physically correct touch and RGB
panels before proceeding.

Then follow this HDMI hot-plug sequence: keep HDMI disconnected until DSI-1 is
800x480 with correct RGB and physical touch; attach HDMI; run `xrandr --current`
again; confirm both connectors retain independent modes, correct RGB, and usable
touch; finally recheck the protected HDMI checksum. HDMI hot-plug sequence
success is required before describing dual-display support as accepted.

```sh
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority xrandr --current
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority \
  xinput list-props 'Raspberry Pi 7-inch Touchscreen'
sha256sum /etc/X11/xorg.conf.d/20-dfrobot-display.conf
```

Keep persistent crash collection enabled throughout the checkpoint. Inspect
`/var/log.hdd/kernel-live.log` and `/var/log.hdd/crash-watch.log` after the
first boot and after HDMI hot-plug; neither may contain a new Oops, lockup, or
display-transfer failure:

```sh
sudo tail -n 200 /var/log.hdd/kernel-live.log
sudo tail -n 40 /var/log.hdd/crash-watch.log
```

Production cold-start and reboot acceptance remains pending until video,
brightness, identity-matrix touch, HDMI hot-plug, persistent logs, and an
explicitly authorized shutdown/cold-start have all passed. This project never
reboots or shuts down automatically.
No automatic reboot or shutdown occurs; obtain fresh authorization before any power action.

## Limitations

The overlay is specific to this board, connector route, and kernel/device-tree
symbols. It does not support the Touch Display 2, other Rock Pi models, or
other panels. A missing or disconnected panel can leave the shared Rockchip DRM
master waiting for its panel component, so HDMI is not guaranteed to remain
usable in that failure mode. Keep SSH or serial-console access available; if
neither display binds, use the offline project-token removal in
[docs/recovery.md](docs/recovery.md). Kernel upgrades can require a compatible
compiler or overlay review.

The transactional uninstaller deliberately accepts only an unregistered
package or one DKMS lifecycle tuple for the running kernel. It stops without
changing owned assets when multiple kernel tuples exist; follow the exact
per-kernel reconciliation procedure in [docs/recovery.md](docs/recovery.md)
before rerunning it. The repository is ready for publication before physical
validation only when clearly marked draft or hardware-unverified; do not
describe hardware support as complete until the checks above and a
shutdown/start cycle have passed.
