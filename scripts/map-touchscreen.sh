#!/bin/sh
set -eu

touch_name='Raspberry Pi 7-inch Touchscreen'
output_name=DSI-1
mode=${1:---once}

case $mode in
--once|--watch) ;;
*) printf 'usage: %s [--once|--watch]\n' "$0" >&2; exit 2 ;;
esac

[ "${XDG_SESSION_TYPE:-x11}" != wayland ] || exit 0
[ -n "${DISPLAY:-}" ] || { printf 'ERROR: DISPLAY is not set\n' >&2; exit 1; }

require_command()
{
	command -v "$1" >/dev/null 2>&1 || {
		printf 'ERROR: required command not found: %s\n' "$1" >&2
		exit 1
	}
}

require_command xrandr
require_command xinput
[ "$mode" = --once ] || { require_command xev; require_command stdbuf; }

map_once()
{
	if ! xrandr --current | awk -v output="$output_name" '
		$1 == output && $2 == "connected" {
			for (i = 3; i <= NF; i++)
				if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) found = 1
		}
		END { exit found ? 0 : 1 }
	'; then
		return 0
	fi
	ids=$(xinput list --id-only "$touch_name" 2>/dev/null || true)
	count=$(printf '%s\n' "$ids" | awk 'NF { count++ } END { print count + 0 }')
	[ "$count" -eq 1 ] || {
		printf 'ERROR: expected exactly one %s device, found %s\n' "$touch_name" "$count" >&2
		return 1
	}
	input_id=$(printf '%s\n' "$ids" | awk 'NF { print; exit }')
	xinput map-to-output "$input_id" "$output_name"
}

map_once
[ "$mode" = --watch ] || exit 0
stdbuf -oL xev -root -event randr | while IFS= read -r event_line; do
	case $event_line in
	RRScreenChangeNotify*|RRNotify*) map_once ;;
	esac
done
