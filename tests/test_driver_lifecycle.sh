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
