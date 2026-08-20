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
		END {
			if (!found || !started || depth != 0)
				exit 1
		}
	' "$panel"
}

line_of()
{
	awk -v pattern="$1" '
		index($0, pattern) {
			print NR
			found = 1
			exit
		}
		END { if (!found) exit 1 }
	' "$panel"
}

body_line()
{
	pattern=$1
	awk -v pattern="$pattern" '
		index($0, pattern) {
			print NR
			found = 1
			exit
		}
		END { if (!found) exit 1 }
	'
}

test -f "$panel" || fail 'missing compatibility panel driver'
grep -Fq '.compatible = "rockpi,rpi-7inch-touchscreen-panel"' "$panel" ||
	fail 'missing project panel compatible'
grep -Fq 'dsi->lanes = 1;' "$panel" || fail 'DSI must use one lane'
grep -Fq 'dsi->format = MIPI_DSI_FMT_RGB888;' "$panel" ||
	fail 'DSI must use RGB888'
grep -Fq 'MIPI_DSI_MODE_VIDEO_BURST | MIPI_DSI_MODE_LPM;' "$panel" ||
	fail 'DSI must use Radxa burst and low-power flags'

mode_body=$(awk '
	/static const struct drm_display_mode rockpi_panel_mode = \{/ {
		inside = 1
	}
	inside {
		print
		if (/^[[:space:]]*};/) exit
	}
' "$panel")
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.clock = 25979,$' ||
	fail 'panel mode must use the fixed 25979 kHz clock'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.hdisplay = 800,$' ||
	fail 'panel mode must use fixed hdisplay 800'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.hsync_start = 801,$' ||
	fail 'panel mode must use fixed hsync_start 801'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.hsync_end = 803,$' ||
	fail 'panel mode must use fixed hsync_end 803'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.htotal = 849,$' ||
	fail 'panel mode must use fixed htotal 849'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.vdisplay = 480,$' ||
	fail 'panel mode must use fixed vdisplay 480'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.vsync_start = 487,$' ||
	fail 'panel mode must use fixed vsync_start 487'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.vsync_end = 489,$' ||
	fail 'panel mode must use fixed vsync_end 489'
printf '%s\n' "$mode_body" | grep -Eq '^[[:space:]]*\.vtotal = 510,$' ||
	fail 'panel mode must use fixed vtotal 510'
printf '%s\n' "$mode_body" |
	grep -Eq '^[[:space:]]*\.flags = DRM_MODE_FLAG_NHSYNC \| DRM_MODE_FLAG_NVSYNC,$' ||
	fail 'panel mode must use fixed negative horizontal and vertical sync flags'

expected_sequence=$(cat <<'EOF'
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
)
actual_sequence=$(awk '
	/static const u8 sequence\[\]\[6\] = \{/ {
		inside = 1
		next
	}
	inside && /^[[:space:]]*};/ { exit }
	inside {
		line = $0
		sub(/^[[:space:]]*\{ /, "", line)
		sub(/ \},[[:space:]]*$/, "", line)
		print line
	}
' "$panel")
[ "$actual_sequence" = "$expected_sequence" ] ||
	fail 'TC358762 initializer must match the exact ordered Radxa sequence'

tc_init_body=$(function_body rockpi_tc358762_init)
tc_write=$(printf '%s\n' "$tc_init_body" |
	body_line 'ret = rockpi_tc358762_write(ctx, sequence[i])') ||
	fail 'TC358762 loop must assign each generic-write result'
tc_check=$(printf '%s\n' "$tc_init_body" |
	body_line 'if (ret)') ||
	fail 'TC358762 loop must check each generic-write result'
tc_return=$(printf '%s\n' "$tc_init_body" |
	body_line 'return ret;') ||
	fail 'TC358762 loop must return the first generic-write error'
[ "$tc_check" -eq $((tc_write + 1)) ] &&
	[ "$tc_return" -eq $((tc_check + 1)) ] ||
	fail 'TC358762 write assignment must be immediately checked and returned'

prepare_body=$(function_body rockpi_panel_prepare)
grep -Fq '#define ROCKPI_PANEL_READY_RETRIES' "$panel" &&
	grep -Eq '#define ROCKPI_PANEL_READY_RETRIES[[:space:]]+100' "$panel" ||
	fail 'the advisory ready-bit wait must remain bounded at 100 attempts'
printf '%s\n' "$prepare_body" |
	grep -Fq 'for (i = 0; i < ROCKPI_PANEL_READY_RETRIES; i++)' ||
	fail 'prepare must use the bounded ready-retry constant in its poll loop'
printf '%s\n' "$prepare_body" |
	grep -Fq 'rockpi_mcu_write(ctx, REG_POWERON, 1)' ||
	fail 'prepare must power the panel through the MCU'
if printf '%s\n' "$prepare_body" | grep -Fq 'mipi_dsi_generic_write'; then
	fail 'prepare must not issue DSI bridge writes'
fi
printf '%s\n' "$prepare_body" | grep -Fq 'failed to power on panel:' ||
	fail 'prepare must log MCU power-on failures'
printf '%s\n' "$prepare_body" | grep -Fq 'failed to read panel ready state:' ||
	fail 'prepare must log MCU ready-read failures'
if printf '%s\n' "$prepare_body" | grep -Fq 'ret = -ETIMEDOUT'; then
	fail 'an advisory MCU ready bit must not make panel prepare fail'
fi
printf '%s\n' "$prepare_body" |
	grep -Fq 'panel ready bit did not assert; continuing after bounded wait' ||
	fail 'prepare must warn when the advisory MCU ready bit does not assert'
printf '%s\n' "$prepare_body" | grep -Fq 'WRITE_ONCE(ctx->prepared, true)' ||
	fail 'prepare must continue after the bounded advisory ready-bit wait'
read_error=$(printf '%s\n' "$prepare_body" | body_line 'if (ret < 0)') ||
	fail 'MCU ready-state read errors must be checked'
read_error_power_off=$(printf '%s\n' "$prepare_body" | body_line 'goto power_off;') ||
	fail 'MCU ready-state read errors must use the power-off error path'
ready_break=$(printf '%s\n' "$prepare_body" | body_line 'if (ret & BIT(0))') ||
	fail 'prepare must retain the upstream ready-bit early exit'
exhaustion_warning=$(printf '%s\n' "$prepare_body" |
	body_line 'panel ready bit did not assert; continuing after bounded wait') ||
	fail 'prepare must warn only after the bounded wait is exhausted'
prepared_line=$(printf '%s\n' "$prepare_body" |
	body_line 'WRITE_ONCE(ctx->prepared, true)') ||
	fail 'prepare must mark the panel prepared after the advisory wait'
[ "$read_error" -lt "$read_error_power_off" ] &&
	[ "$read_error_power_off" -lt "$ready_break" ] &&
	[ "$ready_break" -lt "$exhaustion_warning" ] &&
	[ "$exhaustion_warning" -lt "$prepared_line" ] ||
	fail 'prepare must keep I2C errors fatal and ready-bit exhaustion advisory'
printf '%s\n' "$prepare_body" |
	sed -n '/if (ret < 0)/,/^[[:space:]]*}/p' |
	grep -Fq 'goto power_off;' ||
	fail 'negative MCU reads must conditionally enter the power-off error path'
printf '%s\n' "$prepare_body" |
	sed -n '/if (ret & BIT(0))/,/^[[:space:]]*}/p' |
	grep -Fq 'break;' ||
	fail 'an asserted upstream ready bit must exit the bounded poll early'
printf '%s\n' "$prepare_body" |
	sed -n '/if (i == ROCKPI_PANEL_READY_RETRIES)/,/continuing after bounded wait/p' |
	grep -Fq 'panel ready bit did not assert; continuing after bounded wait' ||
	fail 'the advisory warning must be guarded by retry exhaustion'

enable_body=$(function_body rockpi_panel_enable)
init_line=$(printf '%s\n' "$enable_body" |
	body_line 'rockpi_tc358762_init(ctx)') ||
	fail 'enable must call the TC358762 initialization helper'
init_check=$(printf '%s\n' "$enable_body" |
	body_line 'if (ret)') ||
	fail 'enable must check the TC358762 initialization result'
init_log=$(printf '%s\n' "$enable_body" |
	body_line 'failed to initialize TC358762:') ||
	fail 'enable must log the TC358762 initialization error'
init_return=$(printf '%s\n' "$enable_body" |
	body_line 'return ret;') ||
	fail 'enable must return the TC358762 initialization error'
[ "$init_check" -eq $((init_line + 1)) ] &&
	[ "$init_log" -eq $((init_check + 1)) ] &&
	[ "$init_return" -eq $((init_log + 1)) ] ||
	fail 'enable must check, log, and return the TC358762 initialization error'
backlight_line=$(printf '%s\n' "$enable_body" |
	body_line 'backlight_enable(ctx->backlight)') ||
	fail 'enable must use the serialized backlight core helper'
[ "$init_line" -lt "$backlight_line" ] ||
	fail 'enable must initialize TC358762 before enabling backlight'
printf '%s\n' "$enable_body" | grep -Fq 'failed to initialize TC358762:' ||
	fail 'enable must log TC358762 initialization failures'
printf '%s\n' "$enable_body" | grep -Fq 'failed to enable backlight:' ||
	fail 'enable must log backlight failures'
printf '%s\n' "$enable_body" | grep -Fq 'failed to set panel orientation:' ||
	fail 'enable must log orientation I2C failures'
grep -Fq '.state = BL_CORE_FBBLANK,' "$panel" ||
	fail 'backlight must start framebuffer-blanked'
if grep -Fq 'ctx->backlight->props.power' "$panel"; then
	fail 'panel lifecycle must not mutate backlight power outside the core'
fi

backlight_body=$(function_body rockpi_backlight_update_status)
printf '%s\n' "$backlight_body" |
	grep -Fq '!READ_ONCE(ctx->prepared) || !READ_ONCE(ctx->enabled)' ||
	fail 'backlight callback must gate brightness on prepared and enabled state'
printf '%s\n' "$backlight_body" | grep -Fq 'brightness = 0;' ||
	fail 'backlight callback must force PWM zero while the panel is inactive'
printf '%s\n' "$backlight_body" | grep -Fq 'failed to update backlight PWM:' ||
	fail 'backlight callback must log PWM I2C failures'
if printf '%s\n' "$backlight_body" |
	grep -Eq '^[[:space:]]*backlight_(enable|disable|update_status)\('; then
	fail 'backlight callback must not recurse into the backlight core'
fi

disable_body=$(function_body rockpi_panel_disable)
disable_state=$(printf '%s\n' "$disable_body" |
	body_line 'WRITE_ONCE(ctx->enabled, false)') ||
	fail 'disable must retain false state before the hardware callback'
disable_core=$(printf '%s\n' "$disable_body" |
	body_line 'backlight_disable(ctx->backlight)') ||
	fail 'disable must use the serialized backlight core helper'
[ "$disable_state" -lt "$disable_core" ] ||
	fail 'disable must make sysfs gating safe before forcing PWM off'
printf '%s\n' "$disable_body" | grep -Fq 'failed to disable backlight:' ||
	fail 'disable must log PWM-off failures while retaining false state'

unprepare_body=$(function_body rockpi_panel_unprepare)
unprepare_state=$(printf '%s\n' "$unprepare_body" |
	body_line 'WRITE_ONCE(ctx->prepared, false)') ||
	fail 'unprepare must retain false state before powering off'
unprepare_power=$(printf '%s\n' "$unprepare_body" |
	body_line 'rockpi_mcu_write(ctx, REG_POWERON, 0)') ||
	fail 'unprepare must always request MCU power off'
[ "$unprepare_state" -lt "$unprepare_power" ] ||
	fail 'unprepare must make backlight gating safe before powering off'
printf '%s\n' "$unprepare_body" | grep -Fq 'failed to power off panel:' ||
	fail 'unprepare must log power-off failures while retaining false state'

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
attach_dsi=$(line_of 'ret = mipi_dsi_attach(ctx->dsi)') ||
	fail 'probe must attach the DSI peripheral'
[ "$panel_register" -lt "$attach_dsi" ] ||
	fail 'DRM panel publication must precede DesignWare DSI attach'
grep -Fq 'if (id != 0xc3)' "$panel" ||
	fail 'probe must reject every MCU ID except 0xc3'

probe_body=$(function_body rockpi_panel_probe)
probe_id=$(printf '%s\n' "$probe_body" |
	body_line 'rockpi_mcu_read(ctx, REG_ID)') ||
	fail 'probe must identify the MCU'
probe_force_off=$(printf '%s\n' "$probe_body" |
	body_line 'rockpi_panel_force_off(ctx)') ||
	fail 'probe must force inherited PWM and panel power off'
probe_backlight=$(printf '%s\n' "$probe_body" |
	body_line 'backlight_device_register') ||
	fail 'probe must register a backlight'
probe_panel=$(printf '%s\n' "$probe_body" |
	body_line 'drm_panel_add(&ctx->panel)') ||
	fail 'probe must publish the DRM panel'
probe_attach=$(printf '%s\n' "$probe_body" |
	body_line 'mipi_dsi_attach(ctx->dsi)') ||
	fail 'probe must attach the DSI peripheral'
[ "$probe_id" -lt "$probe_force_off" ] &&
	[ "$probe_force_off" -lt "$probe_backlight" ] &&
	[ "$probe_backlight" -lt "$probe_panel" ] &&
	[ "$probe_panel" -lt "$probe_attach" ] ||
	fail 'probe must establish hardware off before publishing panel and attaching DSI'

force_off_body=$(function_body rockpi_panel_force_off) ||
	fail 'missing fail-safe hardware-off helper'
force_pwm=$(printf '%s\n' "$force_off_body" |
	body_line 'rockpi_mcu_write(ctx, REG_PWM, 0)') ||
	fail 'hardware-off helper must force PWM zero'
force_power=$(printf '%s\n' "$force_off_body" |
	body_line 'rockpi_mcu_write(ctx, REG_POWERON, 0)') ||
	fail 'hardware-off helper must force panel power zero'
force_return=$(printf '%s\n' "$force_off_body" |
	body_line 'return first_error;') ||
	fail 'hardware-off helper must preserve and return the first error'
[ "$force_pwm" -lt "$force_power" ] &&
	[ "$force_power" -lt "$force_return" ] ||
	fail 'hardware-off helper must attempt both off writes before returning'

cleanup_panel=$(printf '%s\n' "$probe_body" |
	body_line 'drm_panel_remove(&ctx->panel)') ||
	fail 'DSI attach failure must remove the published panel'
cleanup_backlight=$(printf '%s\n' "$probe_body" |
	body_line 'backlight_device_unregister(ctx->backlight)') ||
	fail 'DSI attach failure must unregister the backlight'
cleanup_dsi=$(printf '%s\n' "$probe_body" |
	body_line 'mipi_dsi_device_unregister(ctx->dsi)') ||
	fail 'DSI attach failure must unregister the DSI peripheral'
[ "$probe_attach" -lt "$cleanup_panel" ] &&
	[ "$cleanup_panel" -lt "$cleanup_backlight" ] &&
	[ "$cleanup_backlight" -lt "$cleanup_dsi" ] ||
	fail 'DSI attach failure must unwind panel, backlight, then DSI peripheral'

grep -Fq 'https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/gpu/drm/panel/panel-raspberrypi-touchscreen.c' "$panel" ||
	fail 'missing immutable Linux v6.18 source reference'
grep -Fq 'https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/gpu/drm/panel/panel-raspits-tc358762.c' "$panel" ||
	fail 'missing immutable Radxa TC358762 source reference'
grep -Fq 'Modified 2026-08-19 by the Rock Pi RPi Touchscreen contributors' "$panel" ||
	fail 'missing dated project modification notice'

printf 'PASS: RK3399-safe panel lifecycle and source policy\n'
