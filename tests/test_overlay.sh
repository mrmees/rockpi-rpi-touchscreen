#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
armbian_env=${ARMBIAN_ENV:-/boot/armbianEnv.txt}
dtb_root=${DTB_ROOT:-/boot/dtb}
overlay=$repo_root/overlays/rockpi-4b-plus-rpi-touchscreen.dts
workdir=$(mktemp -d)
output=$workdir/rockpi-4b-plus-rpi-touchscreen.dtbo

cleanup()
{
	# mktemp -d creates a private directory; remove only that exact directory.
	rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

extract_named_node()
{
	node=$1
	awk -v node="$node" '
		!found && $0 ~ "^[[:space:]]*" node "[[:space:]]*\\{" {
			found = 1
		}
		found {
			print
			line = $0
			opens = gsub(/\{/, "{", line)
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
			if (depth == 0)
				exit
		}
		END {
			if (!found || depth != 0)
				exit 1
		}
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
	printf '%s\n' "$text" | grep -Fq "$needle" || {
		printf 'FAIL: %s\n' "$message" >&2
		exit 1
	}
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

require_equal()
{
	actual=$1
	expected=$2
	message=$3
	[ -n "$actual" ] && [ "$actual" = "$expected" ] || {
		printf 'FAIL: %s (got %s, expected %s)\n' "$message" "$actual" "$expected" >&2
		exit 1
	}
}

active_dtb()
{
	env_file=$1
	dtb_directory=$2

	[ -r "$env_file" ] || {
		printf 'FAIL: cannot read Armbian environment: %s\n' "$env_file" >&2
		return 1
	}

	fdtfile=$(sed -n 's/^[[:space:]]*fdtfile[[:space:]]*=[[:space:]]*\([^[:space:]#][^[:space:]#]*\).*$/\1/p' "$env_file" | tail -n 1)
	[ -n "$fdtfile" ] || {
		printf 'FAIL: fdtfile is absent or empty in Armbian environment: %s\n' "$env_file" >&2
		return 1
	}

	case $fdtfile in
	/*) printf '%s\n' "$fdtfile" ;;
	*) printf '%s/%s\n' "$dtb_directory" "$fdtfile" ;;
	esac
}

assert_active_dtb_resolution()
{
	resolution_env=$workdir/armbianEnv-resolution
	missing_fdtfile_env=$workdir/armbianEnv-no-fdtfile

	printf '%s\n' 'fdtfile=rockchip/rk3399-rock-pi-4b-plus.dtb' > "$resolution_env"
	require_equal "$(active_dtb "$resolution_env" /boot/dtb)" \
		'/boot/dtb/rockchip/rk3399-rock-pi-4b-plus.dtb' \
		'configured fdtfile resolves below the DTB root'

	printf '%s\n' '# fdtfile intentionally absent' > "$missing_fdtfile_env"
	if active_dtb "$missing_fdtfile_env" /boot/dtb >/dev/null 2>&1; then
		printf 'FAIL: missing fdtfile was accepted\n' >&2
		exit 1
	fi
	if active_dtb "$workdir/no-such-armbianEnv" /boot/dtb >/dev/null 2>&1; then
		printf 'FAIL: unreadable armbianEnv was accepted\n' >&2
		exit 1
	fi
	printf 'PASS: active DTB configuration resolution\n'
}

dtb=$(active_dtb "$armbian_env" "$dtb_root")
assert_active_dtb_resolution

[ -f "$dtb" ] || {
	printf 'FAIL: active Rock Pi 4B+ DTB not found: %s\n' "$dtb" >&2
	exit 1
}

dtc -Wno-power_domains_property -@ -I dts -O dtb -o "$output" "$overlay"
dtc -Wno-power_domains_property -I dtb -O dts -o "$workdir/compiled.dts" "$output"
fdtoverlay -i "$dtb" -o "$workdir/merged.dtb" "$output"
dtc -I dtb -O dts -o "$workdir/merged.dts" "$workdir/merged.dtb"

compiled_provider=$(node_from_file "$workdir/compiled.dts" 'rockpi-display-compat') || {
	printf 'FAIL: compiled overlay is missing the display compatibility provider\n' >&2
	exit 1
}
compiled_panel=$(node_from_file "$workdir/compiled.dts" 'panel@45')
compiled_touch=$(node_from_file "$workdir/compiled.dts" 'touchscreen@38')
require_text "$compiled_provider" 'compatible = "rockpi,rk3399-dsi1-rpi-touchscreen-compat";' 'compiled provider compatible'
require_equal "$(grep -Fc 'compatible = "rockpi,rk3399-dsi1-rpi-touchscreen-compat";' "$workdir/compiled.dts")" \
	'1' 'compiled overlay has exactly one display compatibility provider'
require_text "$compiled_provider" 'status = "okay";' 'compiled provider is enabled'
for property in power-domains rockchip,dsi0 rockchip,dsi1 rockchip,grf rockchip,vopb rockchip,vopl; do
	require_text "$compiled_provider" "$property = <" "compiled provider property $property"
done
require_text "$compiled_panel" 'rockpi,display-compat = <' 'compiled panel provider link'
require_text "$compiled_touch" 'touchscreen-inverted-x;' 'compiled touch X inversion'
require_text "$compiled_touch" 'touchscreen-inverted-y;' 'compiled touch Y inversion'
printf 'PASS: compiled provider and consumer properties\n'

dsi0=$(node_from_file "$workdir/merged.dts" 'dsi@ff960000')
dsi1=$(node_from_file "$workdir/merged.dts" 'dsi@ff968000')
i2c1=$(node_from_file "$workdir/merged.dts" 'i2c@ff110000')
grf=$(node_from_file "$workdir/merged.dts" 'syscon@ff770000')
vopb=$(node_from_file "$workdir/merged.dts" 'vop@ff900000')
vopl=$(node_from_file "$workdir/merged.dts" 'vop@ff8f0000')
power=$(node_from_file "$workdir/merged.dts" 'power-controller')
hdmi=$(node_from_file "$workdir/merged.dts" 'hdmi@ff940000')
provider=$(node_from_file "$workdir/merged.dts" 'rockpi-display-compat')
panel=$(printf '%s\n' "$i2c1" | extract_named_node 'panel@45')
touch=$(printf '%s\n' "$i2c1" | extract_named_node 'touchscreen@38')

require_text "$dsi0" 'status = "disabled";' 'unused DSI0 remains disabled'
require_text "$dsi1" 'status = "okay";' 'DSI1 is enabled'
dsi0_output_port=$(printf '%s\n' "$dsi0" | extract_named_node 'port@1')
if printf '%s\n' "$dsi0_output_port" | grep -Eq '^[[:space:]]*endpoint(@[^[:space:]{]+)?[[:space:]]*\{'; then
	printf 'FAIL: unused DSI0 has an output endpoint\n' >&2
	exit 1
fi
printf 'PASS: unused DSI0 disabled without an output graph and DSI1 enabled\n'

require_equal "$(grep -Fc 'compatible = "rockpi,rk3399-dsi1-rpi-touchscreen-compat";' "$workdir/merged.dts")" \
	'1' 'merged tree has exactly one display compatibility provider'
require_text "$provider" 'status = "okay";' 'display compatibility provider is enabled'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,dsi0)" \
	"$(printf '%s\n' "$dsi0" | property_phandle phandle)" 'provider DSI0 resource'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,dsi1)" \
	"$(printf '%s\n' "$dsi1" | property_phandle phandle)" 'provider DSI1 resource'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,grf)" \
	"$(printf '%s\n' "$grf" | property_phandle phandle)" 'provider GRF resource'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,vopb)" \
	"$(printf '%s\n' "$vopb" | property_phandle phandle)" 'provider big-VOP resource'
require_equal "$(printf '%s\n' "$provider" | property_phandle rockchip,vopl)" \
	"$(printf '%s\n' "$vopl" | property_phandle phandle)" 'provider little-VOP resource'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 1)" \
	"$(printf '%s\n' "$power" | property_phandle phandle)" 'provider VIO power controller'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 2)" \
	'0x0f' 'provider RK3399_PD_VIO domain ID'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 1)" \
	"$(printf '%s\n' "$dsi0" | property_cell power-domains 1)" 'provider and DSI0 power controller'
require_equal "$(printf '%s\n' "$provider" | property_cell power-domains 2)" \
	"$(printf '%s\n' "$dsi0" | property_cell power-domains 2)" 'provider and DSI0 power-domain ID'
printf 'PASS: enabled display compatibility provider resources\n'

require_text "$panel" 'compatible = "rockpi,rpi-7inch-touchscreen-panel";' 'project panel compatible'
if printf '%s\n' "$panel" | grep -Fq 'compatible = "raspberrypi,7inch-touchscreen-panel";'; then
	printf 'FAIL: upstream panel compatible remains on the RK3399 route\n' >&2
	exit 1
fi
require_text "$panel" 'reg = <0x45>;' 'panel address 0x45'
require_equal "$(printf '%s\n' "$panel" | property_phandle rockpi,display-compat)" \
	"$(printf '%s\n' "$provider" | property_phandle phandle)" 'panel display compatibility provider link'
printf 'PASS: panel at 0x45\n'

require_text "$touch" 'compatible = "raspits_ft5426";' 'touch compatible'
require_text "$touch" 'reg = <0x38>;' 'touch address 0x38'
require_text "$touch" 'touchscreen-size-x = <0x320>;' 'touch X size'
require_text "$touch" 'touchscreen-size-y = <0x1e0>;' 'touch Y size'
require_text "$touch" 'touchscreen-inverted-x;' 'touch X inversion'
require_text "$touch" 'touchscreen-inverted-y;' 'touch Y inversion'
printf 'PASS: inverted touch at 0x38\n'

vopl_endpoint=$(printf '%s\n' "$vopl" | extract_named_node 'endpoint@3')
dsi1_vopb_input=$(printf '%s\n' "$dsi1" | extract_named_node 'endpoint@0')
dsi1_input=$(printf '%s\n' "$dsi1" | extract_named_node 'endpoint@1')
require_text "$dsi1_vopb_input" 'status = "disabled";' 'big VOP input is disabled'
require_text "$dsi1_input" 'status = "okay";' 'little VOP input is enabled'
require_equal "$(printf '%s\n' "$vopl_endpoint" | property_phandle remote-endpoint)" \
	"$(printf '%s\n' "$dsi1_input" | property_phandle phandle)" \
	'little VOP output connects to DSI1 input'
require_equal "$(printf '%s\n' "$dsi1_input" | property_phandle remote-endpoint)" \
	"$(printf '%s\n' "$vopl_endpoint" | property_phandle phandle)" \
	'DSI1 input connects back to little VOP output'

dsi1_output_port=$(printf '%s\n' "$dsi1" | extract_named_node 'port@1')
dsi1_output=$(printf '%s\n' "$dsi1_output_port" | extract_named_node 'endpoint')
panel_port=$(printf '%s\n' "$panel" | extract_named_node 'port')
panel_input=$(printf '%s\n' "$panel_port" | extract_named_node 'endpoint')
require_equal "$(printf '%s\n' "$dsi1_output" | property_phandle remote-endpoint)" \
	"$(printf '%s\n' "$panel_input" | property_phandle phandle)" \
	'DSI1 output connects to panel input'
require_equal "$(printf '%s\n' "$panel_input" | property_phandle remote-endpoint)" \
	"$(printf '%s\n' "$dsi1_output" | property_phandle phandle)" \
	'panel input connects back to DSI1 output'
printf 'PASS: little-VOP to DSI1 to panel graph\n'

require_text "$hdmi" 'status = "okay";' 'HDMI remains enabled'
printf 'PASS: HDMI remains enabled\n'

printf 'PASS: overlay compile, apply, routing, panel, touch, and HDMI checks\n'
