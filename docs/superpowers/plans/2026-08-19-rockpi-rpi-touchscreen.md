# Rock Pi 4B+ Raspberry Pi Touch Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, install, and document safe DSI video and five-point touch support for the original Raspberry Pi 7-inch Touch Display on a Rock Pi 4B+ running Armbian.

**Architecture:** A board-specific device-tree overlay connects the upstream Raspberry Pi panel driver to RK3399 DSI and declares the interrupt-less FT5426 touch controller. A small GPL-2.0 DKMS driver polls and parses touch frames, while idempotent scripts validate all artifacts against the running kernel and DTB before changing boot state.

**Tech Stack:** Linux kernel module C, DKMS, Device Tree Compiler, POSIX shell, C protocol unit tests, Armbian U-Boot overlays.

**Spec:** `docs/superpowers/specs/2026-08-19-rockpi-rpi-touchscreen-design.md`

## Global Constraints

- Target `radxa,rockpi4b-plus`, initially kernel `6.18.43-current-rockchip64`.
- Support the original 800x480 display, panel I2C `0x45`, touch I2C `0x38`.
- Poll touch because the connector does not route its interrupt.
- Preserve HDMI and `/etc/X11/xorg.conf.d/20-dfrobot-display.conf` unchanged.
- Stop before boot mutation if any module or overlay validation fails.
- Provide SSH and offline rollback; preserve GPL-2.0 attribution.

---

### Task 1: Safe polling touch driver and protocol tests

**Files:**
- Create: `src/ft5426_protocol.h`
- Create: `src/raspits_ft5426.c`
- Create: `tests/test_protocol.c`
- Create: `Makefile`
- Create: `dkms.conf`
- Create: `LICENSES/GPL-2.0-only.txt`
- Create: `LICENSE`

**Interfaces:**
- Consumes: FT5426 I2C registers `0x02` through `0x20`.
- Produces: `ft5426_parse_frame()`; `raspits_ft5426.ko`; a five-slot input device named `Raspberry Pi 7-inch Touchscreen`.

- [ ] **Step 1: Write the failing portable parser test**

Create `tests/test_protocol.c`, define userspace `u8`/`u16`, include the
protocol header, and test literal two-contact data:

```c
static void test_two_contacts(void)
{
    const u8 raw[] = { 2,
        0x01, 0x23, 0x14, 0x56, 0, 0,
        0x82, 0x34, 0x27, 0x89, 0, 0 };
    struct ft5426_frame out = {0};
    assert(ft5426_parse_frame(raw, sizeof(raw), &out) == 0);
    assert(out.count == 2);
    assert(out.points[0].id == 1 && out.points[0].x == 0x123);
    assert(out.points[0].y == 0x456 && out.points[0].active);
    assert(out.points[1].id == 2 && out.points[1].x == 0x234);
    assert(out.points[1].y == 0x789 && out.points[1].active);
}
```

Also test a truncated frame, count above five, ID above fourteen, and x/y
outside 800x480.

- [ ] **Step 2: Confirm RED**

Run `cc -std=c11 -Wall -Wextra -Werror -I. tests/test_protocol.c -o /tmp/test_ft5426`.
Expected: missing `src/ft5426_protocol.h` failure.

- [ ] **Step 3: Implement the bounded parser**

Create `src/ft5426_protocol.h` with constants for five points, 800x480, and
six bytes per point, plus:

```c
struct ft5426_point { u16 x, y; u8 id; bool active; };
struct ft5426_frame {
    u8 count;
    struct ft5426_point points[FT5426_MAX_POINTS];
};
static inline int ft5426_parse_frame(const u8 *frame, size_t len,
                                     struct ft5426_frame *out);
```

The implementation masks count to four bits, validates total length before
access, decodes event/x/y/id, accepts events 0 and 2 as active, rejects IDs
above fourteen and coordinates outside 800x480, and zeroes output first.

- [ ] **Step 4: Confirm GREEN**

Compile and run `/tmp/test_ft5426`; expect exit 0 and
`PASS: FT5426 protocol parser`.

- [ ] **Step 5: Establish the failing module build**

Run `make KDIR=/lib/modules/$(uname -r)/build modules`.
Expected: missing module source/target. If headers are absent, install the
matching Armbian headers and repeat until failure is specifically missing
production code.

- [ ] **Step 6: Implement the current-kernel polling driver**

Use this lifecycle:

```c
struct raspits_ft5426 {
    struct i2c_client *client;
    struct input_dev *input;
    struct delayed_work poll_work;
    unsigned long active_ids;
    bool stopping;
};
static void raspits_poll(struct work_struct *work);
static int raspits_probe(struct i2c_client *client);
static void raspits_remove(struct i2c_client *client);
static const struct of_device_id raspits_of_match[] = {
    { .compatible = "raspits_ft5426" }, { }
};
MODULE_DEVICE_TABLE(of, raspits_of_match);
```

Probe reads firmware registers `0xa6`, `0xb2`, `0xb3`, allocates five
`INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED` slots, registers 800x480 bounds,
and schedules delayed work. Poll reads status plus contacts in one bounded
transaction, parses, reports/releases slots, calls `input_mt_sync_frame()`
and `input_sync()`, then reschedules after 17 ms. Remove sets `stopping` and
calls `cancel_delayed_work_sync()`. Use managed allocations and no duplicate
input-device free.

Create a module Makefile and DKMS package `rockpi-rpi-touchscreen` version
`0.1.1`, module name `raspits_ft5426`, destination `/updates/dkms`.

- [ ] **Step 7: Verify module build and metadata**

Run:

```bash
make clean
make KDIR=/lib/modules/$(uname -r)/build W=1 modules
modinfo ./raspits_ft5426.ko
```

Expect no errors and metadata containing GPL v2, the OF alias, and running
kernel vermagic.

- [ ] **Step 8: Commit**

```bash
git add src tests/test_protocol.c Makefile dkms.conf LICENSE LICENSES
git commit -m "feat: add safe FT5426 polling driver"
```

---

### Task 2: RK3399 DSI overlay and merged-tree integration

**Files:**
- Create: `overlays/rockpi-4b-plus-rpi-touchscreen.dts`
- Create: `tests/test_overlay.sh`

**Interfaces:**
- Consumes: active DTB symbols `mipi_dsi1`, `mipi1_in_vopl`, `mipi1_in_vopb`, `vopl_out_mipi1`, and `i2c1`.
- Produces: `build/rockpi-4b-plus-rpi-touchscreen.dtbo` and a test-only merged DTB.

- [ ] **Step 1: Write the failing overlay integration test**

Create `tests/test_overlay.sh`. Use `mktemp -d` and a trap, compile with
`dtc -@`, apply with `fdtoverlay` to the exact active DTB, decompile, and
assert within named nodes: DSI1 is okay, panel `0x45` and touch `0x38` exist,
the little-VOP graph connects to DSI1, and HDMI remains okay. Extract each
node before matching so strings elsewhere cannot create a false pass.

- [ ] **Step 2: Confirm RED**

Run `sh tests/test_overlay.sh`.
Expected: missing overlay source failure.

- [ ] **Step 3: Implement the mainline-compatible overlay**

The overlay must leave the unused `&mipi_dsi` (DSI0) disabled, enable
`&mipi_dsi1`, connect a new DSI1 output endpoint to an I2C1 panel node, and
select little VOP. Enabling the unconnected DSI0 host blocks the shared
Rockchip DRM component master and takes HDMI down with it:

```dts
&i2c1 {
    status = "okay";
    panel@45 {
        compatible = "raspberrypi,7inch-touchscreen-panel";
        reg = <0x45>;
        port { panel_in_dsi: endpoint {
            remote-endpoint = <&dsi_out_panel>;
        }; };
    };
    touchscreen@38 {
        compatible = "raspits_ft5426";
        reg = <0x38>;
        touchscreen-size-x = <800>;
        touchscreen-size-y = <480>;
    };
};
&mipi1_in_vopb { status = "disabled"; };
&mipi1_in_vopl { status = "okay"; };
&vopl_out_mipi1 { status = "okay"; };
```

Use only dual-DSI properties supported by this kernel's binding; do not copy
obsolete downstream properties merely because Radxa's old overlay had them.

- [ ] **Step 4: Confirm GREEN**

Run `sh tests/test_overlay.sh`; expect PASS for compile, apply, routing,
panel, touch, and preserved HDMI.

- [ ] **Step 5: Commit**

```bash
git add overlays tests/test_overlay.sh
git commit -m "feat: add Rock Pi 4B+ touchscreen overlay"
```

---

### Task 3: Transactional install and rollback tooling

**Files:**
- Create: `scripts/common.sh`
- Create: `scripts/install.sh`
- Create: `scripts/uninstall.sh`
- Create: `scripts/validate.sh`
- Create: `tests/test_scripts.sh`

**Interfaces:**
- Consumes: repository root, active DTB, `/boot/armbianEnv.txt`, DKMS, root.
- Produces: installed DKMS package, user DTBO, exact overlay token, backup, reversible uninstall.

- [ ] **Step 1: Write failing sandboxed lifecycle tests**

Point scripts at a temporary root using `BOOT_DIR`, `DKMS_TREE`, and
`MODULES_DIR`. Start with `user_overlays=spi-test` and assert: install adds
the project token once; unrelated text is preserved; second install is
byte-identical; uninstall removes only the project token; failed validation
does not mutate boot config; backup checksum equals the original.

- [ ] **Step 2: Confirm RED**

Run `sh tests/test_scripts.sh`.
Expected: missing `scripts/install.sh` failure.

- [ ] **Step 3: Implement shared primitives**

In `scripts/common.sh`, implement `die`, `require_command`, `require_root`,
`active_dtb`, `add_overlay_token`, and `remove_overlay_token`. Treat
`user_overlays` as exact whitespace-separated tokens, preserve order, and
write via a temporary file plus atomic `install`.

- [ ] **Step 4: Implement offline validation**

`scripts/validate.sh --offline` verifies board compatible, headers, module
build and metadata, required DTB symbols, overlay compile/apply, merged
DSI/panel/touch nodes, and unchanged HDMI. Print one PASS per boundary.

- [ ] **Step 5: Implement transactional installation**

Validate first. Install source at `/usr/src/rockpi-rpi-touchscreen-0.1.1`,
run `dkms add/build/install`, install DTBO mode 0644, back up and checksum
`armbianEnv.txt`, then atomically add the token. A trap restores boot config
and removes newly added project assets after any post-backup failure.

- [ ] **Step 6: Implement scoped uninstall and dry run**

Dry-run prints exact owned paths and resulting overlay line. Normal mode
removes only the project token, DTBO, DKMS registration, and its `/usr/src`
tree.

- [ ] **Step 7: Confirm GREEN**

Run `sh tests/test_scripts.sh` and `sudo sh scripts/validate.sh --offline`.
Expect all sandbox and offline boundaries PASS.

- [ ] **Step 8: Commit**

```bash
git add scripts tests/test_scripts.sh
git commit -m "feat: add transactional install and rollback tooling"
```

---

### Task 4: Documentation, system install, and shutdown handoff

**Files:**
- Create: `README.md`
- Create: `docs/wiring.md`
- Create: `docs/recovery.md`
- Create: `tests/test_docs.sh`
- Modify: system only through `scripts/install.sh`

**Interfaces:**
- Consumes: tested artifacts from Tasks 1-3.
- Produces: operator documentation and installed, hardware-pending support.

- [ ] **Step 1: Write failing documentation acceptance test**

Check that local links resolve and docs state: power off before FFC insertion;
GPIO 2 or 4 is 5 V and GPIO 6 is ground; follow Radxa's FFC orientation;
remove the user overlay token for offline recovery; Touch Display 2 is not
supported; hardware validation remains pending.

- [ ] **Step 2: Confirm RED**

Run `sh tests/test_docs.sh`.
Expected: missing README/operator docs failure.

- [ ] **Step 3: Write documentation**

Cover supported hardware/kernel, architecture, attribution, dependencies,
install/uninstall, cable/GPIO wiring, HDMI coexistence, first-boot journal,
DRM/I2C/libinput checks, brightness, rotation, limitations, and SSH/offline
recovery.

- [ ] **Step 4: Verify the complete repository**

Run:

```bash
make test
sudo sh scripts/validate.sh --offline
git diff --check
```

Expect all protocol, module, overlay, lifecycle, docs, and integration tests
PASS, with no whitespace errors.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md docs/wiring.md docs/recovery.md tests/test_docs.sh Makefile
git commit -m "docs: add installation wiring and recovery guide"
```

- [ ] **Step 6: Install through the tested entry point**

Run `sudo sh scripts/install.sh`. Expect DKMS, DTBO, backup, and overlay-token
success without modification of the HDMI Xorg file.

- [ ] **Step 7: Verify installed state before shutdown**

Run:

```bash
dkms status | grep rockpi-rpi-touchscreen
modinfo raspits_ft5426
sudo sh scripts/validate.sh --offline
sudo sh scripts/uninstall.sh --dry-run
grep '^user_overlays=' /boot/armbianEnv.txt
sha256sum /boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
git status --short
```

Expect DKMS installed for this kernel, valid metadata, all offline checks
passing, one overlay token, readable backup/DTBO, and clean repository.

- [ ] **Step 8: Stop at the hardware checkpoint**

Do not reboot automatically. The branch may be pushed first when clearly
labeled draft and hardware-unverified. Give the user the shutdown and wiring
sequence. After connection and boot, run the spec's journal, DRM, I2C, and
libinput checks before claiming hardware support.
