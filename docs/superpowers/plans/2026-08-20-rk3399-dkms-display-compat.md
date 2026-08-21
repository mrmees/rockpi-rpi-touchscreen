# RK3399 DKMS Display Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the successful throwaway DSI0 PLL, active-VOP lane/color, and X touch-orientation diagnostics with a reboot-safe DKMS 0.2.4 release for the Rock Pi 4B+ and original Raspberry Pi 7-inch Touch Display.

**Architecture:** A new `rockpi_rk3399_display_compat` platform module owns the disabled DSI0 PLL supplier and reversible VOP corrections. The panel module consumes that provider at DRM enable/disable boundaries, while the touch module uses standard kernel touchscreen properties. The overlay supplies explicit phandles, and the transactional installer migrates the complete two-module 0.2.3 baseline to a three-module 0.2.4 release.

**Tech Stack:** Linux 6.18 DRM panel and Rockchip VOP/DSI registers, platform/I2C drivers, common clock/reset/regmap/device-link APIs, input touchscreen helpers, DKMS, Device Tree overlays, POSIX shell, portable C unit tests.

**Spec:** `docs/superpowers/specs/2026-08-20-rk3399-dkms-display-compat-design.md`

## Global Constraints

- Target only `radxa,rockpi4b-plus` with the original 800x480 Raspberry Pi Touch Display.
- Package version is immutable DKMS `0.2.4`; the migration baseline is `0.2.3` with exactly `raspits_ft5426` and `panel_rockpi_rpi_touchscreen`.
- Production modules are exactly `rockpi_rk3399_display_compat`, `panel_rockpi_rpi_touchscreen`, and `raspits_ft5426`.
- DSI0 remains disabled in the DRM graph; it is a clock/PHY supplier only.
- Never use `/dev/mem`, never access both VOPs as a fallback, and never read or write the inactive VOP.
- Read the GRF DSI1 route only after the CRTC is live; apply from panel enable and restore from panel disable.
- Preserve HDMI and `/etc/X11/xorg.conf.d/20-dfrobot-display.conf` byte-for-byte.
- Preserve the working TC358762 profile, panel lifecycle, and FT5426 polling/recovery behavior.
- Keep persistent crash logging enabled.
- Do not unload the live diagnostic helpers, reboot, or shut down without fresh user authorization.
- Commit and push all reviewed source work before requesting reboot authorization.

---

### Task 1: Portable DSI0 and VOP compatibility core

**Files:**
- Create: `src/display_compat_core.h`
- Create: `src/display_compat_core.c`
- Create: `tests/test_display_compat.c`
- Modify: `Makefile`

**Interfaces:**
- Consumes: callback operations supplied later by the kernel platform wrapper.
- Produces:
  - `int rockpi_dsi0_start(struct rockpi_dsi0_state *state, const struct rockpi_display_io *io, void *context)`
  - `void rockpi_dsi0_stop(struct rockpi_dsi0_state *state, const struct rockpi_display_io *io, void *context)`
  - `int rockpi_vop_apply(struct rockpi_vop_state *state, const struct rockpi_display_io *io, void *context)`
  - `void rockpi_vop_restore(struct rockpi_vop_state *state, const struct rockpi_display_io *io, void *context)`

- [ ] **Step 1: Write the failing portable behavior test**

Create `tests/test_display_compat.c` with a fake context containing separate DSI0,
VOPB, and VOPL register arrays plus an ordered operation log. Use literal expected
values independent of production helpers. Add these tests:

```c
static void test_dsi0_start_programs_proven_780mbps_sequence(void);
static void test_dsi0_lock_timeout_unwinds_reset_and_clocks(void);
static void test_dsi0_each_setup_failure_unwinds_completed_steps(void);
static void test_vopb_route_accesses_only_vopb(void);
static void test_vopl_route_accesses_only_vopl(void);
static void test_route_failure_accesses_neither_vop(void);
static void test_vop_apply_sets_lane_and_bg_rb_only(void);
static void test_vop_restore_preserves_unrelated_live_changes(void);
static void test_vop_apply_is_idempotent(void);
static void test_vop_restore_without_apply_is_noop(void);
```

The successful fake must observe the exact DSI0 test-code/value pairs confirmed in
`/home/matt/dsi0_diag-20260820.RrRtF9/dsi0_diag.c`, followed by
`PHY_IF_CFG=0x2000`, `PHY_RSTZ=BIT(3)|BIT(2)|BIT(1)|BIT(0)`, and bounded lock reads.
The VOP literal expectations are `SYS_CTRL` bit 17 and `DSP_CTRL0` bits 12 and 13,
with bit 14 cleared and one `CFG_DONE=1` write. Any fake read or write to the
non-routed VOP must fail immediately.

Add this before the shell suites in `make test`:

```make
	cc -std=c11 -Wall -Wextra -Werror -I. tests/test_display_compat.c src/display_compat_core.c -o /tmp/test_display_compat
	/tmp/test_display_compat
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
cc -std=c11 -Wall -Wextra -Werror -I. tests/test_display_compat.c src/display_compat_core.c -o /tmp/test_display_compat
```

Expected: compilation initially fails because the core API does not exist. Add only
the declarations needed to compile, rerun the binary, and require a behavior failure
such as `FAIL: DSI0 PHY write sequence differs from proven 780 Mb/s sequence`.

- [ ] **Step 3: Implement portable types and callbacks**

In `src/display_compat_core.h`, use conditional kernel/userspace integer and bool
types following `src/ft5426_protocol.h`. Define:

```c
enum rockpi_vop_id { ROCKPI_VOP_BIG, ROCKPI_VOP_LIT };

struct rockpi_dsi0_state {
	bool clocks_enabled;
	bool reset_deasserted;
	bool started;
};

struct rockpi_vop_state {
	bool applied;
	enum rockpi_vop_id selected;
	bool original_data01_swap;
	rockpi_u32 original_rgb_swap;
};
```

Define `struct rockpi_display_io` with callbacks to enable/disable clocks,
assert/deassert reset, write DSI0 GRF, read/write DSI0, delay, resolve the DSI1 VOP,
and read/write one VOP identified by `enum rockpi_vop_id`. Define DSI PHY offsets,
VOP `CFG_DONE=0x0000`, `SYS_CTRL=0x0008`, `DSP_CTRL0=0x0010`, and the swap masks
once in the core header. Do not expose physical addresses in the portable core.

- [ ] **Step 4: Implement DSI0 start/stop minimally**

Implement `rockpi_dsi0_start()` in this order: enable clocks, assert reset, delay
10-20 microseconds, deassert reset, write proven GRF state, clear the test interface,
emit the literal 780 Mb/s sequence, write PHY interface configuration and enable
bits, then poll `PHY_STATUS & BIT(0)` at most ten times with 1 ms delays. Return
`-ETIMEDOUT` on the tenth miss. Every failure calls `rockpi_dsi0_stop()`.

Stop writes `PHY_RSTZ=0` only while clocks are enabled, asserts reset after a
successful deassert, disables clocks, and clears state. A second stop is a no-op.

- [ ] **Step 5: Implement routed VOP apply/restore minimally**

Apply returns success if already applied, then resolves routing. Route failure
returns before a VOP callback. Read only the selected VOP, save bit 17 and bits
12-14, set bit 17, replace bits 12-14 with bits 12 and 13, and commit once. Mark
applied only after writes. Restore uses the saved selection, never re-reads routing,
preserves unrelated live bits, restores saved fields, commits once, and clears state.

- [ ] **Step 6: Run focused and repository tests**

Run `make test` and `git diff --check`.

Expected: `PASS: RK3399 display compatibility core` plus every existing suite PASS.
Mentally mutate route selection, bit masks, lock bound, and restore; a named test
must catch each mutation.

- [ ] **Step 7: Commit Task 1**

```bash
git add Makefile src/display_compat_core.h src/display_compat_core.c tests/test_display_compat.c
git commit -m "feat: add tested RK3399 display compatibility core"
```

---

### Task 2: Kernel provider module and DRM panel integration

**Files:**
- Create: `src/display_compat.h`
- Create: `src/display_compat_main.c`
- Create: `tests/test_display_compat_lifecycle.sh`
- Modify: `src/panel_rockpi_rpi_touchscreen.c`
- Modify: `tests/test_panel_lifecycle.sh`
- Modify: `Makefile`
- Modify: `LICENSES/UPSTREAM.md`

**Interfaces:**
- Consumes: Task 1 core and DT properties `rockchip,dsi0`, `rockchip,dsi1`,
  `rockchip,grf`, `rockchip,vopb`, and `rockchip,vopl`.
- Produces module `rockpi_rk3399_display_compat.ko`, OF alias
  `rockpi,rk3399-dsi1-rpi-touchscreen-compat`, and:

```c
struct rockpi_display_compat;
struct rockpi_display_compat *rockpi_display_compat_get(struct device *consumer);
void rockpi_display_compat_put(struct rockpi_display_compat *compat);
int rockpi_display_compat_apply(struct rockpi_display_compat *compat);
void rockpi_display_compat_restore(struct rockpi_display_compat *compat);
```

- [ ] **Step 1: Write failing lifecycle and panel-consumer tests**

Create `tests/test_display_compat_lifecycle.sh` using the existing lifecycle-test
helpers. Require a provider platform driver with the exact compatible and five
properties, publication only after `rockpi_dsi0_start()` succeeds, DSI1/provider
and panel/provider device links, PM start/stop ordering, and reverse cleanup.

Extend `tests/test_panel_lifecycle.sh` to extract functions and prove:

```text
probe gets the provider before usable panel registration
enable checks prepared, applies compatibility, then enables backlight
failed enable after apply restores compatibility before return
disable turns backlight off, then restores compatibility
remove and every later probe unwind put the provider exactly once
```

Require the provider target in Makefile and later verify the panel has an undefined
reference to `rockpi_display_compat_apply`, producing a hard module dependency.

- [ ] **Step 2: Run lifecycle tests and verify RED**

Run `sh tests/test_display_compat_lifecycle.sh` and
`sh tests/test_panel_lifecycle.sh`.

Expected: fail for missing `src/display_compat_main.c` or missing panel acquisition,
not shell syntax or fixture errors.

- [ ] **Step 3: Implement provider resource callbacks**

Create a platform context containing Task 1 states, four DSI0 clocks, reset, GRF
regmap, DSI0/VOPB/VOPL mappings, provider device, DSI1 device/link, and mutex.
Resolve each phandle with `of_parse_phandle()`. Use `of_iomap()` only after
validating the node/resource. Map both VOPs but perform no VOP read during probe.
Acquire DSI0 clocks by name and its exclusive reset, with managed cleanup actions
for each mapping/reference.

Implement Task 1 callbacks with clock/reset APIs, `regmap_write()` for proven DSI0
GRF state, `readl()`/`writel()`, and `usleep_range()`. Read RK3399 GRF `SOC_CON20`
for DSI1 LCD select; zero selects VOPB and one VOPL. Return a regmap error before
VOP MMIO. The callback must touch only its selected mapping.

- [ ] **Step 4: Implement probe, PM, and exported API**

Probe calls `rockpi_dsi0_start()` and returns its error before publishing driver
data. Find DSI1 from its phandle and add a stateless link with DSI1 as consumer and
provider as supplier. Publish only after DSI0 lock and link creation succeed.

`rockpi_display_compat_get()` parses `rockpi,display-compat`, finds the provider
device, returns `ERR_PTR(-EPROBE_DEFER)` when driver data is absent, adds an
auto-removing consumer link, and retains the provider reference until put. Apply
and restore hold the mutex around Task 1. Export all four symbols GPL-only.

Suspend requires VOP state restored, then stops DSI0; resume restarts it and
propagates failure. Remove destroys the DSI1 link/reference and stops DSI0 without
VOP access.

- [ ] **Step 5: Integrate provider lifecycle into the panel**

Add provider pointer and `compat_applied` to panel context. Acquire the provider
before `drm_panel_add()` and release it on every later unwind and remove.

In enable, after the prepared check, call apply and return its error with `enabled`
false. Set `compat_applied` only on success. If brightness, backlight, or orientation
later fails, restore. In disable, turn off backlight first, restore if applied, and
clear the flag, preserving the first backlight error. Do not change prepare's
working TC358762 sequence.

- [ ] **Step 6: Build and verify linkage**

Run:

```bash
make test
make clean
scripts/dkms-make.sh "$(uname -r)" make KDIR="/lib/modules/$(uname -r)/build" W=1 modules
modinfo ./rockpi_rk3399_display_compat.ko
modinfo ./panel_rockpi_rpi_touchscreen.ko
nm -u ./panel_rockpi_rpi_touchscreen.ko | grep rockpi_display_compat
/lib/modules/"$(uname -r)"/build/scripts/checkpatch.pl --no-tree --strict src/display_compat_main.c src/display_compat_core.c src/display_compat_core.h src/display_compat.h
```

Expected: warning-free modules; provider GPL v2, matching vermagic, and exact OF
alias; panel `depends` includes provider; checkpatch has zero errors/warnings.

- [ ] **Step 7: Commit Task 2**

```bash
git add Makefile LICENSES/UPSTREAM.md src/display_compat.h src/display_compat_main.c src/panel_rockpi_rpi_touchscreen.c tests/test_display_compat_lifecycle.sh tests/test_panel_lifecycle.sh
git commit -m "feat: integrate RK3399 display compatibility provider"
```

---

### Task 3: Persistent kernel touch orientation

**Files:**
- Modify: `src/raspits_ft5426.c`
- Modify: `tests/test_driver_lifecycle.sh`

**Interfaces:**
- Consumes: standard `touchscreen-size-x/y` and `touchscreen-inverted-x/y`.
- Produces correctly oriented multitouch through `struct touchscreen_properties`
  and `touchscreen_report_pos()`.

- [ ] **Step 1: Write the failing touch-integration test**

Extend `tests/test_driver_lifecycle.sh` to extract probe and poll bodies. Require
probe to retain 800x480 axes and call
`touchscreen_parse_properties(input, true, &ts->properties)`. Require poll to call
`touchscreen_report_pos()` with raw point coordinates and multitouch true, and to
stop reporting raw X/Y itself. Preserve slot, release, sync, and polling-recovery
assertions.

- [ ] **Step 2: Run focused test and verify RED**

Run `sh tests/test_driver_lifecycle.sh`.

Expected: fail because the driver has no touchscreen-properties integration.

- [ ] **Step 3: Implement standard property handling**

Include `<linux/input/touchscreen.h>`, add
`struct touchscreen_properties properties` to driver state, and call:

```c
touchscreen_parse_properties(input, true, &ts->properties);
```

after both ABS axis definitions and before registration. Replace the two raw
coordinate reports with:

```c
touchscreen_report_pos(ts->input, &ts->properties, point->x, point->y, true);
```

Do not change parsing, slot keys, releases, recovery, or polling interval.

- [ ] **Step 4: Run tests and warning build**

Run:

```bash
sh tests/test_driver_lifecycle.sh
make test
scripts/dkms-make.sh "$(uname -r)" make KDIR="/lib/modules/$(uname -r)/build" W=1 modules
```

Expected: lifecycle/repository PASS and no warnings.

- [ ] **Step 5: Commit Task 3**

```bash
git add src/raspits_ft5426.c tests/test_driver_lifecycle.sh
git commit -m "fix: persist Raspberry Pi touch orientation"
```

---

### Task 4: Provider device tree and strict merged-tree validation

**Files:**
- Modify: `overlays/rockpi-4b-plus-rpi-touchscreen.dts`
- Modify: `tests/test_overlay.sh`
- Modify: `scripts/validate.sh`
- Modify: `tests/test_validate.sh`

**Interfaces:**
- Consumes: Task 2 provider/property names and Task 3 touch properties.
- Produces provider resources, panel/provider link, inverted touch axes, the
  existing DSI1/panel graph, and a disabled DSI0 DRM node.

- [ ] **Step 1: Write failing overlay and validator tests**

Require the compiled and merged tree to contain one enabled node compatible with
`rockpi,rk3399-dsi1-rpi-touchscreen-compat` and:

```dts
rockchip,dsi0 = <&mipi_dsi>;
rockchip,dsi1 = <&mipi_dsi1>;
rockchip,grf = <&grf>;
rockchip,vopb = <&vopb>;
rockchip,vopl = <&vopl>;
```

Require panel `rockpi,display-compat` to resolve back to the provider and both
touch inversion booleans. Continue requiring DSI0 disabled, no DSI0 graph,
reciprocal DSI1/panel endpoints, I2C `0x45`/`0x38`, 800x480, and HDMI `okay`.
Remove only assertions that endpoint status guarantees the live VOP; retain graph
preference checks.

- [ ] **Step 2: Run focused tests and verify RED**

Run `sh tests/test_overlay.sh` and `sh tests/test_validate.sh`.

Expected: fail for missing provider/phandles and inversion properties.

- [ ] **Step 3: Add provider and consumer properties**

Add an enabled root-level `rockpi_display_compat` overlay node with the exact
compatible and phandles above. Add
`rockpi,display-compat = <&rockpi_display_compat>` to `panel@45`, plus both
inversion booleans to `touchscreen@38`. Keep DSI0 disabled without endpoints.
Update the comment: endpoint statuses are a preference; provider follows GRF.

- [ ] **Step 4: Extend strict offline validation**

Locate the provider in the merged tree, compare every phandle to its target,
verify the panel back-reference and boolean inversions, and reject enabled DSI0 or
a DSI0 graph. Preserve HDMI and all existing address/mode/graph checks.

- [ ] **Step 5: Run complete overlay validation**

Run:

```bash
sh tests/test_overlay.sh
sh tests/test_validate.sh
sudo sh scripts/validate.sh --offline
git diff --check
```

Expected: provider, orientation, DSI graph, DSI0-disabled, and HDMI PASS.

- [ ] **Step 6: Commit Task 4**

```bash
git add overlays/rockpi-4b-plus-rpi-touchscreen.dts scripts/validate.sh tests/test_overlay.sh tests/test_validate.sh
git commit -m "feat: describe RK3399 display compatibility resources"
```

---

### Task 5: Transactional DKMS 0.2.4 three-module migration

**Files:**
- Modify: `dkms.conf`
- Modify: `scripts/common.sh`
- Modify: `scripts/install.sh`
- Modify: `scripts/uninstall.sh`
- Modify: `tests/test_dkms.sh`
- Modify: `tests/test_scripts.sh`

**Interfaces:**
- Consumes: Tasks 1-4 source and overlay artifacts.
- Produces immutable `rockpi-rpi-touchscreen/0.2.4` with three verified modules and
  exact rollback to two-module 0.2.3.

- [ ] **Step 1: Write failing metadata/allowlist tests**

Require:

```sh
PACKAGE_VERSION="0.2.4"
BUILT_MODULE_NAME[0]="rockpi_rk3399_display_compat"
BUILT_MODULE_NAME[1]="panel_rockpi_rpi_touchscreen"
BUILT_MODULE_NAME[2]="raspits_ft5426"
```

with matching locations/destinations. Require Makefile targets and installer
source/digest entries for all four display-compat source/header files, but no
tests, docs, Git metadata, or diagnostic directories.

- [ ] **Step 2: Write faithful migration and rollback cases**

Make fake DKMS 0.2.3 build/install exactly old panel and touch; 0.2.4 builds all
three new modules. Seed real old metadata/checksums. Add provider build/install,
panel install-after-provider, touch install-after-two, per-module checksum,
immutable-source, and uninstall-remove failures. Scope injections to 0.2.4 so
rollback reinstall of 0.2.3 succeeds.

Each failure must restore old DKMS status, both old module bytes/paths, old source,
DTBO, boot config, and cleanup state. Reject `rollback also failed` output in
ordinary injected failures.

- [ ] **Step 3: Run focused tests and verify RED**

Run `sh tests/test_dkms.sh` and `sh tests/test_scripts.sh`.

Expected: fail for version 0.2.3, two-module new lists, or migration from 0.2.2.

- [ ] **Step 4: Update package and transaction logic**

Set 0.2.4 in `dkms.conf`/`common.sh`; set:

```sh
MODULE_NAMES='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426'
OLD_MODULE_NAMES='panel_rockpi_rpi_touchscreen raspits_ft5426'
```

Set installer `old_version=0.2.3`. Use the three-name list for new staging,
snapshot, build/install/checksum, rollback, and uninstall. Use the explicit old
two-name list for old preflight/reinstall/post-rollback verification; never require
the new provider from 0.2.3. Include all provider files in staged source and digest.

- [ ] **Step 5: Run transactional and full tests**

Run:

```bash
sh tests/test_dkms.sh
sh tests/test_scripts.sh
make test
sudo sh scripts/validate.sh --offline
git diff --check
```

Expected: every success/failure/rollback/uninstall case and full suite PASS.

- [ ] **Step 6: Commit Task 5**

```bash
git add dkms.conf scripts/common.sh scripts/install.sh scripts/uninstall.sh tests/test_dkms.sh tests/test_scripts.sh
git commit -m "feat: package RK3399 display compatibility in DKMS 0.2.4"
```

---

### Task 6: Documentation, final verification, production install, and push

**Files:**
- Modify: `README.md`
- Modify: `docs/recovery.md`
- Modify: `docs/wiring.md`
- Modify: `LICENSES/UPSTREAM.md`
- Modify: `tests/test_docs.sh`
- System mutation: only through `sudo sh scripts/install.sh`

**Interfaces:**
- Consumes: reviewed Tasks 1-5.
- Produces accurate docs, installed DKMS 0.2.4/overlay, pushed branch, and a
  no-reboot hardware checkpoint.

- [ ] **Step 1: Write failing documentation checks**

Require docs to distinguish confirmed live diagnostics from pending production
reboot acceptance and state:

```text
DKMS 0.2.4 and all three module names
DSI0 disabled in DRM but supplying DSI1 PLL through provider
GRF-selected active VOP gets reversible data01 and BG/RB correction
both touch axes inverted in DT; X transform must be identity
no /dev/mem or inactive-VOP access
protected HDMI Xorg configuration
/var/log.hdd/kernel-live.log and crash-watch.log
exact scoped SSH/offline rollback
no automatic reboot or shutdown
```

- [ ] **Step 2: Run docs test and verify RED**

Run `sh tests/test_docs.sh`.

Expected: fail for missing 0.2.4/provider/live-evidence text.

- [ ] **Step 3: Update attribution and operator docs**

Add immutable Linux v6.18 and Rockchip/Radxa source URLs for the internal D-PHY
sequence, DSI1 data swap, VOP fields, and DRM panel order. Update README,
recovery, and wiring with install ownership, expected logs, identity X transform,
HDMI hotplug, crash collection, and rollback. Do not claim production reboot or
cold-start acceptance.

- [ ] **Step 4: Run final source verification**

Run:

```bash
make clean
make test
scripts/dkms-make.sh "$(uname -r)" make KDIR="/lib/modules/$(uname -r)/build" W=1 modules
sudo sh scripts/validate.sh --offline
/lib/modules/"$(uname -r)"/build/scripts/checkpatch.pl --no-tree --strict src/display_compat_main.c src/display_compat_core.c src/display_compat_core.h src/display_compat.h src/panel_rockpi_rpi_touchscreen.c src/raspits_ft5426.c
git diff --check
```

Expected: all PASS, warning-free modules, valid merged tree, checkpatch zero
errors/warnings, and no whitespace errors.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md docs/recovery.md docs/wiring.md LICENSES/UPSTREAM.md tests/test_docs.sh
git commit -m "docs: describe validated RK3399 display compatibility"
```

- [ ] **Step 6: Obtain final code review and resolve findings**

Review `babe78d..HEAD`. Critical or important findings require a focused
RED/GREEN cycle, full verification, corrective commit, and re-review. Do not
install until review reports no critical or important findings.

- [ ] **Step 7: Push reviewed source before system mutation**

Run:

```bash
git status --short --branch
git log --oneline origin/feat/touchscreen-support..HEAD
git push origin feat/touchscreen-support
```

Expected: clean worktree and remote advanced through every reviewed commit.

- [ ] **Step 8: Capture protected state and install transactionally**

Capture:

```bash
sha256sum /etc/X11/xorg.conf.d/20-dfrobot-display.conf
dkms status -m rockpi-rpi-touchscreen
sha256sum /boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
grep '^user_overlays=' /boot/armbianEnv.txt
```

Run `sudo sh scripts/install.sh`. Do not unload live modules. Require exact DKMS
0.2.4 installed status, three matching built/installed checksums, one overlay
token, verified source/DTBO, and removal of owned 0.2.3 only after success.

- [ ] **Step 9: Audit install and push any corrective commit**

Require the HDMI checksum unchanged. Run offline validation as root and
unprivileged, inspect persistent crash logs, and confirm `dsi0_diag` plus
`vop_data_swap_diag` remain loaded so the current display does not regress.

If installation exposes a source defect, use tested rollback, write a focused
failing test, fix/review/commit/push, and repeat. Never hand-edit installed
artifacts.

- [ ] **Step 10: Stop at reboot authorization**

Report commit hashes, remote state, test/install evidence, installed module/DTBO
state, protected HDMI checksum, live helper status, and first-boot acceptance
commands. The post-authorization checklist is:

```bash
lsmod | grep -E '^(rockpi_rk3399_display_compat|panel_rockpi_rpi_touchscreen|raspits_ft5426)'
sudo dmesg | grep -E 'display_compat|dsi0|panel_rockpi|failed to write command FIFO|Oops|lockup'
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority xrandr --current
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority xinput list-props 'Raspberry Pi 7-inch Touchscreen'
sha256sum /etc/X11/xorg.conf.d/20-dfrobot-display.conf
sudo tail -n 200 /var/log.hdd/kernel-live.log
sudo tail -n 40 /var/log.hdd/crash-watch.log
```

Require DSI-1 at 800x480, identity touch matrix with physically correct touches,
and user-confirmed RGB panels before HDMI hotplug. Then rerun `xrandr --current`
and the RGB check with both connectors active. Request fresh permission before
running any reboot command. Do not reboot, shut down, unload helpers, or reset the
current X transform in this task.
