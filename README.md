# Rock Pi 4B+ Raspberry Pi Touch Display

This project enables the **original** Raspberry Pi 7-inch 800x480 Touch
Display on a Radxa Rock Pi 4B+ running Armbian
`6.18.43-current-rockchip64`. It installs a board-specific device-tree overlay
and DKMS display stack while retaining HDMI as a recovery display.

Touch Display 2 is not supported. Earlier 0.2.4 hardware work produced
user-confirmed correct RGB desktop video and physically correct touch and
identified the safe HDMI-on-VOPB, DSI-on-VOPL pairing. DKMS 0.2.5 packages that
route constraint and layout-neutral touch mapping, but its hardware acceptance
is still pending. Do not describe 0.2.5 as production-hardware-validated until
a separately authorized reboot, HDMI hot-plug and layout checks, physical touch
and log checks, and a later separately authorized shutdown/cold-start pass.

## What is installed

- The Rock Pi MIPI DSI graph and Raspberry Pi panel controller at I2C `0x45`.
- A GPL-2.0 polling driver for the FT5426 touch controller at I2C `0x38`, a
  board-specific DRM panel driver for the TC358762 bridge, and an RK3399
  display compatibility provider.
- A DKMS package named `rockpi-rpi-touchscreen` and a user overlay named
  `rockpi-4b-plus-rpi-touchscreen`.

DKMS `0.2.5` installs exactly three production modules in provider, panel, then touch order:
`rockpi_rk3399_display_compat`, `panel_rockpi_rpi_touchscreen`, and `raspits_ft5426`.
The exact migration baseline is DKMS `0.2.4` with the same three modules in that order.
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
It is not registered as a DRM output. An unsafe reversed assignment was observed with a VOP timeout and hard lock; the hard-lock mechanism itself is not proven.
DSI is constrained to VOPL by device-tree graph identity. The overlay
terminates the unsupported DSI1/VOPB graph reciprocally at a disabled
project-owned route filter, so the DSI encoder advertises only VOPL without
depending on CRTC numbering. HDMI remains free to use VOPB. The provider reads
the live GRF DSI1 route only after the CRTC is active, applies a reversible `data01_swap` and blue/green plus red/blue correction to that selected VOP, and
restores only those fields during panel disable. The provider never uses `/dev/mem` and never reads or writes the inactive VOP.
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
Release `0.2.5` treats `/usr/src/rockpi-rpi-touchscreen-0.2.5` as immutable: a
same-version content mismatch fails instead of silently replacing registered
source. The installer checksum-compares the source, all three DKMS-built and
installed modules, DTBO, and runtime assets. It accepts only the faithful exact
three-module 0.2.4 baseline and retires that baseline only after 0.2.5, all
three modules, the source, boot backup, single overlay token, DTBO, mapper, and
autostart entry verify. A failed migration retains or restores the exact prior
state and reports any recovery paths.

Release 0.2.5 owns the executable X11 mapper at
`/usr/libexec/rockpi-rpi-touchscreen-map-touch` and the system XDG autostart
entry at
`/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop`. Pre-existing
files at either path must match the packaged bytes and mode or installation
fails closed; unrelated files are never overwritten. The installer does not reboot or shut down automatically. It does not unload live diagnostic helpers
and never changes `/etc/X11/xorg.conf.d/20-dfrobot-display.conf`.

## Display layout and X11 touch mapping

Mirror or extend mode, position, primary display, and output modes remain user-configurable through normal desktop display settings.
The project installs no display-layout preset or layout command. It neither
forces a primary output nor saves an `xrandr` arrangement.

In an X11 session, the XDG entry automatically maps X11 touch to the active DSI output without changing the display layout. It runs the mapper in watch mode,
inherits the session's `DISPLAY` and `XAUTHORITY`, and remaps only after relevant
RandR layout events. Run one mapping attempt manually inside the graphical X11
session with:

```sh
/usr/libexec/rockpi-rpi-touchscreen-map-touch --once
```

The mapper requires exactly one input named `Raspberry Pi 7-inch Touchscreen`
and maps it to active output `DSI-1`. An inactive DSI output is a no-op; an
ambiguous input-device name is an error. It changes only XInput's output
mapping and never changes modes, position, primary state, CRTC assignment, or
DPMS. Wayland compositor mapping is out of scope.

To disable automatic mapping for one user, copy the system entry to the same
name at `~/.config/autostart/rockpi-rpi-touchscreen-touch-map.desktop` and add
the XDG override `Hidden=true`:

```sh
mkdir -p "$HOME/.config/autostart"
cp /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop \
  "$HOME/.config/autostart/rockpi-rpi-touchscreen-touch-map.desktop"
printf '\nHidden=true\n' >> \
  "$HOME/.config/autostart/rockpi-rpi-touchscreen-touch-map.desktop"
```

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

Task 5 performs offline validation only; it does not install, reboot, change the
live display layout, or touch boot state. After separate installation and fresh
authorization for a reboot, the 0.2.5 overlay and all three production modules
first bind on that new boot. Do not claim hardware support from offline
validation or earlier 0.2.4 evidence alone.

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
the production boot uses kernel touch orientation and must not apply a fixed
userspace 180-degree correction. The 0.2.5 mapper may set a non-identity X
Coordinate Transformation Matrix because `xinput map-to-output` derives
scaling and translation from the current desktop geometry. Verify that touch
targets DSI-1 and is physically oriented correctly; do not require a fixed
matrix:

```sh
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority \
  xinput list-props 'Raspberry Pi 7-inch Touchscreen'
```

Confirm physically correct touch and RGB panels before proceeding. In an X11
session, run `/usr/libexec/rockpi-rpi-touchscreen-map-touch --once` and confirm
the same result before and after the layout changes below.

Then follow this HDMI hot-plug sequence: keep HDMI disconnected until DSI-1 is
800x480 with correct RGB and physical touch; attach HDMI; run `xrandr --current`
again; confirm DSI advertises only its VOPL-backed CRTC and both connectors
retain independent modes and correct RGB. Use normal desktop display settings
to exercise mirror and extend, relative positions, primary selection, and
supported modes without running a project layout command. After every change,
confirm touch remains mapped to DSI-1; then recheck the protected HDMI
checksum. HDMI hot-plug and layout success are required before describing
dual-display support as accepted.

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

The production cold-start and reboot acceptance remains pending until video,
brightness, physical DSI touch mapping, HDMI hot-plug and user-selected layouts,
persistent logs, and an explicitly authorized later shutdown/cold-start have
all passed. This project never reboots or shuts down automatically.
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
