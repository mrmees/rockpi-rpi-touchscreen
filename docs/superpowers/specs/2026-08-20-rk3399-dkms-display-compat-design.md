# RK3399 DKMS Display Compatibility Design

**Date:** 2026-08-20  
**Status:** Approved in chat; implementation pending

## Problem

The original Raspberry Pi 7-inch Touch Display now produces a stable 800x480
desktop on the Rock Pi 4B+, but only while two throwaway diagnostic modules and
one userspace input transform are active. The successful live configuration is:

- a helper keeps the disabled DSI0 block's clocks, reset, and internal D-PHY
  PLL active at the same 780 Mb/s rate used by DSI1;
- the VOP feeding DSI1 has `data01_swap` enabled;
- that VOP's output swap field has blue/green and red/blue swap bits enabled;
- both touchscreen axes are inverted by an X coordinate transformation matrix.

Without `data01_swap`, the panel is lit but black. With the lane swap alone,
intended red, green, and blue display as green, blue, and red. With the two
output-channel swap bits, intended RGB displays as RGB. The user confirmed that
the 180-degree touch transform is correct.

The current helpers are deliberately throwaway: they use fixed physical targets,
have no device-tree binding or system power-management contract, are not packaged
by DKMS, and disappear at reboot. The userspace touch transform is likewise not
persistent. A reboot-safe implementation must preserve HDMI, follow whichever VOP
DRM actually routes to DSI1, and never access a clock-gated inactive VOP; a prior
raw read of the inactive display block hard-froze the machine.

## Goals

- Reproduce the proven DSI0 PLL, VOP lane, VOP color, and touch corrections on
  every boot.
- Remain a DKMS-only solution that follows Armbian kernel updates without a
  custom kernel build.
- Support the Rock Pi 4B+ with the original 800x480 Raspberry Pi Touch Display.
- Preserve HDMI and the existing DFRobot Xorg configuration unchanged.
- Select only the VOP currently routed to DSI1 and never access the inactive VOP.
- Reapply and restore VOP state at DRM lifecycle points where the selected VOP is
  known to be powered.
- Support system suspend/resume ordering through Linux device links.
- Preserve transactional install, upgrade, rollback, and uninstall behavior.
- Commit and push the reviewed work before any reboot.

## Non-goals

- Support Raspberry Pi Touch Display 2 or unrelated DSI panels.
- Replace or rebuild Armbian's `rockchipdrm` module.
- Upstream a generic RK3399 DSI1 companion implementation in this release.
- Use `/dev/mem`, a boot-time userspace register writer, or the inactive VOP.
- Change the HDMI monitor's mode, desktop placement, or Xorg configuration.
- Claim cold-start or dual-display hardware acceptance before those checks run.

## Chosen Architecture

Add a third GPL-compatible DKMS module named
`rockpi_rk3399_display_compat`. It is a device-tree-backed platform provider
whose only responsibility is the Rock Pi 4B+ RK3399 compatibility state needed
by this panel. The existing panel driver consumes its small exported interface;
the existing touch driver consumes standard kernel touchscreen properties.

Keeping the provider separate from the panel driver gives DSI0 clocks, reset,
GRF routing, VOP register ownership, and system PM one explicit lifecycle. It
also makes the panel module depend on the provider at module-link time, so normal
module loading brings the provider in before the panel can probe. Folding the
same logic into the I2C panel driver would mix three unrelated devices in one
driver and make supplier ordering harder to reason about. A systemd service was
rejected because it could race DRM modesets and suspend/resume.

## Device Tree and Resource Ownership

The overlay adds one enabled provider node with compatible string
`rockpi,rk3399-dsi1-rpi-touchscreen-compat`. It contains phandles for:

- the disabled DSI0 node at `ff960000`;
- the active DSI1 host at `ff968000`;
- the RK3399 general register files;
- VOPB at `ff900000`;
- VOPL at `ff8f0000`.

The panel node gains a `rockpi,display-compat` phandle to the provider. DSI0
remains disabled in the DRM graph so the unused DSI0 component cannot block the
Rockchip DRM master or HDMI. The provider may acquire the disabled node's clocks,
reset, and register resource directly, as the successful diagnostic helper does;
it does not register DSI0 as a DRM output.

The current endpoint statuses that express a preference for VOPL remain advisory.
The provider does not assume they determine live routing. Instead it reads the
safe GRF DSI1 LCD-select bit after the CRTC is enabled and chooses VOPB or VOPL
from that hardware state.

The touchscreen node retains its 800x480 size and gains
`touchscreen-inverted-x` and `touchscreen-inverted-y`. No userspace calibration
file is installed.

## Compatibility Provider Lifecycle

### Probe

Provider probe resolves every required phandle and resource before changing
hardware. It acquires DSI0's `ref`, `pclk`, `phy_cfg`, and `grf` clocks and its
exclusive reset control. It also creates a supplier device link from DSI1 to the
provider so system PM resumes the provider before DSI1. Failure to resolve any
mandatory resource aborts probe without touching a VOP.

Probe then enables the four clocks, asserts and deasserts DSI0 reset, applies the
proven RK3399 GRF force-bit state, programs the exact internal D-PHY sequence that
locked at 780 Mb/s during diagnosis, enables the PHY, and polls the lock bit with
a bounded timeout. Any failure unwinds reset and clocks in reverse order. The
provider publishes itself to consumers only after lock succeeds.

### Consumer acquisition and PM

The panel probe resolves `rockpi,display-compat`. If the provider has not completed
probe, the panel returns `-EPROBE_DEFER`; it never continues with an unprepared
DSI0 clock source. Successful acquisition creates a panel-to-provider device link.
Together, the links require provider resume before both DSI1 and the panel, and
provider suspend after both consumers.

Provider resume repeats the complete clock/reset/GRF/PLL/lock sequence before
consumers resume. Provider suspend disables the PHY and releases the enabled
clocks after consumers have stopped. Resume failure is reported and prevents a
false successful panel resume.

### VOP apply

The panel calls the provider's apply operation from panel `enable()`. Linux DRM
enables the CRTC before invoking panel enable, so the DSI route and selected VOP
are live at this point. The provider:

1. reads the GRF DSI1 LCD-select bit;
2. selects exactly one mapped VOP resource from that result;
3. reads and saves only `SYS_CTRL.data01_swap` and the three RGB swap bits in
   `DSP_CTRL0`;
4. enables `data01_swap`;
5. replaces the RGB swap field with blue/green plus red/blue swap;
6. writes `CFG_DONE=1` once to commit both settings.

The provider does not read or write the other VOP. It preserves every unrelated
register bit. It does not require immediate readback to match because these VOP
registers are shadowed and become visible at the frame commit.

If apply fails before the MMIO writes, panel enable leaves `enabled` false and the
backlight off. If a later panel-enable operation fails, the panel invokes provider
restore before returning the error.

### VOP restore

Panel `disable()` first turns the backlight off, then calls provider restore.
DRM invokes panel disable before disabling the CRTC, so the VOP selected during
apply is still powered. Restore uses that saved VOP selection, reinstates only the
saved lane and RGB fields around any unrelated live changes, commits once, and
clears the provider's applied state. It never re-evaluates routing or touches the
inactive VOP during teardown.

Provider operations serialize their saved state. A second apply without a restore
is idempotent; restore without a successful apply is a no-op. Provider removal
requires no live VOP access after all consumers have detached.

## Panel Driver Integration

The panel module includes the provider's exported header and therefore has a hard
module dependency on `rockpi_rk3399_display_compat`. Panel probe acquires the
provider before registering a usable DSI panel.

The existing panel power and TC358762 sequence remains unchanged. In panel
`enable()`, the provider apply call occurs after the prepared-state check and
before `enabled` becomes true or any backlight operation runs. Panel `disable()`
turns off the backlight and restores provider state while the CRTC remains active.
Every subsequent modeset repeats this pair, so mainline VOP programming cannot
permanently overwrite the correction.

Panel remove, probe unwind, shutdown, and failed-enable paths release or restore
provider state exactly once. Existing safe panel, backlight, DSI attach, and MCU
cleanup behavior remains intact.

## Touch Driver Integration

The touch driver adds `struct touchscreen_properties`, calls
`touchscreen_parse_properties()` after establishing the 800x480 multitouch axes,
and reports each active contact with `touchscreen_report_pos()`. The generic kernel
helper applies both inversion properties from the overlay. Slot allocation,
release handling, polling recovery, and raw FT5426 frame validation do not change.

The temporary X coordinate transformation matrix must be identity after the new
driver is active; otherwise the same 180-degree correction would be applied twice.
No live touch-driver swap is attempted while the current display session owns the
device. Reboot provides the clean transition.

## Error Handling and Crash Safety

- No code uses `/dev/mem` or accesses a VOP before GRF routing identifies it as
  DSI1's active source.
- Missing phandles, clocks, reset, GRF, VOP resources, or provider state fail probe
  or defer the panel; they do not guess physical addresses.
- DSI0 clock, reset, PHY, or lock failures unwind in reverse order and prevent the
  panel backlight from presenting a lit-but-dead display.
- A GRF route-read failure returns before VOP MMIO. No fallback touches both VOPs.
- Failed panel enable restores any applied VOP state before returning.
- Suspend and resume use supplier/consumer links rather than relying on platform
  enumeration order.
- The existing persistent kernel and five-second crash-watch logs remain enabled
  through implementation and reboot validation.

## DKMS, Installation, and Recovery

Bump the immutable package from 0.2.3 to 0.2.4. DKMS builds and installs:

- `rockpi_rk3399_display_compat`;
- `panel_rockpi_rpi_touchscreen`;
- `raspits_ft5426`.

The source allowlist gains only the provider source, its focused shared headers,
and the existing build inputs. Installer validation requires all three module
aliases, licenses, matching vermagic, DKMS-built artifacts, installed artifacts,
and equal checksums. It also requires the merged provider phandles and touchscreen
inversion properties in the compiled overlay.

Migration treats 0.2.3 as a complete baseline containing the two existing modules
and its source, DTBO, and boot configuration. Version 0.2.3 is removed only after all
0.2.4 modules, source, overlay, boot token, and checksums verify. Failure of any
one of the three new module builds or installs restores the exact 0.2.3 DKMS,
module-path, overlay, and boot-configuration state. Uninstall remains scoped to
the project package, source, overlay, token, and verified backups.

The installer does not unload active display modules or load the new provider into
the current device tree. The working throwaway helpers remain loaded until reboot,
when they disappear naturally. The production overlay and modules first bind on
the newly authorized boot.

## Testing

Development follows RED/GREEN TDD. Portable behavioral tests use fake register,
clock, reset, and route operations around a small provider core. They require:

- the exact proven DSI0 PHY write sequence and one bounded lock poll;
- reverse-order unwind at each injected clock, reset, GRF, and lock failure;
- VOPB access only when GRF selects VOPB;
- VOPL access only when GRF selects VOPL;
- zero inactive-VOP accesses in every success and failure case;
- setting only `data01_swap` and blue/green plus red/blue output swaps;
- preserving unrelated register changes during apply and restore;
- idempotent apply and no-op restore behavior.

Kernel lifecycle/build tests require provider probe/defer relationships, panel
apply/restore ordering, PM callbacks and device links, warning-free `W=1` builds,
GPL-compatible metadata, the provider OF alias, and the panel's module dependency.

Touch and overlay tests require standard property parsing/reporting, both inversion
properties, the provider compatible and phandles, DSI0 still disabled in the DRM
graph, the reciprocal DSI1/panel graph, both VOP resources, and HDMI preserved.

Sandbox installer tests migrate a faithful installed 0.2.3 two-module baseline to
0.2.4 with three modules. They inject each new module's build/install/checksum
failure and require exact rollback. The complete repository suite, strict offline
validation, compiler-banner check, `git diff --check`, and relevant checkpatch run
before installation.

## Installation and Hardware Acceptance

Before installation, record the HDMI Xorg file checksum and current DKMS, DTBO,
boot-token, and module state. Install only through `scripts/install.sh`. Afterward,
require DKMS 0.2.4 installed, all three checksums matching, exactly one overlay
token, a verified boot backup, and an unchanged HDMI Xorg checksum.

Commit and push the complete reviewed branch before requesting fresh reboot
permission. Do not automatically reboot or shut down.

On the first authorized boot, with the Raspberry Pi display attached and HDMI
initially disconnected, require:

- the compatibility provider loads before the panel and reports DSI0 PHY lock;
- DSI1 connects at 800x480 and the panel shows the desktop without VPG;
- intended red, green, and blue display as red, green, and blue;
- touch reaches the correct screen location with an identity X transform;
- brightness control works;
- kernel and crash-watch logs contain no new Oops, lockup, or display-transfer
  error.

Then hot-plug HDMI and require both connectors remain usable with independent
modes, the DSI correction stays on the VOP routed to DSI1, HDMI colors remain
correct, and the protected DFRobot Xorg file remains unchanged. A later explicitly
authorized power-off/cold-start repeats the core panel and touch checks before the
release is described as hardware-validated.

## Attribution and Evidence

Production source retains the existing upstream and Radxa attribution. The DSI0
PHY sequence and DSI1 lane-swap behavior are derived from the same Rockchip and
Radxa sources already recorded in `LICENSES/UPSTREAM.md`; the VOP register fields
are documented by the RK3399 technical reference manual. The repository records
the 2026-08-20 live evidence separately from hardware acceptance claims: VPG first
proved the panel/link path, active VOPB `data01_swap` produced the desktop, the
RGB mapping test identified the cyclic channel order, and blue/green plus red/blue
swap produced user-confirmed correct RGB.
