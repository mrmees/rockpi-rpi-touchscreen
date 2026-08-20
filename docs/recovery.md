# SSH and offline recovery

Use HDMI as a recovery display when it remains available. A missing or failed
panel component can keep the shared Rockchip DRM master waiting, so HDMI may
also be unavailable. Keep SSH or a serial console available and inspect the
boot checks documented in the
[README](../README.md#first-boot-hardware-checkpoint). If those paths are not
available, use the offline project-token removal below.

## Online rollback

Keep an SSH session open while testing DSI. From another machine, connect and
enter this repository checkout on the Rock Pi:

```sh
ssh USER@ROCK_PI
cd /path/to/rockpi-rpi-touchscreen
```

Preview the change first:

```sh
sudo sh scripts/uninstall.sh --dry-run
```

Then remove only this project's DTBO, DKMS source, and `user_overlays` token:

```sh
sudo sh scripts/uninstall.sh
```

Rollback removes only the project overlay token, DTBO, and DKMS package; it
does not remove unrelated overlays or alter the HDMI Xorg configuration. The
single `rockpi-rpi-touchscreen/0.2.0` package owns both `raspits_ft5426` and
`panel_rockpi_rpi_touchscreen`. Uninstalling it does not edit
`/etc/X11/xorg.conf.d/20-dfrobot-display.conf`.

The original `armbianEnv.txt` backup created by the installer is kept beside
the configuration with a timestamp and `.sha256` checksum.

## Multiple DKMS kernel tuples

The transactional online uninstaller supports either no registered
`rockpi-rpi-touchscreen/0.2.0` package or exactly one `added`, `built`, or
`installed` lifecycle tuple for the running kernel and architecture. If this
command lists more than one line, or a tuple for another kernel or
architecture, the uninstaller stops before changing the boot configuration,
DTBO, source, or modules:

```sh
dkms status -m rockpi-rpi-touchscreen -v 0.2.0
```

To complete an intentional uninstall, remove each non-running-kernel tuple
explicitly, substituting the `KERNEL` and `ARCH` printed by `dkms status`:

```sh
sudo dkms remove -m rockpi-rpi-touchscreen -v 0.2.0 -k KERNEL -a ARCH
```

Stop if any removal fails and retain
`/usr/src/rockpi-rpi-touchscreen-0.2.0`; use `dkms status` to reconcile that
tuple before continuing. Once status shows only the running kernel's exact
tuple, rerun `sudo sh scripts/uninstall.sh`. If display recovery is urgent,
remove only the overlay token with the offline procedure instead and leave all
DKMS source and tuples in place for later reconciliation.

## Offline rollback

If neither display works, shut down and mount the Rock Pi system storage on
another Linux system. `TARGET_ROOT` is the mounted system root containing
`boot/armbianEnv.txt`; for example, if the mounted configuration is
`/mnt/rockpi/boot/armbianEnv.txt`, use `TARGET_ROOT=/mnt/rockpi`. Then run this
repository's uninstaller from the host:

```sh
sudo sh scripts/uninstall.sh --offline-boot-root TARGET_ROOT
```

This mode changes only `TARGET_ROOT/boot/armbianEnv.txt`: it does not call
DKMS and does not remove files from the host. It will remove the `rockpi-4b-plus-rpi-touchscreen` token from `user_overlays` while retaining unrelated overlay tokens. If the script is unavailable, edit that one line
carefully and remove the `rockpi-4b-plus-rpi-touchscreen` token from
`user_overlays`; do not delete unrelated names or the entire line.

Unmount the boot filesystem cleanly, reconnect HDMI if needed, and boot before
attempting the DSI wiring again. Do not use the touchscreen as the only
recovery path until the hardware checkpoint is complete.
