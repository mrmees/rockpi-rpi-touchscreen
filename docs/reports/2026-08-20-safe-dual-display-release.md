# Safe dual-display routing 0.2.5 release gates

- Install date: 2026-08-21
- Production source head: `20c924771cd8e65bab0a25b5517bce67cc8fcf66`
- Branch: `feat/touchscreen-support`
- Host kernel: `6.18.43-current-rockchip64` (`aarch64`)

Status: 0.2.5 installed without reboot; live session preserved; push,
post-reboot hardware acceptance, and cold-start acceptance remain pending.

## Authorization and outcome

This release gate performed the separately authorized transactional migration
from the exact installed three-module DKMS 0.2.4 release to 0.2.5. The only
production transaction command was:

```sh
sudo -n sh scripts/install.sh
```

It exited 0. No command rebooted, shut down, powered off, loaded or unloaded a
module, changed the XRandR layout, started the mapper watcher, or accessed
`/dev/mem` or VOP MMIO. The boot ID remained
`efeb3465-c321-4cb5-a6c8-12f316ea854e` throughout. The Xorg process remained
PID 1282 with the same command line. The live output layout, DRM routes,
touchscreen Coordinate Transformation Matrix, loaded-module listing, and
filtered current-boot error log were byte-identical before and after the
transaction.

The controller explicitly deferred the plan's push step until this report and
commit receive review. Nothing was pushed, and no reboot, shutdown, or other
power action was performed. This preserves the required push-before-power
ordering because all power actions remain prohibited while publication is
pending.

## Reviewed source and commit ranges

The binding design is
`docs/superpowers/specs/2026-08-20-safe-dual-display-routing-design.md`; the
binding implementation plan is
`docs/superpowers/plans/2026-08-20-safe-dual-display-routing.md`.

The reviewed ranges were:

- Safe-routing plan execution base through Task 5:
  `3730b48be23836e4ee73f289df493c7850a153df..8e9782553418bc5bfbc181337abe9c20accb3570`.
- Whole-branch production review:
  `af330da812fede2cb584958494201993ef74a758..8e9782553418bc5bfbc181337abe9c20accb3570`.
- Whole-branch fix wave:
  `8e9782553418bc5bfbc181337abe9c20accb3570..dc29da080a9a3776dfe6ed9f5e05914381fd8612`.
- Final release-blocker follow-up:
  `dc29da080a9a3776dfe6ed9f5e05914381fd8612..20c924771cd8e65bab0a25b5517bce67cc8fcf66`.

The production installation used the clean tracked content at the last hash.
The safe-routing implementation and review commits are:

```text
a9656e9cdf535d98cc5ba5a30b2e33557dd0eeb6 fix: constrain DSI to little VOP
7a1b90cf7fd82c7bfdd39025f09650fcf02d245e fix: enforce warning-free DSI route graph
7f4b23bfb09247f31f017866308e73d2b321f94a feat: map X11 touch to DSI output
114891fe6715da5e7df7e271e7a637aa49896ac6 feat: package safe display routing in DKMS 0.2.5
4fc6df3060b3dd15ec91144cbdc2165d1b1e3b6b fix: harden runtime asset rollback ordering
9db358c5739e9401a7961716b885271139490ca8 fix: make touch mapper removal transactional
73a52841a5a843fb407900285ff3a6fe7fde9167 fix: close runtime uninstall race windows
021e316c5951175cfc5b55b2041fd4b020905ac6 fix: retain runtime claims across dependency races
e342ef8597292a2ee2e7bd769bf8413c30555ea7 docs: describe safe configurable dual displays
04c5775af688aa2e4260205ce5a95e6caf1e4bc2 fix: align dry-run and packaged asset validation
8e9782553418bc5bfbc181337abe9c20accb3570 fix: preserve mapper lexer command state
ae0dd26a5a8935de0eedbbc8f007a1759c403825 fix: enforce exact supported kernel boundary
9e1b5c11f1f70e723b154532df79d471ecdf5ec2 fix: linearize runtime asset ownership
6cb89097b1f6da92831da1d417d67d01cdd31a68 fix: attest protected Xorg across transactions
ac696c5019d13297126c8cf6b8cc6f5df188246f fix: report committed install cleanup failures
75e66a011f06996422d038f4411752cb93ebd078 fix: enforce exact source tree ownership
61c4f0995eb8c5e0f1d97f591f1bf609ca4ed9dc fix: pin touch mapper to canonical artifact
dc29da080a9a3776dfe6ed9f5e05914381fd8612 fix: attest both HDMI graph routes
2e0c7ab13d8fbfa48c82c0c60a28050dae14a5a6 fix: close final 0.2.5 release blockers
20c924771cd8e65bab0a25b5517bce67cc8fcf66 test: normalize canonical mapper fixture mode
```

## RED, GREEN, and review record

### Task 1: VOPL-only DSI graph

Before production changes, `sh tests/test_overlay.sh` exited 1 with
`FAIL: merged tree is missing the VOPB route filter`, and
`sh tests/test_validate.sh` exited 1 with
`FAIL: validator accepted route-filter mutation: ROUTE_FILTER_STATUS=okay`.
After `a9656e9`, the real active-DTB merge, route-filter mutation table, root
offline validator, `make test`, and `git diff --check` exited 0.

Review then rejected graph-warning suppressions (Critical) and a direct-port
count that missed an unnumbered `port` child (Important). Permanent regressions
reproduced:

```text
FAIL: validator accepted route-filter mutation: ROUTE_FILTER_EXTRA_UNNUMBERED_PORT=1
FAIL: validator passed a graph warning suppression to dtc
```

Commit `7a1b90c` removed the suppressions and rejected every direct extra port.
`sh tests/test_overlay.sh`, `sh tests/test_validate.sh`, root offline
validation, `git diff --check`, and `make test` all exited 0; scoped review was
clean.

### Task 2: X11 touch mapping without layout ownership

`sh tests/test_touch_mapper.sh` first failed because the mapper was absent:
`FAIL: one-shot mapper should succeed (got: 127; expected: 0)`. After
`7f4b23b`, the mapper suite, `sh -n scripts/map-touchscreen.sh`,
`git diff --check`, and `make test` exited 0. The command-boundary tests cover
active and inactive DSI, HDMI-only operation, duplicate devices, missing
tools, Wayland, watcher termination, RandR events, and mirror/position/primary
layout variants while accepting only `xrandr --current`.

The live one-shot follow-up fed the exact committed helper bytes to the
LightDM shell because `/home/matt` is not traversable by that account. It
changed only the intended CTM from identity to
`0.438596,0,0,0,0.800000,0,0,0,1`; XRandR and DRM hashes remained identical.
Task review was clean.

### Task 3: immutable 0.2.5 packaging and install transaction

Initial RED included wrong DKMS version/cardinality, wrong migration identity,
missing old-provider checksum enforcement, and every new runtime ownership
case: install, unrelated pre-existing objects, wrong modes, first/second asset
failure, late rollback, checksum failure, preservation of pre-existing exact
assets, and old-release retirement ordering. After `114891f`, final focused
results were:

```text
sh tests/test_dkms.sh      -> exit 0, 6 PASS lines
sh tests/test_scripts.sh   -> exit 0, 98 PASS lines
sh tests/test_validate.sh  -> exit 0, 192 PASS lines
git diff --check           -> exit 0
```

Review found three Important gaps: created flags armed after an ambiguous
move, mapper removal before its autostart dependency, and insufficiently
independent pre-boot/pre-retirement verification barriers. The focused RED
cases were:

```text
FAIL: expected absent: .../rockpi-rpi-touchscreen-touch-map.desktop
FAIL: autostart removal failure did not retain its mapper dependency
FAIL: initial runtime verification allowed boot configuration mutation
FAIL: installer accepted mapper corruption after boot mutation
```

Commit `4fc6df3` made all four focused cases pass and raised the complete
script-suite count to 102 PASS lines. Scoped review was clean.

### Task 4: transactional runtime removal

The six required uninstall cases were each run RED before implementation:

```text
test_uninstall_dry_run_lists_runtime_assets
test_uninstall_removes_matching_runtime_assets
test_uninstall_retains_and_reports_modified_mapper
test_uninstall_retains_and_reports_modified_autostart
test_uninstall_late_failure_restores_removed_runtime_assets
test_uninstall_runtime_restore_failure_retains_recovery
```

They and the full script suite passed after `9db358c`. Review found two
Critical race windows (post-preflight deletion and no-clobber restore), an
Important inaccurate cleanup outcome, and a Minor dry-run coverage gap.
Commit `73a5284` closed the first wave, but re-review retained two open race
findings: autostart claim collision recovery and dependency checking before
mapper claim. Permanent RED tests reproduced both. Commit `021e316` retained
held claims, linearized mapper ownership, preserved symlink types, and made
all focused and full script tests pass. Scoped review was clean.

### Task 5: documentation and automated release gates

Initial RED proved the validator accepted a missing mapper and a
path-qualified mutating xrandr invocation, while documentation lacked required
0.2.5 and rollback statements. Commit `e342ef8` made the mapper, validator,
and documentation suites pass; the full suite exited 0 with 375 PASS records,
root and unprivileged offline validators passed, and the exact-kernel `W=1`
build had no warning diagnostics with exact module metadata checks.

Review found an Important dry-run dependency mismatch, bypasses and false
positives in the xrandr policy, missing permanent syntax/TryExec mutations, and
desktop keys not bound to exactly one Desktop Entry group; documentation also
had a Minor snapshot/claim wording error. The first fix wave captured RED for
the dependency mismatch, wrong desktop header, quoted path, comment false
positive, and multiline substitution. Commit `04c5775` made focused suites,
root/user validators, and a 382-PASS full suite green. Re-review found one
remaining Important substitution/backtick/redirection state gap. Focused RED
then covered lost surrounding-word state, legacy backticks, leading
redirections, and assignment-like redirection targets. Commit `8e97825` made
the focused suites, both validators, and a 387-PASS full suite green. Review
was clean at Critical/Important severity; one deferred Minor concerned a
conservative false-positive for quote-stripped literal redirection characters.

### Whole-branch review and fix wave

The final whole-branch review of `af330da..8e97825` ruled the release not ready
and found seven load-bearing issues: exact-kernel enforcement, linearizable
runtime ownership, protected-Xorg attestation, committed cleanup reporting,
exact source-tree ownership, a canonical mapper boundary, and unchanged
reciprocal HDMI graph identity.

Each received a focused RED before its fix. Representative exact failures
were:

```text
FAIL: validator did not report the exact supported-kernel boundary
FAIL: installer accepted a raced mapper publication
FAIL: install rollback deleted or changed the post-publication mapper edit
FAIL: production installer did not hash protected Xorg before and after mutation
FAIL: combined cleanup failure did not report committed installation
FAIL: installer deleted extra old source as project-owned
FAIL: validator accepted noncanonical touch mapper: extra-after-current
FAIL: validator accepted HDMI route mutation: HDMI_VOPB_REMOTE=0xff
```

Commits `ae0dd26`, `9e1b5c1`, `6cb8909`, `ac696c5`, `75e66a0`, `61c4f09`,
and `dc29da0` made their focused suites green. A tracked-only clean-copy
`make test` exited 0 with 418 PASS and 0 FAIL; separate root and unprivileged
offline validators passed 13/13; the exact-kernel `W=1` build had no warnings;
module alias/license/vermagic/dependency, POSIX syntax, diff, scope,
forbidden-action, protected-Xorg, boot-hash, and live no-0.2.5 audits passed.

Scoped re-review approved findings 1, 3, 4, and 7 but retained three release
blockers: a combined local-edit plus failed claim move could discard data, the
0.2.4 manifest named the wrong deployed Makefile bytes, and mapper validation
accepted an exact-byte symlink or wrong executable mode. The controller ruled
that installation must remain blocked until all three were corrected.

### Final release-blocker follow-up

Commit `2e0c7ab` added permanent RED/GREEN and mutation evidence for all three
residual findings:

```text
FAIL: failed install claim move discarded the locally edited mapper recovery
FAIL: failed uninstall claim move discarded the locally edited autostart recovery
FAIL: rollback deleted or changed the exact-byte replacement mapper type
ERROR: registered old DKMS source does not match exact 0.2.4 ownership
FAIL: validator accepted canonical mapper object mutation: symlink
```

The corresponding focused GREEN markers proved exact edited claims survived,
publication identity came from the verified boundary, the exact deployed
0.2.4 source was accepted while byte/mode/type/extra mutations were rejected,
and the canonical mapper required non-symlink regular type, mode 755, syntax,
and exact bytes. A clean-copy `make test` exited 0 with 424 PASS and 0 FAIL;
separate user/root validators passed 13/13; exact-kernel `W=1` and `modinfo`
gates passed; syntax, diff, scope, safety, and live-state audits passed.

Review approved all production fixes but found one Important nondeterministic
test fixture under `umask 077`: the copied canonical mapper became mode 700.
The restrictive-umask command reproduced that RED. Commit `20c9247` normalized
the fixture to 0755; restrictive and ordinary focused cases passed, the full
validator passed with 226 PASS and 0 FAIL, and a clean-copy `make test` again
passed with 424 PASS and 0 FAIL. Scoped re-review found the issue addressed
with no new Critical/Important breakage. Immediately before Task 6, the
controller independently reran the tracked-only clean-copy suite at this exact
head and observed exit 0, 424 PASS, and 0 FAIL.

## Production pre-install baseline

The complete baseline was captured at `2026-08-21T14:52:23Z`. The required
commands included:

```sh
git rev-parse HEAD
git status --short
uname -r
dkms status -m rockpi-rpi-touchscreen
sha256sum /etc/X11/xorg.conf.d/20-dfrobot-display.conf
sha256sum /boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
sha256sum /boot/armbianEnv.txt
grep '^user_overlays=' /boot/armbianEnv.txt
ps -eo user:20,pid,args | grep '[X]org.* -auth '
sudo -n -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority \
  xrandr --current
sudo -n awk '/^crtc\[/ || /^connector\[/ || /^\tcrtc=crtc-/ || /\tmode:/' \
  /sys/kernel/debug/dri/0/state
sudo -n -u lightdm env DISPLAY=:0 XAUTHORITY=/var/lib/lightdm/.Xauthority \
  xinput list-props 6
sudo -n journalctl -b -k --no-pager -o short-iso-precise
```

The results were:

- `HEAD` was exactly `20c924771cd8e65bab0a25b5517bce67cc8fcf66`;
  tracked status was empty.
- Kernel/architecture were exactly
  `6.18.43-current-rockchip64`/`aarch64`.
- DKMS reported exactly
  `rockpi-rpi-touchscreen/0.2.4, 6.18.43-current-rockchip64, aarch64: installed`;
  0.2.5 status and `/usr/src/rockpi-rpi-touchscreen-0.2.5` were absent.
- The corrected production ownership function returned
  `PASS: /usr/src/rockpi-rpi-touchscreen-0.2.4 matches exact immutable 0.2.4 ownership manifest`.
  Its Makefile SHA-256 was
  `4c7b3fe6fc79f60e58e083011a539b07059378cbdd61395741b1ff7679ed5847`.
- Each installed 0.2.4 module was a root-owned mode-644 regular file and
  compared equal to its DKMS-state module. Provider, panel, and touch hashes
  were respectively `3b243c9828d7acb44f6c86f9a5e54ff5b70be4a6a32fc88531bf2261569c3da9`,
  `9ec49c860ba41098f757b2b8c5cc6e63325b13db06100497beceb098f5c2f193`,
  and `92f508d2060854cbba83b7f3badf275879fb85209c90cc6c27fdae5d19a9350b`.
- Both 0.2.5 runtime destination paths were absent.
- Protected Xorg was the same root-owned mode-644 inode `45825:833320`, with
  SHA-256
  `7720b05721c77a8d002e63215ba62f61559340abf28906d4fa9a7d4cb1e9ae0a`.
- `/boot/armbianEnv.txt` SHA-256 was
  `6101ed3b77d052c3e5cf5a8789de93f6e829b34bfc99ae204bf295d3816111c8`.
  It contained exactly one line
  `user_overlays=rockpi-4b-plus-rpi-touchscreen` and exactly one project token.
- The installed 0.2.4 DTBO SHA-256 was
  `4047f7f50ef1dad9e684cb8dadc4bfd92430fad273bd17ca0d44366347d2d793`.
- Xorg was
  `/usr/lib/xorg/Xorg -core :0 -seat seat0 -auth /var/run/lightdm/root/:0 -nolisten tcp vt7 -novtswitch`.
- XRandR reported screen `1824x600`, HDMI-1 primary at
  `1024x600+800+0`, and DSI-1 at `800x480+0+0`.
- DRM reported connector 54 HDMI-A-1 on crtc-0 with the 40 MHz 1024x600
  mode, and connector 57 DSI-1 on crtc-1 with the 25.979 MHz 800x480 mode.
  This is the accepted HDMI=VOPB, DSI=VOPL route.
- The exact touchscreen CTM was
  `0.438596, 0, 0, 0, 0.800000, 0, 0, 0, 1`.
- Current-boot grep for gamma LUT timeout, command-FIFO/FIFO error, Oops,
  lockup, kernel panic, and OOM signatures returned zero records.

The baseline fingerprints were:

| Snapshot | SHA-256 |
| --- | --- |
| `xrandr --current` | `a23799880b1f3ca7b41c8e77277774c2551b781be6c892f15ddc00722d8f22c0` |
| Filtered DRM atomic state | `7dbe1760435c65150f61f584a71e11de9b2e96adf859e648abdb07d786629156` |
| XInput CTM line | `ff8abb50be480501aed6ba90ebc4ccb7aa77c2e4b147d1f1cf4a3d8caa6cf3ef` |
| Filtered current-boot errors | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

## Exact installation output

The exact command exited 0. Its complete combined output was:

```text
PASS: board compatible
PASS: kernel headers
PASS: packaged touch mapper and autostart boundaries
PASS: all three module builds and metadata
PASS: active DTB symbols
PASS: overlay compile
PASS: overlay apply
PASS: unused DSI0 disabled without an output graph and DSI1 enabled
PASS: display compatibility provider resources
PASS: I2C1 panel and touch nodes
PASS: DSI1 VOPB route is terminated; DSI1 graph prefers little VOP and connects to panel
PASS: HDMI enabled with both reciprocal VOP routes unchanged from active base DTB
PASS: offline validation
Creating symlink /var/lib/dkms/rockpi-rpi-touchscreen/0.2.5/source -> /usr/src/rockpi-rpi-touchscreen-0.2.5
The kernel is built without module signing facility, modules won't be signed

Building module(s)........ done.
Installing /lib/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko
Installing /lib/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko
Installing /lib/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko
Running depmod.... done.
Module rockpi-rpi-touchscreen/0.2.4 is not installed for kernel 6.18.43-current-rockchip64 (aarch64). Skipping...

Deleting module rockpi-rpi-touchscreen/0.2.4 completely from the DKMS tree.
PASS: installed rockpi-rpi-touchscreen/0.2.5 and verified all three modules, source, backup, boot token, and DTBO checksums
NEXT: installation is complete; no automatic power action occurs. Obtain fresh authorization before any reboot or shutdown.
NEXT: first authorized boot: keep HDMI disconnected; validate DSI-1, RGB, and physical touch; then hot-plug HDMI.
ROLLBACK: sudo sh scripts/uninstall.sh (or use docs/recovery.md offline).
```

## Installed 0.2.5 verification

Post-install verification completed at `2026-08-21T14:56:19Z`.

```sh
dkms status -m rockpi-rpi-touchscreen -v 0.2.5
dkms status -m rockpi-rpi-touchscreen -v 0.2.4
cmp scripts/map-touchscreen.sh \
  /usr/libexec/rockpi-rpi-touchscreen-map-touch
cmp assets/rockpi-rpi-touchscreen-touch-map.desktop \
  /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
stat -c '%a %n' /usr/libexec/rockpi-rpi-touchscreen-map-touch \
  /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
sudo -n sh scripts/validate.sh --offline
```

Results:

- DKMS status is exactly
  `rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed`.
  DKMS 0.2.4 status, `/usr/src/rockpi-rpi-touchscreen-0.2.4`, and
  `/var/lib/dkms/rockpi-rpi-touchscreen/0.2.4` are absent.
- The production ownership function passed the exact immutable 0.2.5 source
  tree at `/usr/src/rockpi-rpi-touchscreen-0.2.5`; its packaged mapper and
  desktop bytes compare equal to the reviewed repository sources.
- Each installed module compares equal to its 0.2.5 DKMS-state module. All are
  root-owned mode-644 regular files with exact-kernel vermagic and GPL v2
  license; the panel depends on `rockpi_rk3399_display_compat`.

| Module | Installed/DKMS-state SHA-256 |
| --- | --- |
| `rockpi_rk3399_display_compat` | `746b2511801923686e62f3535418b2089e051f07453958ad13c74e3789b04ef3` |
| `panel_rockpi_rpi_touchscreen` | `7b114336ccdf04cad2993dc89ed095a5f82057993b8204dd4e2fa61756efbdff` |
| `raspits_ft5426` | `ad605c2ce901fd518af98875a268efb15c3d862f0cf178bd8a72a0bec6704507` |

- The mapper and desktop compare equal across reviewed source, immutable
  0.2.5 source, and installed runtime paths. They are root-owned non-symlink
  regular files at exact modes 755 and 644.

| Runtime asset | SHA-256 |
| --- | --- |
| `/usr/libexec/rockpi-rpi-touchscreen-map-touch` | `b2f332b54ad003da2e1f783fffb3a8edcb8640df75a77b3c16e54b8ccbdfa904` |
| `/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop` | `19b30895e66f09757df8975a6975b6d02c630a508f5e2cbd8531c7cce5a65dd1` |

- The installed DTBO compares equal to the freshly validated build. Both have
  SHA-256
  `f2b1faff289eb2f3f29efd6654c5f4ed9b25175d613e3e811d647d9733df0d72`;
  the installed object is root-owned mode 644.
- `/boot/armbianEnv.txt` retained its exact pre-install hash and still has
  exactly one project token. The new backup
  `/boot/armbianEnv.txt.rockpi-rpi-touchscreen.20260821T145333Z.bak`
  compares equal to the current boot file and passed its companion
  `sha256sum -c`; both backup files are root-owned mode 644.
- The protected Xorg file retained its exact pre-install inode, type, mode,
  owner, size, and SHA-256.
- The separate post-install root offline validator exited 0 with 13 PASS
  records, ending in `PASS: offline validation`. It again proved exact board
  and kernel boundaries, packaged userspace, all three module builds and
  metadata, active-DTB symbols, warning-free overlay compile/apply, disabled
  DSI0 output graph, provider/I2C graph, terminated DSI VOPB route, unchanged
  reciprocal HDMI routes, and offline validation.

## Live-session preservation

No module was unloaded or reloaded and the installed watcher was not started
manually. The mapper's autostart entry will be exercised only by a later
authorized login/boot acceptance. All XRandR commands in this gate were
read-only `--current` queries.

The post-install semantic state remained:

```text
Screen: 1824x600
HDMI-1: connected primary, 1024x600+800+0
DSI-1:  connected, 800x480+0+0
connector[54] HDMI-A-1 -> crtc-0, 40 MHz 1024x600 (VOPB)
connector[57] DSI-1    -> crtc-1, 25.979 MHz 800x480 (VOPL)
Touchscreen CTM: 0.438596, 0, 0, 0, 0.800000, 0, 0, 0, 1
```

The exact pre/post comparisons were:

| Evidence | Before SHA-256 | After SHA-256 | Result |
| --- | --- | --- | --- |
| `xrandr --current` | `a23799880b1f3ca7b41c8e77277774c2551b781be6c892f15ddc00722d8f22c0` | `a23799880b1f3ca7b41c8e77277774c2551b781be6c892f15ddc00722d8f22c0` | byte-identical |
| Filtered DRM atomic state | `7dbe1760435c65150f61f584a71e11de9b2e96adf859e648abdb07d786629156` | `7dbe1760435c65150f61f584a71e11de9b2e96adf859e648abdb07d786629156` | byte-identical |
| XInput CTM line | `ff8abb50be480501aed6ba90ebc4ccb7aa77c2e4b147d1f1cf4a3d8caa6cf3ef` | `ff8abb50be480501aed6ba90ebc4ccb7aa77c2e4b147d1f1cf4a3d8caa6cf3ef` | byte-identical |
| Filtered current-boot errors | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | byte-identical, zero records |

The exact loaded-module lines were also byte-identical:

```text
panel_rockpi_rpi_touchscreen    12288  0
rockpi_rk3399_display_compat    16384  1 panel_rockpi_rpi_touchscreen
raspits_ft5426         12288  0
```

There was no new gamma LUT timeout, command-FIFO/FIFO error, Oops, lockup,
kernel panic, or OOM record in the current boot. The unchanged boot ID, Xorg
process, XRandR state, DRM state, CTM, and loaded-module listing prove that the
installation did not reboot or disturb the live display session.

## Report and publication gates

Immediately before commit, exact report-content assertions passed,
`sh tests/test_docs.sh` exited 0 with `PASS: documentation acceptance`, the
untracked-report whitespace check had no diagnostic, and `git diff --check`
exited 0. `git status --porcelain=v1 --untracked-files=all` named only this
release report.

A fresh read-only artifact/protected/live gate also passed immediately before
commit: DKMS/source/module/runtime/DTBO/token state remained exact 0.2.5,
protected Xorg and boot hashes still matched the baseline, and the boot ID,
Xorg process, loaded-module listing, XRandR, DRM, CTM, and zero-record error
fingerprint all remained byte-identical. The tracked release-report commit is
intentionally not pushed in this phase.

## Pending acceptance and recovery

Hardware acceptance remains pending because the corrected overlay and 0.2.5
modules do not become live until a separately authorized reboot.
No reboot is authorized by this report. After the source is reviewed and
pushed, obtain fresh authorization and perform these checkpoints:

1. Boot first with HDMI disconnected and confirm DSI RGB video, backlight,
   physical touch, and only the VOPL-backed DSI CRTC.
2. Hot-plug HDMI and confirm both outputs retain video with HDMI=VOPB and
   DSI=VOPL.
3. Exercise mirror and extended layouts through ordinary desktop settings.
4. Change primary output and relative positions through ordinary settings and
   confirm the autostart mapper keeps physical touch on DSI after every RandR
   event.
5. Confirm persistent logs contain no new VOP gamma timeout, command-FIFO
   error, Oops, lockup, panic, or OOM record.
6. Under separate authorization, perform a later shutdown/cold-start and
   repeat the acceptance.

If rollback is required before reboot, use the reviewed scoped command
`sudo sh scripts/uninstall.sh` and follow `docs/recovery.md`. This report does
not execute rollback, reboot, shutdown, or any other power action.
