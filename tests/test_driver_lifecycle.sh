#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
driver=$repo_root/src/raspits_ft5426.c

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

line_of()
{
	grep -n -m 1 "$1" "$driver" | cut -d: -f1
}

probe_body=$(sed -n '/^static int raspits_probe(/,/^}/p' "$driver")
poll_body=$(sed -n '/^static void raspits_poll(/,/^}/p' "$driver")

probe_read=$(line_of 'raspits_read_fw_register(client, FT5426_REG_FW_VERSION')
probe_register=$(line_of 'input_register_device(input)')
[ "$probe_read" -lt "$probe_register" ] ||
	fail 'controller identification must precede input registration'
grep -Eq 'if \(fw_version < 0\)[[:space:]]*$' "$driver" ||
	fail 'firmware identification read errors must fail probe'
grep -Fq 'if (ret == -ENXIO)' "$driver" ||
	fail 'an unpowered FT5426 must be distinguished from other probe errors'
grep -Fq 'return dev_err_probe(dev, -EPROBE_DEFER,' "$driver" ||
	fail 'an unpowered FT5426 must defer until panel power is available'
[ "$(grep -Fc 'raspits_read_fw_register(client,' "$driver")" -eq 3 ] ||
	fail 'all three firmware identification reads must use the power-aware helper'

printf '%s\n' "$probe_body" | grep -Fq \
	'input_set_abs_params(input, ABS_MT_POSITION_X, 0, FT5426_MAX_X - 1,' ||
	fail 'probe must retain the 800-wide multitouch axis'
printf '%s\n' "$probe_body" | grep -Fq \
	'input_set_abs_params(input, ABS_MT_POSITION_Y, 0, FT5426_MAX_Y - 1,' ||
	fail 'probe must retain the 480-high multitouch axis'
printf '%s\n' "$probe_body" | grep -Fq \
	'touchscreen_parse_properties(input, true, &ts->properties);' ||
	fail 'probe must parse standard touchscreen properties'
probe_axis_y=$(printf '%s\n' "$probe_body" | grep -n -m 1 \
	'input_set_abs_params(input, ABS_MT_POSITION_Y' | cut -d: -f1)
probe_properties=$(printf '%s\n' "$probe_body" | grep -n -m 1 \
	'touchscreen_parse_properties(input, true, &ts->properties);' | cut -d: -f1)
probe_register=$(printf '%s\n' "$probe_body" | grep -n -m 1 \
	'input_register_device(input)' | cut -d: -f1)
[ "$probe_axis_y" -lt "$probe_properties" ] &&
	[ "$probe_properties" -lt "$probe_register" ] ||
	fail 'touchscreen properties must be parsed after axes and before registration'

printf '%s\n' "$poll_body" | grep -Fq \
	'touchscreen_report_pos(ts->input, &ts->properties, point->x, point->y, true);' ||
	fail 'poll must report raw points through touchscreen properties'
printf '%s\n' "$poll_body" | grep -Fq \
	'input_report_abs(ts->input, ABS_MT_POSITION_X,' &&
	fail 'poll must not report raw multitouch X itself'
printf '%s\n' "$poll_body" | grep -Fq \
	'input_report_abs(ts->input, ABS_MT_POSITION_Y,' &&
	fail 'poll must not report raw multitouch Y itself'

grep -Eq '^#define FT5426_MAX_CONSECUTIVE_FAILURES[[:space:]]+[1-9][0-9]*$' "$driver" ||
	fail 'polling must define a nonzero bounded failure threshold'
grep -Fq 'raspits_release_active_touches(ts);' "$driver" ||
	fail 'persistent polling failures must release active touches'
grep -Fq 'ts->consecutive_failures = 0;' "$driver" ||
	fail 'a valid poll frame must reset the failure counter'

[ "$(grep -c 'raspits_stop(ts);' "$driver")" -eq 2 ] ||
	fail 'remove and shutdown must share the synchronous stop helper'
grep -Fq '.shutdown = raspits_shutdown,' "$driver" ||
	fail 'I2C shutdown callback must synchronously stop polling'

printf 'PASS: driver lifecycle and persistent-error release policy\n'
