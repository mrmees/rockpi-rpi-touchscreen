#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

[ "${1:-}" = '--offline' ] || die "usage: $0 --offline"
require_supported_kernel_release
require_command awk cat chmod cp dirname dtc fdtoverlay grep head ln make mkdir modinfo mktemp mv rm sed sha256sum tail tr

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

direct_property_value()
{
	property=$1
	awk -v property="$property" '
		{
			line = $0
			if (depth == 1 && line ~ "^[[:space:]]*" property "[[:space:]]*=") {
				sub("^[[:space:]]*" property "[[:space:]]*=[[:space:]]*", "", line)
				sub(";[[:space:]]*$", "", line)
				print line
				exit
			}
			opens = gsub(/\{/, "{", line)
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
		}
	'
}

require_direct_property()
{
	text=$1
	property=$2
	expected=$3
	message=$4
	actual=$(printf '%s\n' "$text" | direct_property_value "$property")
	[ "$actual" = "$expected" ] || die "$message (got ${actual:-missing}, expected $expected)"
}

require_direct_boolean()
{
	text=$1
	property=$2
	message=$3
	printf '%s\n' "$text" | awk -v property="$property" '
		{
			line = $0
			if (depth == 1 && line ~ "^[[:space:]]*" property "[[:space:]]*;[[:space:]]*$")
				found = 1
			opens = gsub(/\{/, "{", line)
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
		}
		END { exit found ? 0 : 1 }
	' || die "$message"
}

property_phandle()
{
	property=$1
	sed -n "s/^[[:space:]]*${property} = <\\(0x[0-9a-fA-F]*\\)>;.*/\\1/p" | head -n 1
}

property_cell()
{
	property=$1
	cell=$2
	sed -n "s/^[[:space:]]*${property} = <\\([^>]*\\)>;.*/\\1/p" |
		awk -v cell="$cell" 'NR == 1 { print $cell; exit }'
}

property_cell_number()
{
	property=$1
	cell=$2
	value=$(property_cell "$property" "$cell")
	case $value in
	0x*) printf '%d\n' "$((value))" ;;
	*) printf '%d\n' "$value" ;;
	esac
}

property_cells()
{
	property=$1
	sed -n "s/^[[:space:]]*${property} = <\\([^>]*\\)>;.*/\\1/p" |
		awk 'NR == 1 { for (i = 1; i <= NF; i++) print $i; exit }'
}

count_direct_port_children()
{
	awk '
		{
			line = $0
			if (depth == 1 && line ~ "^[[:space:]]*port(@[^[:space:]{]*)?[[:space:]]*\\{")
				count++
			opens = gsub(/\{/, "{", line)
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
		}
		END { print count + 0 }
	'
}

require_equal()
{
	actual=$1
	expected=$2
	message=$3
	[ -n "$actual" ] && [ "$actual" = "$expected" ] || die "$message (got $actual, expected $expected)"
}

require_distinct()
{
	actual=$1
	other=$2
	message=$3
	[ -n "$actual" ] && [ -n "$other" ] && [ "$actual" != "$other" ] ||
		die "$message (got $actual, conflicting phandle $other)"
}

repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
touch_mapper=$repo_root/scripts/map-touchscreen.sh
touch_autostart=$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop

[ -f "$touch_mapper" ] || die 'touch mapper source is missing'
[ -x "$touch_mapper" ] || die 'touch mapper source is not executable'
if ! sh -n "$touch_mapper"; then
	die 'touch mapper source has invalid shell syntax'
fi
[ -f "$touch_autostart" ] || die 'touch autostart source is missing'

first_autostart_line=$(sed -n '1p' "$touch_autostart")
autostart_group_count=$(grep -Ec '^\[[^][]+\]$' "$touch_autostart" || true)
desktop_group_count=$(grep -Fxc '[Desktop Entry]' "$touch_autostart" || true)
[ "$first_autostart_line" = '[Desktop Entry]' ] &&
	[ "$autostart_group_count" -eq 1 ] && [ "$desktop_group_count" -eq 1 ] ||
	die 'touch autostart must contain exactly one [Desktop Entry] group'

expected_exec='Exec=/usr/libexec/rockpi-rpi-touchscreen-map-touch --watch'
exec_count=$(grep -c '^Exec=' "$touch_autostart" || true)
exact_exec_count=$(grep -Fxc "$expected_exec" "$touch_autostart" || true)
[ "$exec_count" -eq 1 ] && [ "$exact_exec_count" -eq 1 ] ||
	die 'touch autostart Exec is not exact'

expected_try_exec='TryExec=/usr/libexec/rockpi-rpi-touchscreen-map-touch'
try_exec_count=$(grep -c '^TryExec=' "$touch_autostart" || true)
exact_try_exec_count=$(grep -Fxc "$expected_try_exec" "$touch_autostart" || true)
[ "$try_exec_count" -eq 1 ] && [ "$exact_try_exec_count" -eq 1 ] ||
	die 'touch autostart TryExec is not exact'

canonical_touch_mapper_sha256=b2f332b54ad003da2e1f783fffb3a8edcb8640df75a77b3c16e54b8ccbdfa904
touch_mapper_checksum_record=$(sha256sum -- "$touch_mapper") ||
	die 'cannot hash touch mapper source'
[ "${touch_mapper_checksum_record%% *}" = "$canonical_touch_mapper_sha256" ] ||
	die 'touch mapper does not match canonical project artifact'
printf 'PASS: packaged touch mapper and autostart boundaries\n'

run_warning_free module-clean make -C "$repo_root" KDIR="$KERNEL_BUILD" clean
run_warning_free module-build "$script_dir/dkms-make.sh" "$KERNEL_RELEASE" \
	make -C "$repo_root" KDIR="$KERNEL_BUILD" W=1 modules
for module_name in $MODULE_NAMES; do
	module_file=$repo_root/$module_name.ko
	[ -f "$module_file" ] || die "module build did not produce $module_name.ko"
	[ "$(modinfo -F license "$module_file")" = 'GPL v2' ] ||
		die "$module_name module metadata is missing GPL v2 license"
	case $(modinfo -F vermagic "$module_file") in
	"$KERNEL_RELEASE "*) ;;
	*) die "$module_name module vermagic does not match $KERNEL_RELEASE" ;;
	esac
	case $module_name in
	rockpi_rk3399_display_compat)
		expected_alias='of:N*T*Crockpi,rk3399-dsi1-rpi-touchscreen-compat'
		metadata_error='display compatibility provider module metadata is missing project device-tree alias'
		;;
	raspits_ft5426)
		expected_alias='of:N*T*Craspits_ft5426'
		metadata_error='touch module metadata is missing expected device-tree alias'
		;;
	panel_rockpi_rpi_touchscreen)
		expected_alias='of:N*T*Crockpi,rpi-7inch-touchscreen-panel'
		metadata_error='panel module metadata is missing project device-tree alias'
		;;
	*) die "no metadata policy for module: $module_name" ;;
	esac
	modinfo -F alias "$module_file" | grep -Fxq "$expected_alias" ||
		die "$metadata_error"
done
printf 'PASS: all three module builds and metadata\n'

dtb=$(active_dtb)
[ -f "$dtb" ] || die "active DTB not found: $dtb"
run_dtb_decompile base-dtb "$dtb" "$workdir/base.dts"
for symbol in mipi_dsi mipi_dsi1 mipi1_in_vopl mipi1_in_vopb vopl_out_mipi1 i2c1 grf vopb vopl power; do
	grep -Eq "^[[:space:]]*$symbol[[:space:]]*=" "$workdir/base.dts" || die "active DTB is missing symbol: $symbol"
done
printf 'PASS: active DTB symbols\n'

build_dir=${BUILD_DIR:-$repo_root/build}
mkdir -p "$build_dir"
overlay=$repo_root/overlays/$OVERLAY_NAME.dts
dtbo=$build_dir/$OVERLAY_NAME.dtbo
temporary_dtbo=$workdir/$OVERLAY_NAME.dtbo
# The standalone overlay cannot expose the external power controller's
# #power-domain-cells to dtc. The merged-tree checks below validate both cells.
run_warning_free overlay-compile dtc -Wno-power_domains_property -@ -I dts -O dtb -o "$temporary_dtbo" "$overlay"
atomic_install_file "$temporary_dtbo" "$dtbo"
printf 'PASS: overlay compile\n'
run_warning_free overlay-apply fdtoverlay -i "$dtb" -o "$workdir/merged.dtb" "$dtbo"
run_dtb_decompile merged-dtb "$workdir/merged.dtb" "$workdir/merged.dts"
printf 'PASS: overlay apply\n'

dsi0=$(node_from_file "$workdir/merged.dts" 'dsi@ff960000')
dsi1=$(node_from_file "$workdir/merged.dts" 'dsi@ff968000')
i2c1=$(node_from_file "$workdir/merged.dts" 'i2c@ff110000')
grf=$(node_from_file "$workdir/merged.dts" 'syscon@ff770000')
vopb=$(node_from_file "$workdir/merged.dts" 'vop@ff900000')
vopl=$(node_from_file "$workdir/merged.dts" 'vop@ff8f0000')
display_subsystem=$(node_from_file "$workdir/merged.dts" 'display-subsystem')
power=$(node_from_file "$workdir/merged.dts" 'power-controller')
hdmi=$(node_from_file "$workdir/merged.dts" 'hdmi@ff940000')
provider_count=$(grep -Fc 'compatible = "rockpi,rk3399-dsi1-rpi-touchscreen-compat";' "$workdir/merged.dts" || true)
[ "$provider_count" -eq 1 ] || die "merged tree has $provider_count display compatibility providers, expected 1"
provider=$(node_from_file "$workdir/merged.dts" 'rockpi-display-compat')
panel=$(printf '%s\n' "$i2c1" | extract_named_node 'panel@45')
touch=$(printf '%s\n' "$i2c1" | extract_named_node 'touchscreen@38')

require_direct_property "$dsi0" status '"disabled"' 'unused merged DSI0 is not disabled'
require_direct_property "$dsi1" status '"okay"' 'merged DSI1 is not enabled'
# The stock tree retains DSI0 input endpoints; reject an output endpoint that
# would attach a panel while allowing those disabled-host input descriptions.
if dsi0_output_port=$(printf '%s\n' "$dsi0" | extract_named_node 'port@1' 2>/dev/null); then
	if printf '%s\n' "$dsi0_output_port" | grep -Eq '^[[:space:]]*endpoint(@[^[:space:]{]+)?[[:space:]]*\{'; then
		die 'unused merged DSI0 has an output graph'
	fi
fi
printf 'PASS: unused DSI0 disabled without an output graph and DSI1 enabled\n'

require_direct_property "$provider" compatible '"rockpi,rk3399-dsi1-rpi-touchscreen-compat"' 'merged display compatibility provider is missing its compatible'
require_direct_property "$provider" status '"okay"' 'merged display compatibility provider is not enabled'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,dsi0)" "$(printf '%s\n' "$dsi0" | property_phandle phandle)" 'display compatibility provider DSI0 phandle is wrong'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,dsi1)" "$(printf '%s\n' "$dsi1" | property_phandle phandle)" 'display compatibility provider DSI1 phandle is wrong'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,grf)" "$(printf '%s\n' "$grf" | property_phandle phandle)" 'display compatibility provider GRF phandle is wrong'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,vopb)" "$(printf '%s\n' "$vopb" | property_phandle phandle)" 'display compatibility provider big-VOP phandle is wrong'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,vopl)" "$(printf '%s\n' "$vopl" | property_phandle phandle)" 'display compatibility provider little-VOP phandle is wrong'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 1)" "$(printf '%s\n' "$power" | property_phandle phandle)" 'display compatibility provider VIO controller phandle is wrong'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 2)" '0x0f' 'display compatibility provider power-domain is not RK3399_PD_VIO'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 1)" "$(printf '%s\n' "$dsi0" | property_cell power-domains 1)" 'display compatibility provider and DSI0 use different power controllers'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 2)" "$(printf '%s\n' "$dsi0" | property_cell power-domains 2)" 'display compatibility provider and DSI0 use different power domains'
printf 'PASS: display compatibility provider resources\n'

require_text "$panel" 'compatible = "rockpi,rpi-7inch-touchscreen-panel";' 'merged project panel compatible is missing'
if printf '%s\n' "$panel" | grep -Fq 'compatible = "raspberrypi,7inch-touchscreen-panel";'; then
	die 'merged tree retains the upstream panel compatible'
fi
require_text "$panel" 'reg = <0x45>;' 'merged panel address is missing'
require_equal "$(printf '%s\n' "$panel" | property_phandle rockpi,display-compat)" "$(printf '%s\n' "$provider" | property_phandle phandle)" 'merged panel display compatibility provider link is wrong'
require_text "$touch" 'compatible = "raspits_ft5426";' 'merged touch compatible is missing'
require_text "$touch" 'reg = <0x38>;' 'merged touch address is missing'
require_text "$touch" 'touchscreen-size-x = <0x320>;' 'merged touch X size is missing'
require_text "$touch" 'touchscreen-size-y = <0x1e0>;' 'merged touch Y size is missing'
require_direct_boolean "$touch" touchscreen-inverted-x 'merged touch X inversion is missing'
require_direct_boolean "$touch" touchscreen-inverted-y 'merged touch Y inversion is missing'
printf 'PASS: I2C1 panel and touch nodes\n'

vopl_endpoint=$(printf '%s\n' "$vopl" | extract_named_node 'endpoint@3')
vopb_endpoint=$(printf '%s\n' "$vopb" | extract_named_node 'endpoint@3')
dsi1_vopb_input=$(printf '%s\n' "$dsi1" | extract_named_node 'endpoint@0')
dsi1_input=$(printf '%s\n' "$dsi1" | extract_named_node 'endpoint@1')
route_filter=$(node_from_file "$workdir/merged.dts" 'rockpi-dsi1-vopb-route-filter') ||
	die 'merged tree is missing the DSI1 VOPB route filter'
route_filter_ports=$(printf '%s\n' "$route_filter" | extract_named_node 'ports')
filter_port0=$(printf '%s\n' "$route_filter_ports" | extract_named_node 'port@0')
filter_port1=$(printf '%s\n' "$route_filter_ports" | extract_named_node 'port@1')
filter_dsi_sink=$(printf '%s\n' "$filter_port0" | extract_named_node 'endpoint')
filter_vopb_sink=$(printf '%s\n' "$filter_port1" | extract_named_node 'endpoint')

require_direct_property "$route_filter" status '"disabled"' 'DSI1 VOPB route filter is not disabled'
require_equal "$(printf '%s\n' "$route_filter_ports" | count_direct_port_children)" '2' 'DSI1 VOPB route filter does not have exactly two ports'
require_equal "$(printf '%s\n' "$filter_port0" | property_cell_number reg 1)" '0' 'DSI1 VOPB route filter port 0 reg is wrong'
require_equal "$(printf '%s\n' "$filter_port1" | property_cell_number reg 1)" '1' 'DSI1 VOPB route filter port 1 reg is wrong'
require_direct_property "$vopb_endpoint" status '"disabled"' 'VOPB DSI output is not disabled'
require_equal "$(printf '%s\n' "$dsi1_vopb_input" | property_phandle remote-endpoint)" "$(printf '%s\n' "$filter_dsi_sink" | property_phandle phandle)" 'DSI1 VOPB input does not terminate at route filter port 0'
require_equal "$(printf '%s\n' "$filter_dsi_sink" | property_phandle remote-endpoint)" "$(printf '%s\n' "$dsi1_vopb_input" | property_phandle phandle)" 'DSI1 VOPB route filter port 0 does not connect back to DSI input'
require_equal "$(printf '%s\n' "$vopb_endpoint" | property_phandle remote-endpoint)" "$(printf '%s\n' "$filter_vopb_sink" | property_phandle phandle)" 'VOPB DSI output does not terminate at route filter port 1'
require_equal "$(printf '%s\n' "$filter_vopb_sink" | property_phandle remote-endpoint)" "$(printf '%s\n' "$vopb_endpoint" | property_phandle phandle)" 'DSI1 VOPB route filter port 1 does not connect back to VOPB output'

for filter_endpoint in "$filter_dsi_sink" "$filter_vopb_sink"; do
	filter_phandle=$(printf '%s\n' "$filter_endpoint" | property_phandle phandle)
	require_distinct "$filter_phandle" "$(printf '%s\n' "$vopb_endpoint" | property_phandle phandle)" 'DSI1 VOPB route filter endpoint aliases the VOPB output'
	require_distinct "$filter_phandle" "$(printf '%s\n' "$vopl_endpoint" | property_phandle phandle)" 'DSI1 VOPB route filter endpoint aliases the VOPL output'
	display_ports=$(printf '%s\n' "$display_subsystem" | property_cells ports)
	[ -n "$display_ports" ] || die 'display-subsystem ports property is missing'
	for display_port_phandle in $display_ports; do
		require_distinct "$filter_phandle" "$display_port_phandle" 'DSI1 VOPB route filter endpoint aliases display-subsystem ports'
	done
done
require_direct_property "$dsi1_vopb_input" status '"disabled"' 'DSI1 big-VOP input is not disabled'
require_direct_property "$dsi1_input" status '"okay"' 'DSI1 little-VOP input is not enabled'
require_equal "$(printf '%s\n' "$vopl_endpoint" | property_phandle remote-endpoint)" "$(printf '%s\n' "$dsi1_input" | property_phandle phandle)" 'little-VOP output does not connect to DSI1 input'
require_equal "$(printf '%s\n' "$dsi1_input" | property_phandle remote-endpoint)" "$(printf '%s\n' "$vopl_endpoint" | property_phandle phandle)" 'DSI1 input does not connect back to little-VOP output'
dsi1_output_port=$(printf '%s\n' "$dsi1" | extract_named_node 'port@1')
dsi1_output=$(printf '%s\n' "$dsi1_output_port" | extract_named_node 'endpoint')
panel_port=$(printf '%s\n' "$panel" | extract_named_node 'port')
panel_input=$(printf '%s\n' "$panel_port" | extract_named_node 'endpoint')
require_equal "$(printf '%s\n' "$dsi1_output" | property_phandle remote-endpoint)" "$(printf '%s\n' "$panel_input" | property_phandle phandle)" 'DSI1 output does not connect to panel input'
require_equal "$(printf '%s\n' "$panel_input" | property_phandle remote-endpoint)" "$(printf '%s\n' "$dsi1_output" | property_phandle phandle)" 'panel input does not connect back to DSI1 output'
printf 'PASS: DSI1 VOPB route is terminated; DSI1 graph prefers little VOP and connects to panel\n'

require_direct_property "$hdmi" status '"okay"' 'merged tree does not preserve HDMI'
printf 'PASS: HDMI unchanged\n'
printf 'PASS: offline validation\n'
