# Safe Dual-Display Routing and Touch Mapping Design

## Background

DKMS 0.2.4 boots the original Raspberry Pi 7-inch Touch Display on the
Rock Pi 4B+ with correct RGB video and touch. A cold DSI-only boot passed, and
HDMI and DSI can also operate concurrently. Dual-display testing nevertheless
found a route-dependent failure:

- HDMI on RK3399 VOPB and DSI on VOPL works.
- DSI on VOPB and HDMI on VOPL can leave one output lit black.
- The failed assignment produced a `gamma LUT update timeout` from
  `ff900000.vop`; repeated display experiments were followed by a hard lock.
- Persistent crash telemetry showed about 1.2 GiB of available memory, about
  1 GiB of free swap, zero memory pressure, and no OOM event immediately
  before the lock. Memory exhaustion is not the working hypothesis.
- Pinning HDMI to CRTC 0/VOPB and DSI to CRTC 1/VOPL produced a stable
  1824x600 extended desktop with both outputs physically confirmed.

The live clock tree maps CRTC 0's 40 MHz mode to `ff900000.vop` (VOPB) and
CRTC 1's approximately 25.8 MHz mode to `ff8f0000.vop` (VOPL). The successful
manual test therefore confirms the board's intended HDMI-on-VOPB and
DSI-on-VOPL pairing.

The overlay already marks the DSI1 VOPB input endpoint disabled and the VOPL
input endpoint enabled. That is insufficient on Linux 6.18: Rockchip DSI sets
the encoder mask with `drm_of_find_possible_crtcs()`, and that generic helper
walks every endpoint without filtering on the endpoint's `status`. X therefore
advertises both CRTCs for DSI and may choose the unsafe reversed pairing.

## Goals

- Make the DSI encoder advertise only VOPL on the supported Rock Pi 4B+ tree.
- Preserve the normal DRM and desktop interfaces for choosing mirror versus
  extended mode, output placement, primary display, and output modes.
- Map the `Raspberry Pi 7-inch Touchscreen` X11 input device to the active
  `DSI-1` output after login and after RandR layout changes.
- Keep HDMI enabled and preserve
  `/etc/X11/xorg.conf.d/20-dfrobot-display.conf` byte-for-byte.
- Deliver the corrected overlay and touch-mapping assets as an immutable,
  transactional DKMS 0.2.5 migration from the installed 0.2.4 release.
- Preserve safe offline recovery and never reboot or shut down automatically.

## Non-goals

- Choose or persist a desktop layout on the user's behalf.
- Force either output to be primary, left, right, mirrored, or extended.
- Change the DFRobot HDMI mode or Xorg monitor configuration.
- Change DPMS, screen blanking, login-manager policy, or desktop power policy.
- Replace or patch the kernel's complete `rockchipdrm` module.
- Add a userspace service that rewrites output modes or CRTC assignments.
- Diagnose the remaining hard-lock mechanism beyond preventing the route that
  preceded the observed VOP timeout.
- Support Wayland compositor input mapping, Touch Display 2, other Rock Pi
  models, or kernels other than the project's exact supported kernel/header
  pair.

## Architecture

### Device-tree route filter

The overlay will keep the real DSI1-to-VOPL graph unchanged. The DSI input
endpoint whose endpoint ID selects VOPB will instead point to a project-owned
inert graph endpoint. That inert endpoint belongs to a plain port under the
existing `rockpi-display-compat` node and is not the port of any registered DRM
CRTC.

For the DSI encoder, `drm_of_find_possible_crtcs()` will then observe:

1. the VOPB-selecting DSI endpoint, whose remote inert port maps to no CRTC;
2. the VOPL-selecting DSI endpoint, whose remote port maps to VOPL.

The resulting encoder mask contains VOPL only. When the encoder is active,
`drm_of_encoder_active_endpoint()` skips the inert port and selects the real
VOPL endpoint ID, so the Rockchip DSI glue writes the little-VOP mux value.
The correction provider continues reading the live GRF mux after the CRTC is
active and therefore applies its reversible lane/color correction to VOPL.

The VOPB output endpoint remains pointed at the DSI component. This deliberate
one-way graph asymmetry preserves Rockchip DRM component discovery while
preventing the DSI encoder's reverse graph walk from treating VOPB as an
eligible CRTC. Redirecting the VOPB output itself to the inert node is forbidden:
the DRM master could then wait for the compatibility provider as though it were
a DRM component.

No literal CRTC index is stored in the overlay or driver. The constraint is
expressed by device-tree graph identity, so registration-order changes do not
turn CRTC number 0 or 1 into a hidden ABI.

HDMI graph endpoints remain unchanged. With DSI consuming VOPL in a two-output
layout, DRM necessarily assigns HDMI to VOPB. With only one connected output,
normal DRM policy remains in control.

### User-controlled display layout

The project will not install an `xrandr` layout command, Xorg monitor position,
LightDM display-setup script, or desktop-specific display profile. The user's
desktop remains responsible for:

- mirror versus extended mode;
- primary output;
- relative output position;
- supported mode selection;
- saving and restoring the user's chosen layout.

The route filter makes those choices safe by removing only the unsupported DSI
pipeline from the DRM encoder mask.

### X11 touch-to-output mapper

The project will install one POSIX shell helper with two modes:

- `--once` maps the exact touchscreen device to active output `DSI-1` once.
- `--watch` performs the initial mapping, subscribes to RandR events, and
  repeats the same mapping after a screen or output-layout notification.

The helper inherits `DISPLAY` and `XAUTHORITY` from the user's graphical
session. It must not contain a LightDM username, display number, or authority
path. A system-wide XDG autostart entry launches `--watch` in X11 sessions.
Wayland sessions exit successfully without changing input state because the
compositor owns absolute-device output mapping there.

For each mapping attempt, the helper will:

1. verify that `xrandr`, `xinput`, `xev`, and `stdbuf` are available;
2. require exactly one XInput device named
   `Raspberry Pi 7-inch Touchscreen`;
3. require `DSI-1` to be connected and active in the current RandR state;
4. call `xinput map-to-output` for that numeric input ID and `DSI-1`;
5. never invoke an `xrandr` mutation or write a fixed transformation matrix.

`xinput map-to-output` derives the transformation from the user's current
screen geometry. Kernel axis inversion remains the physical orientation fix;
the userspace mapping adds only the scaling and translation needed to place
touches inside DSI's current desktop rectangle.

The watcher uses line-buffered `xev -root -event randr` output as its event
source. It remaps only on RandR event headers, not every output line. If the X
server disappears, the helper exits instead of busy-looping. A missing or
inactive DSI output is a no-op so HDMI-only recovery sessions remain usable.
An ambiguous duplicate touch-device name is an error and must not select an
arbitrary device.

The mapper changes only the XInput Coordinate Transformation Matrix. It never
changes output modes, positions, primary state, CRTC selection, DPMS, pointer
acceleration, or other input properties.

## Packaging and ownership

The immutable package version becomes `rockpi-rpi-touchscreen/0.2.5`. It still
builds exactly these three modules in dependency order:

1. `rockpi_rk3399_display_compat`
2. `panel_rockpi_rpi_touchscreen`
3. `raspits_ft5426`

The module source need not change solely for this fix. The release changes the
overlay, userspace touch mapper, autostart asset, validation, packaging tests,
and documentation.

In addition to the existing DKMS source, DTBO, boot token, and backup, 0.2.5
owns these runtime assets:

- `/usr/libexec/rockpi-rpi-touchscreen-map-touch`
- `/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop`

The installer preflights both destination paths before any mutation. An
unrelated pre-existing file at either path fails closed instead of being
overwritten. Migration treats 0.2.4 as the exact prior three-module release.
The new release is considered installed only after DKMS status and all module,
source, DTBO, boot, mapper, and autostart checksums verify.

Any failure restores the exact pre-install DKMS, module-path, DTBO, boot-token,
and runtime-asset state. If restoration cannot be verified, recovery material
is retained and reported. Retirement of 0.2.4 occurs only after complete 0.2.5
verification.

Uninstall removes a runtime asset only when it matches the project's installed
content. A locally modified project asset is retained and reported rather than
silently deleted. Dry-run output lists both runtime paths and all existing
owned paths without changing them. Offline overlay-token recovery remains
scoped to the boot token and does not require an X server.

The installer and uninstaller continue hashing the protected DFRobot Xorg file
before and after every transaction. Neither script may create, replace, edit,
or remove that file.

## Validation and tests

### Overlay and offline validation

The overlay integration test compiles the real DTBO, applies it to the exact
active Rock Pi DTB, and verifies the merged tree. It requires:

- DSI0 remains disabled as a DRM output;
- DSI1 and the project panel path remain enabled;
- the VOPL DSI1 endpoint and DSI VOPL input remain reciprocal and enabled;
- the DSI VOPB input points to the project inert endpoint;
- the inert endpoint's port is not either VOP output port and is not listed in
  `display-subsystem/ports`;
- the VOPB output still points to the DSI component for component discovery;
- both HDMI VOP routes and HDMI status are unchanged;
- the provider resources, panel, touch properties, and touch orientation remain
  valid.

The strict validator repeats these requirements against the active merged DTB
and rejects missing, duplicated, self-referential, or wrongly placed inert
endpoints. A route that still lets the DSI VOPB input resolve to either VOP port
fails validation before boot mutation.

### Touch mapper tests

A new shell integration test runs the real mapping helper against controlled
fake `xrandr`, `xinput`, and RandR-event commands. The fakes model the complete
command outputs consumed by the helper, and the assertions observe the
helper's command boundary and exit status. Tests cover:

- one active DSI output and one exact touch device maps by numeric ID;
- arbitrary DSI positions and framebuffer sizes still produce the same
  `xinput map-to-output ID DSI-1` boundary call without any output mutation;
- mirror, left-of, right-of, above, and primary-display choices do not alter
  helper behavior;
- inactive or disconnected DSI is a successful no-op;
- HDMI-only operation is a successful no-op;
- missing X11 tools and duplicate touch names fail with actionable diagnostics;
- a RandR event triggers one new mapping attempt;
- watcher termination with the X server does not spin or restart indefinitely;
- Wayland sessions are untouched.

The fake `xrandr` rejects every argument other than a read-only query. This
makes any future attempt by the mapper to control layout fail the test.

### Installer and rollback tests

The script sandbox models 0.2.4 as the exact old three-module release and
0.2.5 as the exact new three-module release plus both runtime assets. It tests:

- clean installation and idempotent rerun;
- immutable-source mismatch;
- pre-existing unrelated runtime assets;
- mapper or autostart staging, install, checksum, and permission failure;
- failure before and after boot-token mutation;
- failure during old-release retirement;
- exact rollback of added, built, and installed DKMS states;
- exact rollback of absent and pre-existing runtime-asset states;
- dry-run and normal uninstall;
- locally modified runtime assets are retained and reported;
- protected HDMI Xorg content and checksum never change.

### Hardware acceptance

After installation and a separately authorized reboot:

1. Boot with DSI connected and validate video, color, backlight, and touch.
2. Verify `xrandr --verbose` advertises only the VOPL-backed CRTC for DSI.
3. Attach HDMI and choose both mirror and extended layouts through ordinary
   user settings without a project layout command.
4. Confirm both layouts retain video on both outputs and never reverse the
   DSI/HDMI VOP pairing.
5. Place DSI on different sides of HDMI and confirm physical touch stays mapped
   to DSI after each RandR change.
6. Confirm the protected HDMI Xorg checksum is unchanged.
7. Inspect persistent logs for a new VOP gamma timeout, command-FIFO error,
   Oops, lockup, panic, or OOM event.

The unsafe reversed route is not deliberately reproduced after the route
filter is installed. Acceptance proves it is absent from the advertised DSI
CRTC mask instead.

No install, validation, or acceptance command reboots, shuts down, reads VOP
registers through `/dev/mem`, or accesses an inactive VOP.

## Documentation

The README will replace the 0.2.4 pending-acceptance language with an accurate
0.2.5 status and explain the distinction between hardware route safety and
user-controlled desktop layout. It will document the mapper, its X11 scope,
its owned files, and how to disable or invoke it manually.

Recovery documentation will list the two runtime assets, their modified-file
retention behavior, and the exact 0.2.5 DKMS commands. Wiring documentation
will continue to describe the original display and three-module stack without
claiming Touch Display 2 support.

The release remains hardware-unverified until the 0.2.5 reboot, dual-display,
touch-remapping, logging, and explicit shutdown/cold-start checkpoints pass.
