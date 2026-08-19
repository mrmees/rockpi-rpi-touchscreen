# Rock Pi 4B+ Raspberry Pi Touch Display Design

## Goal

Enable the original 800x480 Raspberry Pi 7-inch Touch Display, including
touch input, on a Rock Pi 4B+ running Armbian's current RK3399 kernel. Keep
the existing HDMI output available as a recovery path and package the work
as a reusable GitHub repository.

## Constraints

- Target board: Radxa Rock Pi 4B+ (`radxa,rockpi4b-plus`).
- Initial target kernel: `6.18.43-current-rockchip64`.
- Display: original Raspberry Pi 7-inch Touch Display, not Touch Display 2.
- The display connects through the board's 15-pin, two-lane MIPI DSI port.
- The panel controller is at I2C address `0x45`; touch is at `0x38`.
- The touch controller has no interrupt routed through this connector, so
  the upstream interrupt-driven FT5x06 driver is not usable.
- HDMI must remain enabled and the existing DFRobot HDMI configuration must
  not be modified.
- Installation must be reversible without a working local display.

## Repository Layout

The repository will contain:

- `src/raspits_ft5426.c`: maintained polling touchscreen driver.
- `dkms.conf` and `Makefile`: DKMS and direct kernel-module builds.
- `overlays/rockpi-4b-plus-rpi-touchscreen.dts`: board-specific overlay.
- `scripts/install.sh`: validated, idempotent installation.
- `scripts/uninstall.sh`: full removal and boot-config restoration.
- `scripts/validate.sh`: offline build and merged-device-tree checks.
- `tests/`: driver build and overlay integration checks.
- `README.md`: hardware wiring, installation, verification, and recovery.
- `LICENSES/` or SPDX metadata preserving upstream licensing and attribution.

## Touch Driver

The driver will be derived from Radxa's GPL-2.0 polling driver but adapted
for current kernels and safe lifecycle management:

- Bind to the device-tree compatible string `raspits_ft5426` at `0x38`.
- Poll touch state using cancellable delayed work at approximately 60 Hz.
- Support five multitouch slots and standard Linux input events.
- Use managed allocation where appropriate and deterministic cleanup.
- Stop polling synchronously during removal and shutdown.
- Validate touch-count and finger-ID values before indexing arrays.
- Avoid repeated logging during normal polling or when no touch is present.
- Fail probe cleanly when the controller is absent or unreadable.
- Release active slots after three consecutive poll read or parse failures.
- Expose 800x480 coordinate bounds; rotation remains a userspace concern.

DKMS will rebuild the module after compatible kernel upgrades. A failed DKMS
build must not prevent the system from booting or affect HDMI.

## Device-Tree Overlay

The overlay will use symbols exported by the installed Rock Pi 4B+ DTB:

- Enable the RK3399 MIPI DSI blocks needed by the physical connector.
- Route the little VOP endpoint to the active DSI host.
- Add the upstream `raspberrypi,7inch-touchscreen-panel` device at I2C
  address `0x45` and connect its graph endpoint to DSI output.
- Add the polling touch device at I2C address `0x38`.
- Preserve the HDMI controller and its VOP routes.

The overlay source will be compiled with `dtc -@`. `fdtoverlay` will apply
the resulting DTBO to a copy of the exact active base DTB. Tests will inspect
the merged tree for enabled DSI nodes, both I2C devices, the 800x480 panel
route, and unchanged HDMI status.

## Installation and Rollback

The installer will:

1. Check the board compatible string, required tools, active kernel headers,
   overlay symbols, and boot paths.
2. Build and install the DKMS module.
3. Compile and validate the overlay against the active DTB.
4. Back up `/boot/armbianEnv.txt` with a timestamp and checksum.
5. Install the DTBO under `/boot/overlay-user/`.
6. Add the overlay name to `user_overlays` without removing existing entries.
7. Regenerate initramfs only if module policy requires it.
8. Print wiring, shutdown, first-boot verification, and rollback commands.

The uninstaller will remove only assets owned by this project and restore the
overlay list without disturbing unrelated overlays. A documented offline
rollback will explain how to edit `armbianEnv.txt` from another Linux system
if local displays fail.

## Testing

Before installation:

- Compile the module against the running kernel headers with warnings treated
  as errors where practical.
- Run source-level lifecycle and bounds checks specific to the polling loop.
- Compile the overlay without warnings.
- Apply it to the exact active DTB and inspect the merged result.
- Confirm HDMI remains enabled in the merged tree.

After installation but before shutdown:

- Verify DKMS status, module metadata, installed DTBO checksum, boot entry,
  backup readability, and uninstall dry-run output.
- Re-run the complete offline validation suite.

After connecting the display while powered off:

- Verify panel and touch-controller I2C probes in the boot journal.
- Verify a DSI DRM connector with an active 800x480 mode.
- Verify a five-slot input device and touch coordinates with `libinput`.
- Verify HDMI still works when connected.
- Test one reboot and one shutdown/start cycle.

Hardware-dependent checks will remain explicitly unverified until the panel
is connected.

## Failure Handling

- Missing panel: module probe fails cleanly; HDMI remains the recovery output.
- Overlay validation failure: installer stops before changing boot config.
- DKMS build failure: installer stops before changing boot config.
- First boot failure: remove the user overlay entry using SSH, serial console,
  or by mounting the boot filesystem elsewhere.
- Kernel upgrade incompatibility: DKMS reports failure while the prior module
  and HDMI boot path remain recoverable.

## Publication

The local repository will use small, reviewable commits. It may be published
after offline tests pass if clearly labeled draft and hardware-unverified.
Publication will include source attribution, limitations, supported
board/kernel versions, and reproducible install/uninstall steps; hardware
support will not be called complete until the physical checks pass.
