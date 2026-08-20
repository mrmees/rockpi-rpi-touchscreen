# Safe Dual-Display Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship DKMS 0.2.5 with a warning-free device-tree route filter that makes DSI VOPL-only and an X11 session helper that keeps touch mapped to DSI without controlling the user's display layout.

**Architecture:** A disabled reciprocal two-port DT node terminates the unsupported DSI1/VOPB graph in both directions while leaving the real VOPL-to-DSI graph intact. A project-owned XDG autostart helper listens for RandR events and changes only the touchscreen's XInput output mapping. The existing transactional installer migrates the faithful three-module 0.2.4 release to 0.2.5 and owns both userspace assets without touching the protected HDMI Xorg configuration.

**Tech Stack:** Linux 6.18 DRM OF graph and Rockchip VOP/DSI routing, device-tree overlays, POSIX shell, XRandR/XInput command-line tools, XDG autostart, DKMS, Armbian boot overlays, shell integration tests, exact-header `W=1` kernel-module builds.

**Spec:** `docs/superpowers/specs/2026-08-20-safe-dual-display-routing-design.md`

## Global Constraints

- Support exactly `radxa,rockpi4b-plus`, the original Raspberry Pi 7-inch 800x480 Touch Display, and `6.18.43-current-rockchip64` with matching headers.
- Package version is immutable DKMS `0.2.5`; migration baseline is exact three-module `0.2.4`.
- Module order remains `rockpi_rk3399_display_compat`, `panel_rockpi_rpi_touchscreen`, `raspits_ft5426`.
- DSI must advertise only the device-tree VOPL route; never encode a literal CRTC index in production artifacts.
- The route-filter graph must compile, apply, and decompile with no diagnostics beyond the three already allowlisted stock-DTB warnings.
- User controls mirror/extend, primary output, placement, and modes. Project userspace code must never issue an output-mutating `xrandr` command.
- X11 touch mapping targets exact device `Raspberry Pi 7-inch Touchscreen` and output `DSI-1`; Wayland is untouched.
- Preserve `/etc/X11/xorg.conf.d/20-dfrobot-display.conf` byte-for-byte.
- No `/dev/mem`, inactive-VOP MMIO access, reboot, shutdown, or automatic power action.
- All production changes follow RED → GREEN TDD and each task ends with focused and relevant regression verification.

## File map

- `overlays/rockpi-4b-plus-rpi-touchscreen.dts`: owns the reciprocal disabled route-filter graph.
- `scripts/map-touchscreen.sh`: one-shot and RandR-watch X11 touch-to-DSI mapper.
- `assets/rockpi-rpi-touchscreen-touch-map.desktop`: system-wide XDG autostart entry for the mapper.
- `scripts/common.sh`: 0.2.5 identity, faithful 0.2.4 baseline, and runtime destination paths.
- `scripts/install.sh`: immutable source staging plus transactional runtime-asset installation and rollback.
- `scripts/uninstall.sh`: scoped dry-run/removal, modified-asset retention, and runtime-asset rollback.
- `scripts/validate.sh`: exact merged-graph and packaged-userspace validation.
- `dkms.conf`: immutable 0.2.5 three-module metadata.
- `tests/test_overlay.sh`: real active-DTB route-filter integration.
- `tests/test_validate.sh`: validator mutation coverage for every route-filter invariant.
- `tests/test_touch_mapper.sh`: real helper behavior with controlled X command boundaries.
- `tests/test_dkms.sh`: exact 0.2.5 metadata cardinality/order.
- `tests/test_scripts.sh`: faithful 0.2.4 migration and runtime-asset transactions.
- `tests/test_docs.sh`: release, ownership, recovery, and hardware-checkpoint documentation contract.
- `Makefile`: includes the new touch-mapper integration suite in `make test`.
- `README.md`, `docs/recovery.md`, `docs/wiring.md`: operator guidance and hardware status.

---

### Task 1: Constrain DSI to VOPL in the merged device tree

**Files:**
- Modify: `overlays/rockpi-4b-plus-rpi-touchscreen.dts`
- Modify: `tests/test_overlay.sh`
- Modify: `scripts/validate.sh`
- Modify: `tests/test_validate.sh`

**Interfaces:**
- Consumes: active DTB symbols `mipi1_in_vopb`, `mipi1_in_vopl`, `vopb_out_mipi1`, and `vopl_out_mipi1`.
- Produces: disabled node `/rockpi-dsi1-vopb-route-filter` with reciprocal port 0 ↔ DSI VOPB input and port 1 ↔ VOPB DSI output; unchanged VOPL ↔ DSI route.

- [ ] **Step 1: Add failing real merged-tree route tests**

Extend `tests/test_overlay.sh` after the current VOP node extraction. Extract the route filter and VOPB endpoint, then assert literal phandle relationships derived independently from the merged tree:

```sh
route_filter=$(node_from_file "$workdir/merged.dts" 'rockpi-dsi1-vopb-route-filter')
vopb_endpoint=$(printf '%s\n' "$vopb" | extract_named_node 'endpoint@3')
filter_port0=$(printf '%s\n' "$route_filter" | extract_named_node 'port@0')
filter_port1=$(printf '%s\n' "$route_filter" | extract_named_node 'port@1')
filter_dsi_sink=$(printf '%s\n' "$filter_port0" | extract_named_node 'endpoint')
filter_vopb_sink=$(printf '%s\n' "$filter_port1" | extract_named_node 'endpoint')

require_text "$route_filter" 'status = "disabled";' 'route filter is disabled'
require_equal "$(printf '%s\n' "$dsi1_vopb_input" | property_phandle remote-endpoint)" \
  "$(printf '%s\n' "$filter_dsi_sink" | property_phandle phandle)" \
  'DSI VOPB input terminates at route filter port 0'
require_equal "$(printf '%s\n' "$filter_dsi_sink" | property_phandle remote-endpoint)" \
  "$(printf '%s\n' "$dsi1_vopb_input" | property_phandle phandle)" \
  'route filter port 0 connects back to DSI VOPB input'
require_equal "$(printf '%s\n' "$vopb_endpoint" | property_phandle remote-endpoint)" \
  "$(printf '%s\n' "$filter_vopb_sink" | property_phandle phandle)" \
  'VOPB DSI output terminates at route filter port 1'
require_equal "$(printf '%s\n' "$filter_vopb_sink" | property_phandle remote-endpoint)" \
  "$(printf '%s\n' "$vopb_endpoint" | property_phandle phandle)" \
  'route filter port 1 connects back to VOPB DSI output'
require_text "$vopb_endpoint" 'status = "disabled";' 'VOPB DSI output is disabled'
```

Also require exactly two direct `port@` children, `reg = <0>`/`reg = <1>`, and retain the existing reciprocal VOPL assertions.

- [ ] **Step 2: Run the real overlay test and capture RED**

Run:

```sh
sh tests/test_overlay.sh
```

Expected: FAIL because `rockpi-dsi1-vopb-route-filter` is absent. Save the exact failure in the task report.

- [ ] **Step 3: Add failing validator mutation cases**

Update the fake merged DTS in `tests/test_validate.sh` so its valid baseline contains the two-port disabled route filter. Add table-driven cases that independently mutate:

```sh
ROUTE_FILTER_STATUS=okay
ROUTE_DSI_REMOTE=0xc0
ROUTE_FILTER_DSI_REMOTE=0xc1
ROUTE_VOPB_REMOTE=0xb0
ROUTE_FILTER_VOPB_REMOTE=0xb1
ROUTE_FILTER_PORT0_REG=1
ROUTE_FILTER_PORT1_REG=0
ROUTE_FILTER_EXTRA_PORT=1
```

Each mutation must make `scripts/validate.sh --offline` fail before it reports `PASS: offline validation`. The wrong-remote fixtures must use valid but incorrect phandles so failure proves route policy, not malformed DTS parsing.

- [ ] **Step 4: Run validator tests and capture RED**

Run:

```sh
sh tests/test_validate.sh
```

Expected: the validator accepts at least one route-filter mutation because it has no filter policy yet.

- [ ] **Step 5: Implement the reciprocal warning-free overlay graph**

Add this root-level sibling beside `rockpi-display-compat`:

```dts
rockpi_dsi1_vopb_route_filter: rockpi-dsi1-vopb-route-filter {
    status = "disabled";

    ports {
        #address-cells = <1>;
        #size-cells = <0>;

        port@0 {
            reg = <0>;
            dsi1_vopb_filter_sink: endpoint {
                remote-endpoint = <&mipi1_in_vopb>;
            };
        };

        port@1 {
            reg = <1>;
            vopb_dsi1_filter_sink: endpoint {
                remote-endpoint = <&vopb_out_mipi1>;
            };
        };
    };
};
```

Replace the unsupported route in both directions:

```dts
&mipi1_in_vopb {
    status = "disabled";
    remote-endpoint = <&dsi1_vopb_filter_sink>;
};

&vopb_out_mipi1 {
    status = "disabled";
    remote-endpoint = <&vopb_dsi1_filter_sink>;
};
```

Do not modify either VOPL endpoint or any HDMI endpoint.

- [ ] **Step 6: Implement strict merged-tree validation**

In `scripts/validate.sh`, extract the filter node and its two ports/endpoints. Require exact disabled status, exact `reg` cells, reciprocal phandles, VOPB endpoint disabled, and unchanged reciprocal VOPL graph. Count direct filter ports with depth-aware `awk`; reject anything other than two. Compare each filter-port phandle against both VOP port phandles and every cell in `display-subsystem/ports`; equality is fatal.

Keep `run_warning_free overlay-compile`, `fdtoverlay`, and `run_dtb_decompile` unchanged so any new graph diagnostic fails validation.

- [ ] **Step 7: Verify GREEN and regression behavior**

Run:

```sh
sh tests/test_overlay.sh
sh tests/test_validate.sh
sudo sh scripts/validate.sh --offline
git diff --check
```

Expected: all PASS; only the three stock-DTB diagnostics are filtered during decompile, and no route-filter graph diagnostic appears.

- [ ] **Step 8: Mutation-review the route policy**

Mentally or temporarily mutate each of these production facts and identify the named test that fails: filter enabled, one port missing, ports swapped, either reciprocal phandle broken, VOPB endpoint reconnected to DSI, VOPL route broken, HDMI status changed. Add a focused regression before proceeding if any mutation survives.

- [ ] **Step 9: Commit Task 1**

```sh
git add overlays/rockpi-4b-plus-rpi-touchscreen.dts scripts/validate.sh \
  tests/test_overlay.sh tests/test_validate.sh
git commit -m "fix: constrain DSI to little VOP"
```

---

### Task 2: Map X11 touch to DSI without owning display layout

**Files:**
- Create: `scripts/map-touchscreen.sh`
- Create: `assets/rockpi-rpi-touchscreen-touch-map.desktop`
- Create: `tests/test_touch_mapper.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: inherited `DISPLAY`, `XAUTHORITY`, optional `XDG_SESSION_TYPE`, commands `xrandr`, `xinput`, `xev`, and `stdbuf`.
- Produces: `scripts/map-touchscreen.sh --once|--watch`; exact boundary call `xinput map-to-output INPUT_ID DSI-1`; no mutating `xrandr` call.

- [ ] **Step 1: Write the failing mapper integration test**

Create `tests/test_touch_mapper.sh` with a private `mktemp -d` sandbox and fake command directory. The fake `xrandr` accepts only `--current`, emits literal fixtures such as:

```text
Screen 0: minimum 320 x 200, current 1824 x 600, maximum 4096 x 4096
HDMI-1 connected primary 1024x600+800+0
DSI-1 connected 800x480+0+0
```

The fake `xinput` implements exactly:

```text
xinput list --id-only Raspberry Pi 7-inch Touchscreen
xinput map-to-output 17 DSI-1
```

It writes map calls to `$XINPUT_LOG`; any other mutation exits 90. The fake `xev` emits one `RRScreenChangeNotify event` header and exits. Test these named behaviors:

```sh
test_once_maps_exact_device_to_active_dsi
test_once_is_noop_for_inactive_dsi
test_once_is_noop_for_hdmi_only
test_once_rejects_duplicate_exact_devices
test_once_fails_when_required_tool_is_missing
test_watch_maps_initial_state_and_one_randr_event
test_wayland_never_invokes_x_commands
test_layout_variants_never_mutate_xrandr
test_watch_exits_when_event_source_exits
```

For layout variants, provide mirror, DSI-left, DSI-right, DSI-above, and either-primary fixtures. Every active fixture must yield the same literal map boundary call and no other output command.

- [ ] **Step 2: Run the mapper test and capture RED**

Run:

```sh
sh tests/test_touch_mapper.sh
```

Expected: FAIL because `scripts/map-touchscreen.sh` does not exist.

- [ ] **Step 3: Implement the minimal mapper**

Create `scripts/map-touchscreen.sh` as POSIX shell with this control flow:

```sh
#!/bin/sh
set -eu

touch_name='Raspberry Pi 7-inch Touchscreen'
output_name=DSI-1
mode=${1:---once}

case $mode in
--once|--watch) ;;
*) printf 'usage: %s [--once|--watch]\n' "$0" >&2; exit 2 ;;
esac

[ "${XDG_SESSION_TYPE:-x11}" != wayland ] || exit 0
[ -n "${DISPLAY:-}" ] || { printf 'ERROR: DISPLAY is not set\n' >&2; exit 1; }

require_command()
{
    command -v "$1" >/dev/null 2>&1 || {
        printf 'ERROR: required command not found: %s\n' "$1" >&2
        exit 1
    }
}

require_command xrandr
require_command xinput
[ "$mode" = --once ] || { require_command xev; require_command stdbuf; }

map_once()
{
    if ! xrandr --current | awk -v output="$output_name" '
        $1 == output && $2 == "connected" {
            for (i = 3; i <= NF; i++)
                if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) found = 1
        }
        END { exit found ? 0 : 1 }
    '; then
        return 0
    fi
    ids=$(xinput list --id-only "$touch_name" 2>/dev/null || true)
    count=$(printf '%s\n' "$ids" | awk 'NF { count++ } END { print count + 0 }')
    [ "$count" -eq 1 ] || {
        printf 'ERROR: expected exactly one %s device, found %s\n' "$touch_name" "$count" >&2
        return 1
    }
    input_id=$(printf '%s\n' "$ids" | awk 'NF { print; exit }')
    xinput map-to-output "$input_id" "$output_name"
}

map_once
[ "$mode" = --watch ] || exit 0
stdbuf -oL xev -root -event randr | while IFS= read -r event_line; do
    case $event_line in
    RRScreenChangeNotify*|RRNotify*) map_once ;;
    esac
done
```

If the real `xev` header differs on this image, update the matcher to the literal captured header and the fake to mirror it; do not broaden the match to every line.

- [ ] **Step 4: Add the XDG autostart asset**

Create `assets/rockpi-rpi-touchscreen-touch-map.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Rock Pi Raspberry Pi Touchscreen Mapping
Comment=Map the Raspberry Pi touchscreen to its DSI output
Exec=/usr/libexec/rockpi-rpi-touchscreen-map-touch --watch
TryExec=/usr/libexec/rockpi-rpi-touchscreen-map-touch
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
```

Do not include `OnlyShowIn`, a desktop layout command, a display number, or an authority path.

- [ ] **Step 5: Add the suite to `make test`**

Insert `sh tests/test_touch_mapper.sh` after the protocol/core unit tests and before packaging tests in `Makefile`.

- [ ] **Step 6: Verify GREEN and real one-shot behavior**

Run:

```sh
sh tests/test_touch_mapper.sh
sh -n scripts/map-touchscreen.sh
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority \
  sh "$PWD/scripts/map-touchscreen.sh" --once
```

The live one-shot may change only the touchscreen CTM. Immediately verify the current output positions and CRTCs are unchanged with `xrandr --current` and `/sys/kernel/debug/dri/0/state`.

- [ ] **Step 7: Mutation-review mapper isolation**

Ensure tests fail for a mutating `xrandr --output`, arbitrary first-device selection, fixed CTM, hard-coded `DISPLAY`, Wayland execution, mapping inactive DSI, and an event loop that maps on every `xev` detail line.

- [ ] **Step 8: Commit Task 2**

```sh
git add Makefile scripts/map-touchscreen.sh \
  assets/rockpi-rpi-touchscreen-touch-map.desktop tests/test_touch_mapper.sh
git commit -m "feat: map X11 touch to DSI output"
```

---

### Task 3: Package immutable DKMS 0.2.5 and install runtime assets transactionally

**Files:**
- Modify: `dkms.conf`
- Modify: `scripts/common.sh`
- Modify: `scripts/install.sh`
- Modify: `tests/test_dkms.sh`
- Modify: `tests/test_scripts.sh`

**Interfaces:**
- Consumes: Task 2 source files; faithful old `rockpi-rpi-touchscreen/0.2.4` with all three modules.
- Produces: immutable `0.2.5` source, three verified modules, DTBO, mapper mode 0755, autostart mode 0644, exact checksums, retirement of 0.2.4 only after complete verification.

- [ ] **Step 1: Write failing 0.2.5 metadata and faithful-baseline tests**

Change `tests/test_dkms.sh` expected metadata to version `0.2.5` while retaining exactly three indices 0..2. In `tests/test_scripts.sh`, make fake 0.2.4 and 0.2.5 both build/install provider, panel, and touch; only 0.2.5 receives new-release failure injections. Seed old source metadata with all three modules and exact cardinality. Add a regression that corrupts the old provider build/install checksum and requires migration to fail before mutation.

Run:

```sh
sh tests/test_dkms.sh
TEST_FILTER=test_migration_removes_old_release_only_after_success_and_ordered_verification \
  sh tests/test_scripts.sh
```

Expected: RED on 0.2.4 production metadata and the old 0.2.3 production baseline.

- [ ] **Step 2: Write failing runtime-install transaction tests**

Extend sandbox creation with:

```sh
mkdir -p "$sandbox/usr-libexec" "$sandbox/etc/xdg/autostart"
```

Pass `LIBEXEC_DIR=$sandbox/usr-libexec` and `XDG_AUTOSTART_DIR=$sandbox/etc/xdg/autostart` through `run_install`. Add tests:

```sh
test_install_owns_verified_runtime_assets
test_preexisting_unrelated_runtime_asset_blocks_before_mutation
test_runtime_asset_install_failure_restores_absent_baseline
test_late_failure_removes_new_runtime_assets
test_runtime_asset_checksum_failure_retains_recovery
test_old_release_retires_only_after_runtime_assets_verify
```

Successful install must assert exact source/runtime `cmp`, mapper mode `755`, desktop mode `644`, exact 0.2.5 DKMS status, absent 0.2.4 status/source, unchanged protected Xorg hash, and no rollback-failure output.

- [ ] **Step 3: Run focused tests and capture RED**

Run each new function through `TEST_FILTER=function_name sh tests/test_scripts.sh`. Expected failures must name missing runtime ownership or wrong version, not a broken fake command.

- [ ] **Step 4: Update common release identity and atomic install mode**

Set in `scripts/common.sh`:

```sh
PROJECT_VERSION=0.2.5
OLD_MODULE_NAMES=$MODULE_NAMES
LIBEXEC_DIRECTORY=${LIBEXEC_DIR:-/usr/libexec}
XDG_AUTOSTART_DIRECTORY=${XDG_AUTOSTART_DIR:-/etc/xdg/autostart}
TOUCH_MAPPER_DESTINATION=$LIBEXEC_DIRECTORY/rockpi-rpi-touchscreen-map-touch
TOUCH_AUTOSTART_DESTINATION=$XDG_AUTOSTART_DIRECTORY/rockpi-rpi-touchscreen-touch-map.desktop
```

Extend `try_atomic_install_file` with optional third argument `destination_mode=${3:-0644}` and apply that mode to the temporary file. Every existing two-argument caller retains 0644 behavior.

Set `PACKAGE_VERSION="0.2.5"` in `dkms.conf` without changing module order or cardinality.

- [ ] **Step 5: Make installer preflight the faithful 0.2.4 release**

Set `old_version=0.2.4`. Require exact old `BUILT_MODULE_NAME[0..2]` order provider, panel, touch and exact three-entry cardinality for names, locations, and destinations. Preflight built/installed checksums for every `$OLD_MODULE_NAMES` entry.

Update the fake DKMS so rollback reinstall failure, corrupt-old-reinstall, old-remove mutation, and retirement verification target 0.2.4; all new-release build/install/checksum/remove injections target 0.2.5.

- [ ] **Step 6: Stage userspace assets in immutable source**

Create `stage_directory/assets`, stage mapper as 0755 and desktop as 0644, and include both in `source_digest`:

```sh
install -m 0755 "$repo_root/scripts/map-touchscreen.sh" "$stage_directory/scripts/"
install -m 0644 "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" \
  "$stage_directory/assets/"
```

The digest input list must include both exact relative paths. Same-version source mismatch remains fatal.

- [ ] **Step 7: Install and verify runtime assets inside the transaction**

Before DKMS mutation, preflight each destination: absent is accepted; a regular file identical to the staged source and with exact expected mode is accepted for idempotence; every other existing type/content/mode fails closed.

Track `mapper_created` and `autostart_created`. After DKMS/module and DTBO verification but before boot-token mutation:

```sh
if [ ! -e "$TOUCH_MAPPER_DESTINATION" ]; then
    try_atomic_install_file "$PROJECT_SOURCE_DIR/scripts/map-touchscreen.sh" \
        "$TOUCH_MAPPER_DESTINATION" 0755 || die 'touch mapper installation failed'
    mapper_created=1
fi
if [ ! -e "$TOUCH_AUTOSTART_DESTINATION" ]; then
    try_atomic_install_file \
        "$PROJECT_SOURCE_DIR/assets/rockpi-rpi-touchscreen-touch-map.desktop" \
        "$TOUCH_AUTOSTART_DESTINATION" 0644 || die 'touch autostart installation failed'
    autostart_created=1
fi
```

Verify `cmp` and numeric modes before adding the overlay token and again before old-release retirement. Rollback removes only assets created by this transaction; a removal failure retains and reports recovery.

- [ ] **Step 8: Verify GREEN and full installer regression**

Run:

```sh
sh tests/test_dkms.sh
sh tests/test_scripts.sh
sh tests/test_validate.sh
git diff --check
```

Expected: all PASS, including every prior module-path, compressed-artifact, depmod, boot snapshot, DKMS state-tree, and rollback test now expressed as 0.2.4 → 0.2.5.

- [ ] **Step 9: Mutation-review installation atomicity**

Ensure a named test fails for: omitted provider in old baseline, runtime installed after old retirement, wrong mapper mode, digest omission, unverified asset, rollback removing pre-existing exact asset, and failure after one of two assets is installed.

- [ ] **Step 10: Commit Task 3**

```sh
git add dkms.conf scripts/common.sh scripts/install.sh tests/test_dkms.sh tests/test_scripts.sh
git commit -m "feat: package safe display routing in DKMS 0.2.5"
```

---

### Task 4: Uninstall runtime assets without deleting local modifications

**Files:**
- Modify: `scripts/uninstall.sh`
- Modify: `tests/test_scripts.sh`

**Interfaces:**
- Consumes: common destination variables and immutable source files from Task 3.
- Produces: scoped dry-run/remove/rollback semantics for mapper and autostart; modified assets retained and reported.

- [ ] **Step 1: Write failing uninstall ownership tests**

Add focused tests:

```sh
test_uninstall_dry_run_lists_runtime_assets
test_uninstall_removes_matching_runtime_assets
test_uninstall_retains_and_reports_modified_mapper
test_uninstall_retains_and_reports_modified_autostart
test_uninstall_late_failure_restores_removed_runtime_assets
test_uninstall_runtime_restore_failure_retains_recovery
```

The modified-file cases must still remove verified DKMS/DTBO/token assets, retain the modified file byte-for-byte, print `RETAIN MODIFIED: exact-path`, and never report rollback failure. Snapshot/restore cases inject failure after runtime removal and compare exact contents plus modes.

- [ ] **Step 2: Run each focused test and capture RED**

Use:

```sh
TEST_FILTER=test_uninstall_dry_run_lists_runtime_assets sh tests/test_scripts.sh
```

Repeat for all six functions. Expected: current uninstaller neither lists nor owns the new paths.

- [ ] **Step 3: Implement preflight and dry-run policy**

For each runtime asset, derive expected source below `$PROJECT_SOURCE_DIR`. Record one of `absent`, `owned`, or `modified`. `owned` requires regular file, exact `cmp`, and exact mode. `modified` is retained.

Dry run prints:

```text
REMOVE: /usr/libexec/rockpi-rpi-touchscreen-map-touch
REMOVE: /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
```

for owned assets, or `RETAIN MODIFIED: path` for modified assets. It must not mutate either.

- [ ] **Step 4: Snapshot, remove, and roll back owned assets**

Copy each owned asset and its mode into the uninstall transaction before the snapshot-complete marker. After DKMS, token, and DTBO removal succeeds, remove only owned runtime assets. On any later failure, restore each snapshot with `try_atomic_install_file source destination mode`, then verify `cmp` and mode.

If restore verification fails, retain the transaction directory, name the exact asset in `rollback_note`, and exit nonzero. Never remove or overwrite a modified asset.

- [ ] **Step 5: Verify GREEN and all uninstall regressions**

Run:

```sh
sh tests/test_scripts.sh
sh -n scripts/uninstall.sh
git diff --check
```

- [ ] **Step 6: Mutation-review removal safety**

Ensure tests catch unconditional deletion, content-only ownership without mode, modified-file overwrite during rollback, omitted dry-run path, and recovery cleanup after failed restore.

- [ ] **Step 7: Commit Task 4**

```sh
git add scripts/uninstall.sh tests/test_scripts.sh
git commit -m "fix: make touch mapper removal transactional"
```

---

### Task 5: Document 0.2.5 behavior and close automated release gates

**Files:**
- Modify: `README.md`
- Modify: `docs/recovery.md`
- Modify: `docs/wiring.md`
- Modify: `tests/test_docs.sh`
- Modify: `scripts/validate.sh`
- Modify: `tests/test_validate.sh`

**Interfaces:**
- Consumes: Tasks 1–4 artifacts and ownership policy.
- Produces: accurate operator docs, packaged-userspace offline checks, and complete automated release verification.

- [ ] **Step 1: Write failing documentation and packaged-asset checks**

Require exact documentation facts:

```text
DKMS `0.2.5`
DSI is constrained to VOPL by device-tree graph identity
mirror, position, and primary display remain user-configurable
/usr/libexec/rockpi-rpi-touchscreen-map-touch
/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
RETAIN MODIFIED
X11 touch mapping; Wayland compositor mapping is out of scope
```

In validator tests, add missing/non-executable mapper, malformed desktop `Exec`, layout-mutating mapper fixture, and wrong asset mode. Run tests and record RED.

- [ ] **Step 2: Validate packaged userspace artifacts offline**

In `scripts/validate.sh`, run `sh -n` on `scripts/map-touchscreen.sh`; require executable source mode; require exact desktop `Exec` and `TryExec`; reject `xrandr` invocations in the mapper unless the next argument is exactly `--current`. Also reject literal `--output`, `--mode`, `--pos`, `--primary`, `--off`, `DISPLAY=:`, and `XAUTHORITY=` in the mapper.

This is a package boundary check, not a replacement for `tests/test_touch_mapper.sh` behavior tests.

- [ ] **Step 3: Update operator documentation**

Document:

- root cause and safe route without claiming the hard-lock mechanism is proven;
- arbitrary user layout through normal desktop settings;
- automatic X11 touch-to-DSI mapping and manual `--once` command;
- how to disable the XDG autostart entry per user;
- runtime ownership, modified-file retention, dry-run output, and recovery;
- 0.2.5 migration baseline and exact three modules;
- hardware acceptance still pending until reboot/hotplug/touch/log/cold-start checks;
- no automatic reboot/shutdown and protected HDMI config unchanged.

Remove stale 0.2.4 pending-language only where replaced by the accurate 0.2.5 state; retain historical release references inside committed old design/plan documents.

- [ ] **Step 4: Run focused GREEN**

```sh
sh tests/test_touch_mapper.sh
sh tests/test_validate.sh
sh tests/test_docs.sh
```

- [ ] **Step 5: Run complete repository verification**

```sh
make test
sudo sh scripts/validate.sh --offline
sh scripts/validate.sh --offline
sh -n scripts/common.sh scripts/dkms-make.sh scripts/install.sh \
  scripts/uninstall.sh scripts/validate.sh scripts/map-touchscreen.sh
git diff --check
```

Build fresh modules with the exact kernel compiler and `W=1`; require no warnings. Run exact-kernel `modinfo` alias/license/vermagic checks for all three modules and require panel dependency on the provider. Run checkpatch in file mode for changed kernel C only if kernel C changed; otherwise record that no kernel C changed.

- [ ] **Step 6: Audit protected and out-of-scope state**

```sh
sha256sum /etc/X11/xorg.conf.d/20-dfrobot-display.conf
git status --short
git diff --name-only d4740ae..HEAD
```

The diff must not include the protected file, any unrelated machine configuration, raw VOP diagnostic code, or layout preset.

- [ ] **Step 7: Commit Task 5**

```sh
git add README.md docs/recovery.md docs/wiring.md tests/test_docs.sh \
  scripts/validate.sh tests/test_validate.sh
git commit -m "docs: describe safe configurable dual displays"
```

---

### Task 6: Review, install 0.2.5, and hand off the reboot checkpoint

**Files:**
- Create: `docs/reports/2026-08-20-safe-dual-display-release.md`
- Modify only if review finds a tested defect: files from Tasks 1–5 plus the matching test.

**Interfaces:**
- Consumes: verified commits from Tasks 1–5 and live installed 0.2.4 baseline.
- Produces: reviewed and pushed source, installed 0.2.5, unchanged live layout/Xorg config, and an explicit no-reboot hardware handoff.

- [ ] **Step 1: Perform two-stage final review**

Review the implementation against the spec first, then review code quality and transaction safety. Any finding gets a focused failing regression before its fix. Re-run the affected focused suite and `make test` after every fix wave.

- [ ] **Step 2: Capture the production pre-install baseline**

Record in the report:

```sh
git rev-parse HEAD
git status --short
dkms status -m rockpi-rpi-touchscreen
sha256sum /etc/X11/xorg.conf.d/20-dfrobot-display.conf
sha256sum /boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
grep '^user_overlays=' /boot/armbianEnv.txt
ps -eo user:20,pid,args | grep '[X]org.* -auth '
sudo -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority \
  xrandr --current
sudo awk '/^crtc\[/ || /^connector\[/ || /^\tcrtc=crtc-/ || /\tmode:/' \
  /sys/kernel/debug/dri/0/state
```

Require current live HDMI=VOPB and DSI=VOPL before installation. Do not change layout.

- [ ] **Step 3: Install 0.2.5 without rebooting**

```sh
sudo sh scripts/install.sh
```

Require exact PASS plus explicit no-power-action handoff. Verify:

```sh
dkms status -m rockpi-rpi-touchscreen -v 0.2.5
dkms status -m rockpi-rpi-touchscreen -v 0.2.4
cmp scripts/map-touchscreen.sh /usr/libexec/rockpi-rpi-touchscreen-map-touch
cmp assets/rockpi-rpi-touchscreen-touch-map.desktop \
  /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
stat -c '%a %n' /usr/libexec/rockpi-rpi-touchscreen-map-touch \
  /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
sudo sh scripts/validate.sh --offline
```

Expected: 0.2.5 installed, 0.2.4 absent, modes 755/644, checksums equal, one overlay token, and protected Xorg checksum unchanged.

- [ ] **Step 4: Verify installation did not disturb the live session**

Re-run `xrandr --current`, DRM atomic state, XInput CTM, and current-boot display-error grep. Require the same live output modes/positions/CRTCs as the baseline and no new gamma timeout, FIFO error, Oops, lockup, panic, or OOM line.

Do not start the autostart watcher manually in the LightDM session; only `--once` was already tested in Task 2.

- [ ] **Step 5: Write and commit the release report**

The report includes commit hashes, RED/GREEN evidence, exact test/build/validator results, pre/post hashes, DKMS/source/DTBO/runtime state, live-layout preservation, remaining reboot/cold-start acceptance, and the explicit statement that the install did not reboot or shut down.

```sh
git add docs/reports/2026-08-20-safe-dual-display-release.md
git commit -m "docs: record safe dual-display release gates"
```

- [ ] **Step 6: Push all committed work before any power action**

```sh
git status --short --branch
git push origin feat/touchscreen-support
git rev-parse HEAD
git rev-parse origin/feat/touchscreen-support
```

Require clean worktree and identical local/remote hashes.

- [ ] **Step 7: Stop for fresh reboot authorization**

Report that source is pushed and 0.2.5 is installed. Request fresh authorization before reboot. The post-reboot acceptance is:

1. DSI advertises only its VOPL-backed CRTC.
2. Mirror and extended layouts both show video on both outputs.
3. User can change primary and positions through normal settings.
4. Autostart mapper keeps physical touch on DSI after each RandR change.
5. Persistent logs remain free of new VOP gamma timeout, FIFO error, Oops, lockup, panic, and OOM.
6. A separately authorized shutdown/cold-start repeats the same acceptance.
