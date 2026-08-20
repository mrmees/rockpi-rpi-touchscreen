# SSH and offline recovery

HDMI remains the preferred recovery display. If the DSI panel does not boot,
use SSH or a serial console and inspect the boot checks documented in the
[README](../README.md#first-boot-hardware-checkpoint).

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
