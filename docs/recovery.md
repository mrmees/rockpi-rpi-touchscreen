# SSH and offline recovery

Use HDMI as a recovery display when it remains available. A missing or failed
panel component can keep the shared Rockchip DRM master waiting, so HDMI may
also be unavailable. Keep SSH or a serial console available and inspect the
boot checks documented in the
[README](../README.md#first-authorized-production-boot-hardware-checkpoint). If those paths are not
available, use the offline project-token removal below.

These procedures are scoped recovery operations; they do not authorize an
automatic reboot, shutdown, display-layout change, or Xorg edit. DKMS 0.2.5
hardware acceptance remains pending until the separately authorized reboot,
HDMI hot-plug and layout, physical touch, persistent-log, and later
shutdown/cold-start checks pass.

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

Then run the exact scoped SSH rollback. It removes the project DTBO, DKMS 0.2.5
source and exact three modules, owned runtime assets, and `user_overlays` token:

Exact scoped SSH rollback command: `sudo sh scripts/uninstall.sh`.

```sh
sudo sh scripts/uninstall.sh
```

Rollback removes only project-owned assets: the overlay token, DTBO, DKMS package, and matching runtime files. It does not remove unrelated overlays or
alter the HDMI Xorg configuration. The
single `rockpi-rpi-touchscreen/0.2.5` package owns
`rockpi_rk3399_display_compat`, `panel_rockpi_rpi_touchscreen`, and
`raspits_ft5426`. Uninstalling it does not edit
`/etc/X11/xorg.conf.d/20-dfrobot-display.conf`.

## Runtime asset ownership and dry-run output

The package also owns the matching mode-0755 mapper at
`/usr/libexec/rockpi-rpi-touchscreen-map-touch` and matching mode-0644 XDG
entry at
`/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop`. Ownership
requires the installed bytes, regular-file type, and mode to match the immutable
0.2.5 source. The uninstaller removes an owned match, ignores an absent path,
and retains any changed bytes, mode, type, or symlink without overwriting it.

Dry-run output is predictive and makes no changes. An owned path is printed as
`REMOVE: exact-path`; a changed path is printed exactly as:

```text
RETAIN MODIFIED: /usr/libexec/rockpi-rpi-touchscreen-map-touch
RETAIN MODIFIED: /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
```

During a real uninstall, matching assets are snapshotted and claimed in
dependency order: autostart first, then mapper. A modified or newly appeared
autostart is retained, and its matching mapper is retained with
`RETAIN DEPENDENCY` so the entry is not stranded without its executable. A
modified mapper may be retained while an otherwise owned autostart is removed.
Every claim is revalidated so a concurrent local replacement is retained, not
deleted. A late failure restores exact bytes and modes without overwriting a
concurrent replacement. If a claim, dependency restoration, or rollback cannot
be verified, uninstall fails closed, names the retained transaction recovery
directory, and leaves it for manual reconciliation.

The original `armbianEnv.txt` backup created by the installer is kept beside
the configuration with a timestamp and `.sha256` checksum.

## Multiple DKMS kernel tuples

The transactional online uninstaller supports either no registered
`rockpi-rpi-touchscreen/0.2.5` package or exactly one `added`, `built`, or
`installed` lifecycle tuple for the running kernel and architecture. If this
command lists more than one line, or a tuple for another kernel or
architecture, the uninstaller stops before changing the boot configuration,
DTBO, source, or modules:

```sh
dkms status -m rockpi-rpi-touchscreen -v 0.2.5
```

To complete an intentional uninstall, remove each non-running-kernel tuple
explicitly, substituting the `KERNEL` and `ARCH` printed by `dkms status`:

```sh
sudo dkms remove -m rockpi-rpi-touchscreen -v 0.2.5 -k KERNEL -a ARCH
```

Stop if any removal fails and retain
`/usr/src/rockpi-rpi-touchscreen-0.2.5`; use `dkms status` to reconcile that
tuple before continuing. Once status shows only the running kernel's exact
tuple, rerun `sudo sh scripts/uninstall.sh`. If display recovery is urgent,
remove only the overlay token with the offline procedure instead and leave all
DKMS source and tuples in place for later reconciliation.

## Offline rollback

If neither display works, use a separately powered-down system and mount the
Rock Pi system storage on another Linux system. `TARGET_ROOT` is the mounted system root containing
`boot/armbianEnv.txt`; for example, if the mounted configuration is
`/mnt/rockpi/boot/armbianEnv.txt`, use `TARGET_ROOT=/mnt/rockpi`. Then run this
repository's uninstaller from the host:

```sh
sudo sh scripts/uninstall.sh --offline-boot-root TARGET_ROOT
```

This exact scoped offline rollback changes only `TARGET_ROOT/boot/armbianEnv.txt`:
it does not call DKMS and does not remove files from the host. It will remove the `rockpi-4b-plus-rpi-touchscreen` token from `user_overlays` while retaining unrelated overlay tokens. If the script is unavailable, edit that one line
carefully and remove the `rockpi-4b-plus-rpi-touchscreen` token from
`user_overlays`; do not delete unrelated names or the entire line.

Exact scoped offline rollback changes only `TARGET_ROOT/boot/armbianEnv.txt`, does not call DKMS, and does not remove host files.

Unmount the boot filesystem cleanly, reconnect HDMI if needed, and boot before
attempting the DSI wiring again. Do not use the touchscreen as the only
recovery path until the hardware checkpoint is complete.
