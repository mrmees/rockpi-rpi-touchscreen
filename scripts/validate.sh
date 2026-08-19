#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

[ "${1:-}" = '--offline' ] || die "usage: $0 --offline"
require_command awk dtc fdtoverlay grep make mkdir modinfo mktemp rm sed tail tr

compatible_file=${COMPATIBLE_FILE:-/proc/device-tree/compatible}
[ -r "$compatible_file" ] || die "cannot read board compatible string: $compatible_file"
tr '\000' '\n' < "$compatible_file" | grep -Fxq 'radxa,rockpi4b-plus' || die 'this installer supports only radxa,rockpi4b-plus'
printf 'PASS: board compatible\n'

[ -d "$KERNEL_BUILD" ] || die "kernel headers not found: $KERNEL_BUILD"
printf 'PASS: kernel headers\n'

workdir=$(mktemp -d)
cleanup()
{
	rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

run_warning_free()
{
	boundary=$1
	shift
	diagnostic=$workdir/$boundary.diagnostics
	if ! "$@" > "$workdir/$boundary.stdout" 2> "$diagnostic"; then
		cat "$workdir/$boundary.stdout" "$diagnostic" >&2
		die "$boundary failed"
	fi
	if grep -Eq '(^|[[:space:]:])([Ww]arning:|Warning \()' "$workdir/$boundary.stdout" "$diagnostic"; then
		cat "$workdir/$boundary.stdout" "$diagnostic" >&2
		die "$boundary emitted warnings"
	fi
}

filter_documented_base_dtb_diagnostics()
{
	# These three diagnostics are inherited from the stock Rock Pi base DTB and
	# are accepted only while decompiling that base tree (or its merged copy).
	awk '
		/Warning \(unit_address_vs_reg\): \/usb@fe800000: node has a unit name, but no reg or ranges property$/ { next }
		/Warning \(unit_address_vs_reg\): \/usb@fe900000: node has a unit name, but no reg or ranges property$/ { next }
		/Warning \(unique_unit_address\): \/pcie@f8000000: duplicate unit-address \(also used in node \/pcie-ep@f8000000\)$/ { next }
		{ print }
	'
}

run_dtb_decompile()
{
	boundary=$1
	input_dtb=$2
	output_dts=$3
	diagnostic=$workdir/$boundary.diagnostics
	if ! dtc -I dtb -O dts -o "$output_dts" "$input_dtb" > "$workdir/$boundary.stdout" 2> "$diagnostic"; then
		cat "$workdir/$boundary.stdout" "$diagnostic" >&2
		die "$boundary failed"
	fi
	filter_documented_base_dtb_diagnostics < "$diagnostic" > "$workdir/$boundary.unfiltered"
	if [ -s "$workdir/$boundary.stdout" ] || [ -s "$workdir/$boundary.unfiltered" ]; then
		cat "$workdir/$boundary.stdout" "$workdir/$boundary.unfiltered" >&2
		die "$boundary emitted unexpected diagnostics"
	fi
}

extract_named_node()
{
	node=$1
	awk -v node="$node" '
		!found && $0 ~ "^[[:space:]]*" node "[[:space:]]*\\{" { found = 1 }
		found {
			print
			line = $0
			opens = gsub(/\{/, "{", line)
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
			if (depth == 0) exit
		}
		END { if (!found || depth != 0) exit 1 }
	'
}

node_from_file()
{
	file=$1
	node=$2
	extract_named_node "$node" < "$file"
}

require_text()
{
	text=$1
	needle=$2
	message=$3
	printf '%s\n' "$text" | grep -Fq "$needle" || die "$message"
}

property_phandle()
{
	property=$1
	sed -n "s/^[[:space:]]*${property} = <\\(0x[0-9a-fA-F]*\\)>;.*/\\1/p" | head -n 1
}

require_equal()
{
	actual=$1
	expected=$2
	message=$3
	[ -n "$actual" ] && [ "$actual" = "$expected" ] || die "$message (got $actual, expected $expected)"
}

repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
run_warning_free module-clean make -C "$repo_root" KDIR="$KERNEL_BUILD" clean
run_warning_free module-build "$script_dir/dkms-make.sh" "$KERNEL_RELEASE" \
	make -C "$repo_root" KDIR="$KERNEL_BUILD" W=1 modules
module_file=$repo_root/raspits_ft5426.ko
[ "$(modinfo -F license "$module_file")" = 'GPL v2' ] || die 'module metadata is missing GPL v2 license'
modinfo -F alias "$module_file" | grep -Fxq 'of:N*T*Craspits_ft5426' || die 'module metadata is missing device-tree alias'
printf 'PASS: module build and metadata\n'

dtb=$(active_dtb)
[ -f "$dtb" ] || die "active DTB not found: $dtb"
run_dtb_decompile base-dtb "$dtb" "$workdir/base.dts"
for symbol in mipi_dsi mipi_dsi1 mipi1_in_vopl mipi1_in_vopb vopl_out_mipi1 i2c1; do
	grep -Eq "^[[:space:]]*$symbol[[:space:]]*=" "$workdir/base.dts" || die "active DTB is missing symbol: $symbol"
done
printf 'PASS: active DTB symbols\n'

build_dir=${BUILD_DIR:-$repo_root/build}
mkdir -p "$build_dir"
overlay=$repo_root/overlays/$OVERLAY_NAME.dts
dtbo=$build_dir/$OVERLAY_NAME.dtbo
run_warning_free overlay-compile dtc -@ -I dts -O dtb -o "$dtbo" "$overlay"
printf 'PASS: overlay compile\n'
run_warning_free overlay-apply fdtoverlay -i "$dtb" -o "$workdir/merged.dtb" "$dtbo"
run_dtb_decompile merged-dtb "$workdir/merged.dtb" "$workdir/merged.dts"
printf 'PASS: overlay apply\n'

dsi0=$(node_from_file "$workdir/merged.dts" 'dsi@ff960000')
dsi1=$(node_from_file "$workdir/merged.dts" 'dsi@ff968000')
i2c1=$(node_from_file "$workdir/merged.dts" 'i2c@ff110000')
vopl=$(node_from_file "$workdir/merged.dts" 'vop@ff8f0000')
hdmi=$(node_from_file "$workdir/merged.dts" 'hdmi@ff940000')
panel=$(printf '%s\n' "$i2c1" | extract_named_node 'panel@45')
touch=$(printf '%s\n' "$i2c1" | extract_named_node 'touchscreen@38')

require_text "$dsi0" 'status = "okay";' 'merged DSI0 is not enabled'
require_text "$dsi1" 'status = "okay";' 'merged DSI1 is not enabled'
printf 'PASS: DSI0 and DSI1 enabled\n'
require_text "$panel" 'compatible = "raspberrypi,7inch-touchscreen-panel";' 'merged panel compatible is missing'
require_text "$panel" 'reg = <0x45>;' 'merged panel address is missing'
require_text "$touch" 'compatible = "raspits_ft5426";' 'merged touch compatible is missing'
require_text "$touch" 'reg = <0x38>;' 'merged touch address is missing'
require_text "$touch" 'touchscreen-size-x = <0x320>;' 'merged touch X size is missing'
require_text "$touch" 'touchscreen-size-y = <0x1e0>;' 'merged touch Y size is missing'
printf 'PASS: I2C1 panel and touch nodes\n'

vopl_endpoint=$(printf '%s\n' "$vopl" | extract_named_node 'endpoint@3')
dsi1_vopb_input=$(printf '%s\n' "$dsi1" | extract_named_node 'endpoint@0')
dsi1_input=$(printf '%s\n' "$dsi1" | extract_named_node 'endpoint@1')
require_text "$dsi1_vopb_input" 'status = "disabled";' 'DSI1 big-VOP input is not disabled'
require_text "$dsi1_input" 'status = "okay";' 'DSI1 little-VOP input is not enabled'
require_equal "$(printf '%s\n' "$vopl_endpoint" | property_phandle remote-endpoint)" "$(printf '%s\n' "$dsi1_input" | property_phandle phandle)" 'little-VOP output does not connect to DSI1 input'
require_equal "$(printf '%s\n' "$dsi1_input" | property_phandle remote-endpoint)" "$(printf '%s\n' "$vopl_endpoint" | property_phandle phandle)" 'DSI1 input does not connect back to little-VOP output'
dsi1_output_port=$(printf '%s\n' "$dsi1" | extract_named_node 'port@1')
dsi1_output=$(printf '%s\n' "$dsi1_output_port" | extract_named_node 'endpoint')
panel_port=$(printf '%s\n' "$panel" | extract_named_node 'port')
panel_input=$(printf '%s\n' "$panel_port" | extract_named_node 'endpoint')
require_equal "$(printf '%s\n' "$dsi1_output" | property_phandle remote-endpoint)" "$(printf '%s\n' "$panel_input" | property_phandle phandle)" 'DSI1 output does not connect to panel input'
require_equal "$(printf '%s\n' "$panel_input" | property_phandle remote-endpoint)" "$(printf '%s\n' "$dsi1_output" | property_phandle phandle)" 'panel input does not connect back to DSI1 output'
printf 'PASS: little-VOP to DSI1 to panel graph\n'

require_text "$hdmi" 'status = "okay";' 'merged tree does not preserve HDMI'
printf 'PASS: HDMI unchanged\n'
printf 'PASS: offline validation\n'
