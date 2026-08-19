#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dtb=/boot/dtb/rockchip/rk3399-rock-pi-4b-plus.dtb
overlay=$repo_root/overlays/rockpi-4b-plus-rpi-touchscreen.dts
output=$repo_root/build/rockpi-4b-plus-rpi-touchscreen.dtbo
workdir=$(mktemp -d)

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

[ -f "$dtb" ] || {
	printf 'FAIL: active Rock Pi 4B+ DTB not found: %s\n' "$dtb" >&2
	exit 1
}

mkdir -p "$(dirname -- "$output")"
dtc -@ -I dts -O dtb -o "$output" "$overlay"
fdtoverlay -i "$dtb" -o "$workdir/merged.dtb" "$output"
dtc -I dtb -O dts -o "$workdir/merged.dts" "$workdir/merged.dtb"

dsi0=$(node_from_file "$workdir/merged.dts" 'dsi@ff960000')
dsi1=$(node_from_file "$workdir/merged.dts" 'dsi@ff968000')
i2c1=$(node_from_file "$workdir/merged.dts" 'i2c@ff110000')
vopl=$(node_from_file "$workdir/merged.dts" 'vop@ff8f0000')
hdmi=$(node_from_file "$workdir/merged.dts" 'hdmi@ff940000')
panel=$(printf '%s\n' "$i2c1" | extract_named_node 'panel@45')
touch=$(printf '%s\n' "$i2c1" | extract_named_node 'touchscreen@38')

require_text "$dsi0" 'status = "okay";' 'DSI0 is enabled'
require_text "$dsi1" 'status = "okay";' 'DSI1 is enabled'
printf 'PASS: DSI0 and DSI1 enabled\n'

require_text "$panel" 'compatible = "raspberrypi,7inch-touchscreen-panel";' 'panel compatible'
require_text "$panel" 'reg = <0x45>;' 'panel address 0x45'
printf 'PASS: panel at 0x45\n'

require_text "$touch" 'compatible = "raspits_ft5426";' 'touch compatible'
require_text "$touch" 'reg = <0x38>;' 'touch address 0x38'
require_text "$touch" 'touchscreen-size-x = <0x320>;' 'touch X size'
require_text "$touch" 'touchscreen-size-y = <0x1e0>;' 'touch Y size'
printf 'PASS: touch at 0x38\n'

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
