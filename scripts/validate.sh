#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

[ "${1:-}" = '--offline' ] || die "usage: $0 --offline"
require_command awk dtc fdtoverlay grep make mkdir modinfo mktemp rm sed tail tr

compatible_file=${COMPATIBLE_FILE:-/proc/device-tree/compatible}
[ -r "$compatible_file" ] || die "cannot read board compatible string: $compatible_file"
tr '\000' '\n' < "$compatible_file" | grep -Fxq 'radxa,rockpi4b-plus' ||
	die 'this installer supports only radxa,rockpi4b-plus'
printf 'PASS: board compatible\n'

[ -d "$KERNEL_BUILD" ] || die "kernel headers not found: $KERNEL_BUILD"
printf 'PASS: kernel headers\n'

repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
make -C "$repo_root" clean
make -C "$repo_root" KDIR="$KERNEL_BUILD" W=1 modules
module_file=$repo_root/raspits_ft5426.ko
[ "$(modinfo -F license "$module_file")" = 'GPL v2' ] || die 'module metadata is missing GPL v2 license'
modinfo -F alias "$module_file" | grep -Fxq 'of:N*T*Craspits_ft5426' ||
	die 'module metadata is missing device-tree alias'
printf 'PASS: module build and metadata\n'

dtb=$(active_dtb)
[ -f "$dtb" ] || die "active DTB not found: $dtb"
workdir=$(mktemp -d)
cleanup()
{
	rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM
dtc -I dtb -O dts -o "$workdir/base.dts" "$dtb"
for symbol in mipi_dsi mipi_dsi1 mipi1_in_vopl mipi1_in_vopb vopl_out_mipi1 i2c1; do
	grep -Eq "^[[:space:]]*$symbol[[:space:]]*=" "$workdir/base.dts" || die "active DTB is missing symbol: $symbol"
done
printf 'PASS: active DTB symbols\n'

build_dir=${BUILD_DIR:-$repo_root/build}
mkdir -p "$build_dir"
overlay=$repo_root/overlays/$OVERLAY_NAME.dts
dtbo=$build_dir/$OVERLAY_NAME.dtbo
dtc -@ -I dts -O dtb -o "$dtbo" "$overlay"
printf 'PASS: overlay compile\n'
fdtoverlay -i "$dtb" -o "$workdir/merged.dtb" "$dtbo"
dtc -I dtb -O dts -o "$workdir/merged.dts" "$workdir/merged.dtb"
printf 'PASS: overlay apply\n'

node_text()
{
	node_name=$1
	awk -v node_name="$node_name" '
		$0 ~ "^[[:space:]]*" node_name "[[:space:]]*\\{" { found = 1 }
		found {
			print
			opens = gsub(/\{/, "{")
			closes = gsub(/\}/, "}")
			depth += opens - closes
			if (depth == 0) exit
		}
	' "$workdir/merged.dts"
}

dsi1=$(node_text 'dsi@ff968000')
panel=$(node_text 'panel@45')
touch=$(node_text 'touchscreen@38')
printf '%s\n' "$dsi1" | grep -Fq 'status = "okay";' || die 'merged DSI1 is not enabled'
printf '%s\n' "$panel" | grep -Fq 'compatible = "raspberrypi,7inch-touchscreen-panel";' ||
	die 'merged tree is missing panel at 0x45'
printf '%s\n' "$touch" | grep -Fq 'compatible = "raspits_ft5426";' ||
	die 'merged tree is missing touch controller at 0x38'
printf 'PASS: merged DSI, panel, and touch nodes\n'

hdmi=$(node_text 'hdmi@ff940000')
printf '%s\n' "$hdmi" | grep -Fq 'status = "okay";' || die 'merged tree does not preserve HDMI'
printf 'PASS: HDMI unchanged\n'
printf 'PASS: offline validation\n'
