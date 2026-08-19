# SSH and offline recovery

HDMI remains the preferred recovery display. If the DSI panel does not boot,
use SSH or a serial console and inspect the boot checks documented in the
[README](../README.md#first-boot-hardware-checkpoint).

## Online rollback

Preview the change first:

```sh
sudo sh scripts/uninstall.sh --dry-run
```

Then remove only this project's DTBO, DKMS source, and `user_overlays` token:

```sh
sudo sh scripts/uninstall.sh
```

The original `armbianEnv.txt` backup created by the installer is kept beside
the configuration with a timestamp and `.sha256` checksum.

## Offline rollback

If neither display works, shut down and mount the Rock Pi boot filesystem on
another Linux system. Let `TARGET_ROOT` be the absolute mount root containing
`boot/armbianEnv.txt`, then run this repository's uninstaller from the host:

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
