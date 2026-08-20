#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mapper=$repo_root/scripts/map-touchscreen.sh
workdir=$(mktemp -d)
system_path=$PATH

cleanup()
{
	rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_equal()
{
	actual=$1
	expected=$2
	message=$3
	[ "$actual" = "$expected" ] || fail "$message (got: $actual; expected: $expected)"
}

assert_empty()
{
	[ ! -s "$1" ] || fail "expected empty: $1"
}

assert_file_lines()
{
	actual=$(cat "$1")
	expected=$2
	assert_equal "$actual" "$expected" "$3"
}

setup_sandbox()
{
	sandbox=$workdir/$1
	fake_bin=$sandbox/bin
	mkdir -p "$fake_bin"
	XINPUT_LOG=$sandbox/xinput.log
	XRANDR_LOG=$sandbox/xrandr.log
	X_COMMAND_LOG=$sandbox/x-commands.log
	XEV_LOG=$sandbox/xev.log
	export XINPUT_LOG XRANDR_LOG X_COMMAND_LOG XEV_LOG

	cat > "$fake_bin/xrandr" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = --current ] || exit 90
printf '%s\n' "$*" >> "${XRANDR_LOG:?}"
printf '%s\n' "$*" >> "${X_COMMAND_LOG:?}"
printf '%s\n' "${XRANDR_FIXTURE:?}"
EOF
	cat > "$fake_bin/xinput" <<'EOF'
#!/bin/sh
set -eu
case "$1 $2" in
'list --id-only')
	[ "$3" = 'Raspberry Pi 7-inch Touchscreen' ] || exit 90
	printf '%s\n' "$*" >> "${X_COMMAND_LOG:?}"
	printf '%s\n' "${XINPUT_IDS:-17}"
	;;
'map-to-output 17')
	[ "$3" = DSI-1 ] || exit 90
	printf '%s\n' "$*" >> "${XINPUT_LOG:?}"
	printf '%s\n' "$*" >> "${X_COMMAND_LOG:?}"
	;;
*) exit 90 ;;
esac
EOF
	cat > "$fake_bin/xev" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 3 ] && [ "$1" = -root ] && [ "$2" = -event ] && [ "$3" = randr ] || exit 90
printf '%s\n' "$*" >> "${XEV_LOG:?}"
printf '%s\n' 'RRScreenChangeNotify event, serial 42, synthetic NO, window 0x0,'
printf '%s\n' '    root 0x0, subw 0x0, time 99, size 1824x600, rotation 0'
EOF
	cat > "$fake_bin/stdbuf" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -oL ] || exit 90
shift
exec "$@"
EOF
	chmod 0755 "$fake_bin/xrandr" "$fake_bin/xinput" "$fake_bin/xev" "$fake_bin/stdbuf"
	PATH=$fake_bin:$system_path
	export PATH
	DISPLAY=:99
	XAUTHORITY=$sandbox/Xauthority
	XDG_SESSION_TYPE=x11
	XINPUT_IDS=17
	export DISPLAY XAUTHORITY XDG_SESSION_TYPE XINPUT_IDS
	XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1824 x 600, maximum 4096 x 4096
HDMI-1 connected primary 1024x600+800+0
DSI-1 connected 800x480+0+0'
	export XRANDR_FIXTURE
}

run_mapper()
{
	set +e
	"$mapper" "$1" > "$sandbox/stdout" 2> "$sandbox/stderr"
	mapper_status=$?
	set -e
}

assert_no_xrandr_mutation()
{
	assert_file_lines "$XRANDR_LOG" '--current' 'xrandr must be read-only'
}

test_once_maps_exact_device_to_active_dsi()
{
	setup_sandbox once-active
	run_mapper --once
	assert_equal "$mapper_status" 0 'one-shot mapper should succeed'
	assert_file_lines "$XINPUT_LOG" 'map-to-output 17 DSI-1' 'one-shot must use exact map boundary'
	assert_no_xrandr_mutation
}

test_once_is_noop_for_inactive_dsi()
{
	setup_sandbox once-inactive
	XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1024 x 600, maximum 4096 x 4096
HDMI-1 connected primary 1024x600+0+0
DSI-1 disconnected'
	export XRANDR_FIXTURE
	run_mapper --once
	assert_equal "$mapper_status" 0 'inactive DSI should be a successful no-op'
	assert_empty "$XINPUT_LOG"
	assert_no_xrandr_mutation
}

test_once_is_noop_for_hdmi_only()
{
	setup_sandbox once-hdmi-only
	XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1024 x 600, maximum 4096 x 4096
HDMI-1 connected primary 1024x600+0+0'
	export XRANDR_FIXTURE
	run_mapper --once
	assert_equal "$mapper_status" 0 'HDMI-only should be a successful no-op'
	assert_empty "$XINPUT_LOG"
	assert_no_xrandr_mutation
}

test_once_rejects_duplicate_exact_devices()
{
	setup_sandbox duplicate-device
	XINPUT_IDS='17
18'
	export XINPUT_IDS
	run_mapper --once
	assert_equal "$mapper_status" 1 'duplicate exact touch devices must fail'
	grep -Fq 'expected exactly one Raspberry Pi 7-inch Touchscreen device, found 2' "$sandbox/stderr" ||
		fail 'duplicate-device error must be actionable'
	assert_empty "$XINPUT_LOG"
}

test_once_fails_when_required_tool_is_missing()
{
	setup_sandbox missing-tool
	rm "$fake_bin/xinput"
	PATH=$fake_bin
	export PATH
	run_mapper --once
	PATH=$fake_bin:$system_path
	export PATH
	assert_equal "$mapper_status" 1 'missing xinput must fail'
	grep -Fq 'ERROR: required command not found: xinput' "$sandbox/stderr" ||
		fail 'missing-tool error must name xinput'
}

test_watch_maps_initial_state_and_one_randr_event()
{
	setup_sandbox watch-event
	run_mapper --watch
	assert_equal "$mapper_status" 0 'watch mapper should exit with its event source'
	assert_file_lines "$XINPUT_LOG" 'map-to-output 17 DSI-1
map-to-output 17 DSI-1' 'watch must map initially and once per event header'
	assert_file_lines "$XEV_LOG" '-root -event randr' 'watch must subscribe to RandR events'
}

test_wayland_never_invokes_x_commands()
{
	setup_sandbox wayland
	XDG_SESSION_TYPE=wayland
	export XDG_SESSION_TYPE
	run_mapper --watch
	assert_equal "$mapper_status" 0 'Wayland should be a successful no-op'
	assert_empty "$X_COMMAND_LOG"
	assert_empty "$XINPUT_LOG"
}

test_layout_variants_never_mutate_xrandr()
{
	for variant in mirror dsi-left dsi-right dsi-above either-primary; do
		setup_sandbox "layout-$variant"
		case $variant in
		mirror) XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1024 x 600, maximum 4096 x 4096
HDMI-1 connected primary 1024x600+0+0
DSI-1 connected 800x480+0+0' ;;
		dsi-left) XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1824 x 600, maximum 4096 x 4096
DSI-1 connected 800x480+0+0
HDMI-1 connected primary 1024x600+800+0' ;;
		dsi-right) XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1824 x 600, maximum 4096 x 4096
HDMI-1 connected primary 1024x600+0+0
DSI-1 connected 800x480+1024+0' ;;
		dsi-above) XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1024 x 1080, maximum 4096 x 4096
DSI-1 connected 800x480+0+0
HDMI-1 connected primary 1024x600+0+480' ;;
		either-primary) XRANDR_FIXTURE='Screen 0: minimum 320 x 200, current 1824 x 600, maximum 4096 x 4096
DSI-1 connected primary 800x480+0+0
HDMI-1 connected 1024x600+800+0' ;;
		esac
		export XRANDR_FIXTURE
		run_mapper --once
		assert_equal "$mapper_status" 0 "$variant layout should map successfully"
		assert_file_lines "$XINPUT_LOG" 'map-to-output 17 DSI-1' "$variant layout must use exact map boundary"
		assert_no_xrandr_mutation
	done
}

test_watch_exits_when_event_source_exits()
{
	setup_sandbox watch-exit
	run_mapper --watch
	assert_equal "$mapper_status" 0 'watch must exit when xev exits'
	assert_file_lines "$XINPUT_LOG" 'map-to-output 17 DSI-1
map-to-output 17 DSI-1' 'watch must not busy-loop after xev exits'
}

test_once_maps_exact_device_to_active_dsi
test_once_is_noop_for_inactive_dsi
test_once_is_noop_for_hdmi_only
test_once_rejects_duplicate_exact_devices
test_once_fails_when_required_tool_is_missing
test_watch_maps_initial_state_and_one_randr_event
test_wayland_never_invokes_x_commands
test_layout_variants_never_mutate_xrandr
test_watch_exits_when_event_source_exits

printf '%s\n' 'PASS: touch mapper tests'
