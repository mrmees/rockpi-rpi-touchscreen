#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workdir=$(mktemp -d)

cleanup()
{
	rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

require_file()
{
	[ -f "$repo_root/$1" ] || fail "missing documentation file: $1"
}

require_text()
{
	file=$1
	text=$2
	grep -Fq "$text" "$repo_root/$file" || fail "$file is missing required text: $text"
}

check_local_links()
{
	file=$1
	directory=$(dirname -- "$file")
	links_file=$workdir/links
	{
		grep -oE '!?\[[^]]*\]\([^)]*\)' "$file" 2>/dev/null | sed 's/^.*](//; s/)$//' || true
		sed -n 's/^[[:space:]]*\[[^]]*\]:[[:space:]]*<?\([^[:space:] >]*\)>?.*/\1/p' "$file"
	} > "$links_file"
	while IFS= read -r link; do
		case $link in
		''|'#'*|http://*|https://*|mailto:*) continue ;;
		esac
		target=${link%%#*}
		[ -e "$directory/$target" ] || fail "$file has an unresolved local link: $link"
	done < "$links_file"
}

require_file README.md
require_file docs/wiring.md
require_file docs/recovery.md
grep -Fq 'sh tests/test_docs.sh' "$repo_root/Makefile" || \
	fail 'Makefile test target does not run documentation acceptance'

for document in README.md docs/wiring.md docs/recovery.md; do
	check_local_links "$repo_root/$document"
done

mkdir "$workdir/link-fixture"
: > "$workdir/link-fixture/first.md"
: > "$workdir/link-fixture/second.md"
: > "$workdir/link-fixture/image.png"
cat > "$workdir/link-fixture/sample.md" <<'EOF'
[first](first.md) and [second](second.md) ![diagram](image.png)
[local-reference]: first.md
[external-reference]: https://example.test/reference
Use [the reference][local-reference].
EOF
check_local_links "$workdir/link-fixture/sample.md"

require_text docs/wiring.md 'Power off the Rock Pi before inserting or removing the FFC.'
require_text docs/wiring.md 'GPIO pin 2 or 4 provides 5 V; GPIO pin 6 is ground.'
require_text docs/wiring.md "Follow Radxa's published FFC orientation for the Rock Pi 4B+ MIPI DSI connector."
require_text docs/recovery.md 'sudo sh scripts/uninstall.sh --offline-boot-root TARGET_ROOT'
require_text docs/recovery.md 'remove the `rockpi-4b-plus-rpi-touchscreen` token from `user_overlays`'
require_text docs/recovery.md 'mounted system root'
require_text docs/recovery.md '/mnt/rockpi/boot/armbianEnv.txt'
require_text README.md 'Touch Display 2 is not supported.'
require_text README.md 'c681d6a31c2289dbaca2e1f822bab41530fc0f68'
require_text README.md 'https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/input/touchscreen/raspits_ft5426.c'
require_text README.md 'three consecutive read or parse failures'
require_text README.md '`panel ready bit did not assert; continuing after bounded wait` is advisory'
require_text README.md 'user-confirmed correct RGB desktop video and physically correct touch'
require_text README.md 'initializes TC358762 during panel prepare'
require_text README.md 'powered the host in command mode'
require_text README.md '`prepare_prev_first`'
require_text README.md 'defers on `-ENXIO`'
require_text LICENSES/UPSTREAM.md 'during panel prepare after the DesignWare host enters command mode'
require_text docs/recovery.md 'Rollback removes only project-owned assets: the overlay token, DTBO, DKMS package, and matching runtime files.'
require_text README.md 'draft or hardware-unverified'
require_text README.md 'DKMS `0.2.6` installs exactly three production modules in provider, panel, then touch order:'
require_text README.md '`rockpi_rk3399_display_compat`, `panel_rockpi_rpi_touchscreen`, and `raspits_ft5426`'
require_text README.md 'The exact migration baseline is DKMS `0.2.5` with the same three modules in that order.'
require_text README.md 'DSI0 is disabled in the DRM graph but supplies the DSI1 PLL through the compatibility provider.'
require_text README.md 'An unsafe reversed assignment was observed with a VOP timeout and hard lock; the hard-lock mechanism itself is not proven.'
require_text README.md 'DSI is constrained to VOPL by device-tree graph identity.'
require_text README.md 'reversible `data01_swap` and blue/green plus red/blue correction'
require_text README.md '`touchscreen-inverted-x` and `touchscreen-inverted-y`'
require_text README.md 'do not require a fixed'
require_text README.md 'never uses `/dev/mem` and never reads or writes the inactive VOP.'
require_text README.md '`/etc/X11/xorg.conf.d/20-dfrobot-display.conf` is protected, and the installer does not change it.'
require_text README.md 'Mirror or extend mode, position, primary display, and output modes remain user-configurable through normal desktop display settings.'
require_text README.md 'The project installs no display-layout preset or layout command.'
require_text README.md '/usr/libexec/rockpi-rpi-touchscreen-map-touch'
require_text README.md '/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop'
require_text README.md '/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf'
require_text README.md 'xserver-command=X -core -s 0 -dpms'
require_text README.md 'Logged-in desktop power settings'
require_text README.md 'remain user-configurable'
require_text README.md 'automatically maps X11 touch to the active DSI output without changing the display layout'
require_text README.md '/usr/libexec/rockpi-rpi-touchscreen-map-touch --once'
require_text README.md 'Wayland compositor mapping is out of scope.'
require_text README.md '~/.config/autostart/rockpi-rpi-touchscreen-touch-map.desktop'
require_text README.md '/var/log.hdd/kernel-live.log'
require_text README.md '/var/log.hdd/crash-watch.log'
require_text docs/recovery.md 'exact scoped SSH rollback'
require_text docs/recovery.md 'exact scoped offline rollback'
require_text README.md 'HDMI hot-plug sequence'
require_text README.md 'does not reboot or shut down automatically'
require_text README.md 'production cold-start and reboot acceptance remains pending'
require_text README.md 'The provider owns the DSI0 PLL supplier and reversible VOP correction; the panel depends on that provider; the touch module owns touch input.'
require_text README.md 'The first authorized production boot starts with HDMI disconnected: validate DSI-1, RGB, and physical touch first, then hot-plug HDMI.'
require_text README.md 'No automatic reboot or shutdown occurs; obtain fresh authorization before any power action.'
require_text docs/recovery.md 'Exact scoped SSH rollback command: `sudo sh scripts/uninstall.sh`.'
require_text docs/recovery.md 'Exact scoped offline rollback changes only `TARGET_ROOT/boot/armbianEnv.txt`, does not call DKMS, and does not remove host files.'
require_text docs/recovery.md 'RETAIN MODIFIED: /usr/libexec/rockpi-rpi-touchscreen-map-touch'
require_text docs/recovery.md 'RETAIN MODIFIED: /etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop'
require_text docs/recovery.md 'RETAIN MODIFIED: /etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf'
require_text docs/recovery.md 'Dry-run output is predictive and makes no changes.'
require_text docs/recovery.md 'Dry-run applies the same autostart-to-mapper dependency decision as real uninstall.'
require_text docs/recovery.md 'Matching runtime assets are snapshotted in mapper-then-autostart-then-LightDM order before any removal claim.'
require_text docs/recovery.md 'A modified or newly appeared'
require_text docs/recovery.md '`RETAIN DEPENDENCY` so the entry is not stranded without its executable.'
require_text LICENSES/UPSTREAM.md 'https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/include/drm/drm_panel.h'
require_text LICENSES/UPSTREAM.md 'https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/gpu/drm/rockchip/rockchip_vop_reg.c'
if grep -Fq 'https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/gpu/drm/rockchip/rockchip_vop_reg.c' "$repo_root/LICENSES/UPSTREAM.md"; then
	fail 'attribution must not claim that the Linux v6.18 VOP table defines the RK3399 swap fields'
fi

printf 'PASS: documentation acceptance\n'
