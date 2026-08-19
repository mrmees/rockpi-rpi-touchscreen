#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
panel=src/panel_rockpi_rpi_touchscreen.c

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

function_body()
{
	function_name=$1
	awk -v function_name="$function_name" '
		$0 ~ "^static .* " function_name "\\(" { found = 1 }
		found {
			print
			line = $0
			opens = gsub(/\{/, "{", line)
			line = $0
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
			if (opens)
				started = 1
			if (started && depth == 0)
				exit
		}
	' "$panel"
}

line_of()
{
	grep -n -m 1 "$1" "$panel" | cut -d: -f1
}

test -f "$panel" || fail 'missing compatibility panel driver'
grep -Fq '.compatible = "rockpi,rpi-7inch-touchscreen-panel"' "$panel" ||
	fail 'missing project panel compatible'
grep -Fq 'dsi->lanes = 1;' "$panel" || fail 'DSI must use one lane'
grep -Fq 'dsi->format = MIPI_DSI_FMT_RGB888;' "$panel" ||
	fail 'DSI must use RGB888'
grep -Fq 'MIPI_DSI_MODE_VIDEO_BURST | MIPI_DSI_MODE_LPM;' "$panel" ||
	fail 'DSI must use Radxa burst and low-power flags'

while IFS= read -r command; do
	grep -Fq "{ $command }," "$panel" ||
		fail "missing Radxa TC358762 command: $command"
done <<'EOF'
0x10, 0x02, 0x03, 0x00, 0x00, 0x00
0x64, 0x01, 0x0c, 0x00, 0x00, 0x00
0x68, 0x01, 0x0c, 0x00, 0x00, 0x00
0x44, 0x01, 0x00, 0x00, 0x00, 0x00
0x48, 0x01, 0x00, 0x00, 0x00, 0x00
0x14, 0x01, 0x15, 0x00, 0x00, 0x00
0x50, 0x04, 0x60, 0x00, 0x00, 0x00
0x20, 0x04, 0x52, 0x01, 0x10, 0x00
0x24, 0x04, 0x14, 0x00, 0x1a, 0x00
0x28, 0x04, 0x20, 0x03, 0x69, 0x00
0x2c, 0x04, 0x02, 0x00, 0x15, 0x00
0x30, 0x04, 0xe0, 0x01, 0x07, 0x00
0x34, 0x04, 0x01, 0x00, 0x00, 0x00
0x64, 0x04, 0x0f, 0x04, 0x00, 0x00
0x04, 0x01, 0x01, 0x00, 0x00, 0x00
0x04, 0x02, 0x01, 0x00, 0x00, 0x00
0x10, 0x04, 0x03, 0x00, 0x00, 0x00
EOF
[ "$(grep -Ec '^[[:space:]]*\{ 0x[0-9a-f][0-9a-f], ' "$panel")" -eq 17 ] ||
	fail 'TC358762 initialization must contain exactly 17 commands'

prepare_body=$(function_body rockpi_panel_prepare)
printf '%s\n' "$prepare_body" |
	grep -Fq 'rockpi_mcu_write(ctx, REG_POWERON, 1)' ||
	fail 'prepare must power the panel through the MCU'
if printf '%s\n' "$prepare_body" | grep -Fq 'mipi_dsi_generic_write'; then
	fail 'prepare must not issue DSI bridge writes'
fi

enable_body=$(function_body rockpi_panel_enable)
init_line=$(printf '%s\n' "$enable_body" |
	grep -n -m 1 'rockpi_tc358762_init(ctx)' | cut -d: -f1) ||
	fail 'enable must call the TC358762 initialization helper'
backlight_line=$(printf '%s\n' "$enable_body" |
	grep -n -m 1 'rockpi_backlight_set(ctx, 255)' | cut -d: -f1) ||
	fail 'enable must call the backlight helper'
[ "$init_line" -lt "$backlight_line" ] ||
	fail 'enable must initialize TC358762 before enabling backlight'
printf '%s\n' "$enable_body" | grep -Eq 'if \(ret\)[[:space:]]*$' ||
	fail 'enable must check TC358762 initialization errors'
printf '%s\n' "$enable_body" | grep -Fq 'return ret;' ||
	fail 'enable must propagate TC358762 initialization errors'

[ "$(grep -c 'rockpi_panel_stop(ctx);' "$panel")" -eq 2 ] ||
	fail 'remove and shutdown must share the synchronous panel-stop helper'
grep -Fq '.shutdown = rockpi_panel_shutdown,' "$panel" ||
	fail 'I2C shutdown callback must stop the panel synchronously'

id_read=$(line_of 'rockpi_mcu_read(ctx, REG_ID)') ||
	fail 'probe must read the MCU identity'
panel_register=$(line_of 'drm_panel_add(&ctx->panel)') ||
	fail 'probe must register the DRM panel'
[ "$id_read" -lt "$panel_register" ] ||
	fail 'MCU identity validation must precede panel registration'
grep -Fq 'if (id != 0xc3)' "$panel" ||
	fail 'probe must reject every MCU ID except 0xc3'

grep -Fq 'https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/gpu/drm/panel/panel-raspberrypi-touchscreen.c' "$panel" ||
	fail 'missing immutable Linux v6.18 source reference'
grep -Fq 'https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/gpu/drm/panel/panel-raspits-tc358762.c' "$panel" ||
	fail 'missing immutable Radxa TC358762 source reference'
grep -Fq 'Modified 2026-08-19 by the Rock Pi RPi Touchscreen contributors' "$panel" ||
	fail 'missing dated project modification notice'

printf 'PASS: RK3399-safe panel lifecycle and source policy\n'
