# Final fix report

Date: 2026-08-19 (America/Chicago)

Base: `430c3c638b432408a70c7c3ebdc87a265398408d`

## Outcome

All final-review findings were addressed without reboot, shutdown, or push.
The production host was migrated through `scripts/install.sh` from owned DKMS
release 0.1.0 to immutable release 0.1.1. Hardware validation remains pending;
the branch may be published only as draft/hardware-unverified until the panel,
touch, HDMI coexistence, reboot, and cold-start checks pass.

## RED/GREEN evidence

### Driver lifecycle

RED:

```text
$ sh tests/test_driver_lifecycle.sh
FAIL: controller identification must precede input registration
```

GREEN:

```text
$ sh tests/test_driver_lifecycle.sh
PASS: driver lifecycle and persistent-error release policy
```

Probe now returns the identification I2C error before allocating/registering
the input device. Three consecutive 17 ms read/parse failures release all
active slots. `.remove` and `.shutdown` call the same synchronous stop helper.
Registers 0xb2/0xb3 and logs are named firmware minor/subminor.

### Immutable install, DTBO, rollback, uninstall, and migration

Initial RED included rejection by the old installer/fake state and later the
new source-permission regression:

```text
$ sh tests/test_scripts.sh
ERROR: DKMS package could not be added or found
...
FAIL: DKMS source root must be traversable (got: 700; expected: 755)
```

GREEN:

```text
$ sh tests/test_scripts.sh
PASS: same-version changed source is rejected
PASS: changed DTBO is transactionally refreshed
PASS: DKMS source package allowlist
PASS: rollback replacement failure preserves recovery and continues cleanup
PASS: genuine DKMS uninstall failure retains source and fails
PASS: uninstall accepts already-unregistered DKMS package
PASS: successful 0.1.0 to 0.1.1 migration
PASS: failed migration retains 0.1.0 release
PASS: transactional installer lifecycle
```

The version is 0.1.1 in `common.sh` and `dkms.conf`. Same-version installed
source must exactly match or installation fails. Source staging uses an
explicit allowlist and 0755 directory modes. The DTBO is checksum-compared,
atomically replaced, verified, and restored from an exact retained artifact on
rollback. The non-exiting atomic helper lets rollback accumulate failures and
continue cleanup. Backup checksum files name the backup itself and pass
`sha256sum -c`. Uninstall distinguishes absent registration from genuine DKMS
failure; genuine failure returns nonzero, retains source, and prints no PASS.

### Validator direct-parent and artifact replacement

RED:

```text
FAIL: disabled DSI0 was accepted by merged-tree validation
ERROR: merged DSI0 is not enabled (got missing, expected "okay")
FATAL ERROR: Couldn't open output file .../build/...dtbo: Permission denied
```

GREEN:

```text
PASS: scoped merged-tree checks and KDIR clean
PASS: status checks require the direct parent
PASS: validator atomically replaces a read-only DTBO
PASS: validation diagnostics policy
```

Status values are now read only from the direct node, so descendant properties
cannot satisfy parent assertions. Validator output is compiled privately then
atomically installed, allowing root and non-root validation runs to alternate.
`cat` and `head` are declared prerequisites.

### Attribution and documentation

Authoritative upstream history was inspected at:

`https://github.com/radxa/kernel/commit/c681d6a31c2289dbaca2e1f822bab41530fc0f68`

Immutable source URL:

`https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/input/touchscreen/raspits_ft5426.c`

The driver preserves the 2016 ASUSTek Computer Inc. and 2012–2014 Linux
Foundation notices, adds a 2026 modification notice, and remains
GPL-2.0-only. `LICENSES/UPSTREAM.md` documents the exact origin. README/spec/
plan document the failure threshold, immutable installation, migration,
hardware-pending status, and draft-before-reboot publication policy.

## Final verification

```text
$ make test
PASS: FT5426 protocol parser
PASS: driver lifecycle and persistent-error release policy
PASS: overlay compile, apply, routing, panel, touch, and HDMI checks
PASS: transactional installer lifecycle
PASS: DKMS autonomous compiler selection
PASS: validation diagnostics policy
PASS: documentation acceptance

$ make clean
$ scripts/dkms-make.sh "$(uname -r)" make KDIR="/lib/modules/$(uname -r)/build" W=1 modules
CC [M] src/raspits_ft5426.o
LD [M] raspits_ft5426.ko
(exit 0; no compiler warnings)

$ sudo sh scripts/validate.sh --offline
PASS: module build and metadata
PASS: overlay apply
PASS: HDMI unchanged
PASS: offline validation

$ sh scripts/validate.sh --offline
PASS: module build and metadata
PASS: overlay apply
PASS: HDMI unchanged
PASS: offline validation

$ git diff --check
(exit 0, no output)

$ sh -n scripts/common.sh scripts/install.sh scripts/uninstall.sh scripts/validate.sh tests/test_driver_lifecycle.sh tests/test_scripts.sh tests/test_validate.sh
(exit 0, no output)
```

The three overlay decompile diagnostics printed by `test_overlay.sh` are the
pre-existing, explicitly allowlisted warnings inherited from the stock base
DTB; strict validator tests reject any unexpected diagnostic.

## Production migration and installed state

Before migration:

```text
rockpi-rpi-touchscreen/0.1.0, 6.18.43-current-rockchip64, aarch64: installed
/usr/src/rockpi-rpi-touchscreen-0.1.0
DTBO sha256 14ce963260d82e49088ef35aa677bd7c84577b8533e885e2f4b7ac40c3bffe21
Xorg sha256 7720b05721c77a8d002e63215ba62f61559340abf28906d4fa9a7d4cb1e9ae0a
```

Migration command and result:

```text
$ sudo sh scripts/install.sh
PASS: installed rockpi-rpi-touchscreen/0.1.1 and verified module, source, and DTBO checksums
NEXT: power off; follow docs/wiring.md; boot with HDMI; run the README first-boot checks.
ROLLBACK: sudo sh scripts/uninstall.sh (or use docs/recovery.md offline).
```

Installed audit:

```text
rockpi-rpi-touchscreen/0.1.1, 6.18.43-current-rockchip64, aarch64: installed
/usr/src/rockpi-rpi-touchscreen-0.1.1 (root and subdirectories mode 0755)
old /usr/src/rockpi-rpi-touchscreen-0.1.0 absent
built module:    4b26fa87e3c1625277fb0c46fa8fc458693efb65274fce052918055d4e0bc827
installed module:4b26fa87e3c1625277fb0c46fa8fc458693efb65274fce052918055d4e0bc827
built DTBO:      14ce963260d82e49088ef35aa677bd7c84577b8533e885e2f4b7ac40c3bffe21
installed DTBO:  14ce963260d82e49088ef35aa677bd7c84577b8533e885e2f4b7ac40c3bffe21
Xorg:            7720b05721c77a8d002e63215ba62f61559340abf28906d4fa9a7d4cb1e9ae0a
user_overlays=rockpi-4b-plus-rpi-touchscreen
/boot/armbianEnv.txt.rockpi-rpi-touchscreen.20260819T220143Z.bak: OK
```

Installed `/usr/src` files, and no others:

```text
LICENSE
LICENSES/GPL-2.0-only.txt
LICENSES/UPSTREAM.md
Makefile
dkms.conf
scripts/dkms-make.sh
src/ft5426_protocol.h
src/raspits_ft5426.c
```

The protected `/etc/X11/xorg.conf.d/20-dfrobot-display.conf` hash is identical
before and after migration. No reboot, shutdown, push, or physical hardware
claim was performed.
