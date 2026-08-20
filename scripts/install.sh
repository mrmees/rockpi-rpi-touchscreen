#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

require_root
require_command awk cat chmod cmp cp date diff dirname dkms find grep head install mkdir mktemp modinfo mv rm sed sha256sum tail

validator=${VALIDATE_SCRIPT:-$script_dir/validate.sh}
[ -x "$validator" ] || [ -f "$validator" ] || die "validation script not found: $validator"
sh "$validator" --offline

repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
overlay_output=${BUILD_DIR:-$repo_root/build}/$OVERLAY_NAME.dtbo
overlay_destination=$OVERLAY_DIRECTORY/$OVERLAY_NAME.dtbo
[ -f "$overlay_output" ] || die "validated overlay not found: $overlay_output"
[ -f "$ARMBIAN_ENV" ] || die "boot configuration not found: $ARMBIAN_ENV"

old_version=0.2.1
old_source=${DKMS_TREE:-/usr/src}/${PROJECT_NAME}-${old_version}
if ! old_status=$(dkms status -m "$PROJECT_NAME" -v "$old_version" 2>&1); then
	printf 'ERROR: cannot verify old DKMS state; retained %s/%s registration and source %s: %s\n' \
		"$PROJECT_NAME" "$old_version" "$old_source" "$old_status" >&2
	exit 1
fi
old_registered=0
if printf '%s\n' "$old_status" | dkms_status_has_version "$old_version"; then
	old_registered=1
fi
old_expected_installed="$PROJECT_NAME/$old_version, $KERNEL_RELEASE, $ARCH: installed"
old_was_installed=0
if printf '%s\n' "$old_status" | grep -Fxq "$old_expected_installed"; then
	old_was_installed=1
fi
old_source_owned=0
if [ -f "$old_source/dkms.conf" ] &&
	grep -Fq 'PACKAGE_NAME="rockpi-rpi-touchscreen"' "$old_source/dkms.conf" &&
	grep -Fq "PACKAGE_VERSION=\"$old_version\"" "$old_source/dkms.conf"; then
	old_source_owned=1
fi
dkms_state_root=${DKMS_STATE_DIR:-/var/lib/dkms}
if [ "$old_was_installed" -eq 1 ]; then
	[ "$old_source_owned" -eq 1 ] ||
		die "installed old DKMS source is missing or unowned: $old_source"
	for module_name in $MODULE_NAMES; do
		old_built_baseline=$(find "$dkms_state_root/$PROJECT_NAME/$old_version/$KERNEL_RELEASE" \
			-type f -name "$module_name.ko" -print 2>/dev/null | head -n 1)
		old_installed_baseline=$(modinfo -k "$KERNEL_RELEASE" -n "$module_name" 2>/dev/null || true)
		[ -n "$old_built_baseline" ] && [ -f "$old_installed_baseline" ] &&
			cmp -s "$old_built_baseline" "$old_installed_baseline" ||
			die "old installed $module_name module does not match its DKMS build; refusing migration"
	done
fi
if ! new_status_before=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>&1); then
	printf 'ERROR: cannot capture DKMS registration baseline for %s/%s: %s\n' \
		"$PROJECT_NAME" "$PROJECT_VERSION" "$new_status_before" >&2
	exit 1
fi
new_was_registered=0
if printf '%s\n' "$new_status_before" | dkms_status_has_version "$PROJECT_VERSION"; then
	new_was_registered=1
fi

source_created=0
overlay_created=0
overlay_backup_created=0
overlay_replaced=0
previous_overlay_file=
dkms_add_attempted=0
dkms_install_attempted=0
backup_created=0
completed=0
stage_directory=
recovery_directory=
backup_file=${BACKUP_PATH:-$ARMBIAN_ENV.$PROJECT_NAME.$(date -u +%Y%m%dT%H%M%SZ).bak}

rollback()
{
	transaction_status=$?
	trap - EXIT HUP INT TERM
	rollback_failed=0
	rollback_note=
	new_source_retained=0
	if [ "$completed" -ne 1 ]; then
		if [ "$backup_created" -eq 1 ] && [ -f "$backup_file" ]; then
			if ! try_atomic_install_file "$backup_file" "$ARMBIAN_ENV"; then
				rollback_failed=1
				rollback_note="$rollback_note boot configuration backup retained at $backup_file;"
			fi
		fi
		if [ "$overlay_created" -eq 1 ] && ! rm -f "$overlay_destination"; then
			rollback_failed=1
			rollback_note="$rollback_note overlay removal failed: $overlay_destination;"
		fi
		if [ "$overlay_replaced" -eq 1 ] && [ -f "$previous_overlay_file" ]; then
			if try_atomic_install_file "$previous_overlay_file" "$overlay_destination"; then
				rm -f "$previous_overlay_file"
				previous_overlay_file=
				overlay_backup_created=0
			else
				rollback_failed=1
				rollback_note="$rollback_note prior overlay retained at $previous_overlay_file;"
			fi
		elif [ "$overlay_backup_created" -eq 1 ] && [ -f "$previous_overlay_file" ]; then
			if ! rm -f "$previous_overlay_file"; then
				rollback_failed=1
				rollback_note="$rollback_note overlay backup cleanup failed: $previous_overlay_file;"
			fi
		fi
		if [ "$dkms_add_attempted" -eq 1 ]; then
			if ! new_status_after=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null); then
				rollback_failed=1
				new_source_retained=1
				rollback_note="$rollback_note DKMS registration baseline inspection failed; new source retained at $PROJECT_SOURCE_DIR;"
			elif [ "$new_status_after" != "$new_status_before" ]; then
				dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all >/dev/null 2>&1 || true
				if ! new_status_restored=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null) ||
					[ "$new_status_restored" != "$new_status_before" ]; then
					rollback_failed=1
					new_source_retained=1
					rollback_note="$rollback_note DKMS registration baseline restoration failed; new source retained at $PROJECT_SOURCE_DIR;"
				fi
			fi
		fi
		if [ "$dkms_install_attempted" -eq 1 ] && [ "$old_was_installed" -eq 1 ]; then
			if ! dkms install -m "$PROJECT_NAME" -v "$old_version" -k "$KERNEL_RELEASE" >/dev/null 2>&1; then
				rollback_failed=1
				rollback_note="$rollback_note old DKMS reinstall failed; retained old source at $old_source;"
			fi
		fi
		if [ -n "$recovery_directory" ] &&
			[ -f "$recovery_directory/prior-modules.snapshot-complete" ]; then
			for module_name in $MODULE_NAMES; do
				prior_paths=$recovery_directory/prior-modules/$module_name.paths
				current_paths=$recovery_directory/prior-modules/$module_name.current-paths
				find "${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE" -type f \
					\( -name "$module_name.ko" -o -name "$module_name.ko.xz" \
					-o -name "$module_name.ko.gz" -o -name "$module_name.ko.zst" \) \
					-print > "$current_paths" 2>/dev/null || true
				while IFS= read -r current_path; do
					[ -n "$current_path" ] || continue
					if ! rm -f "$current_path"; then
						rollback_failed=1
						rollback_note="$rollback_note partial $module_name removal failed: $current_path;"
					fi
				done < "$current_paths"
				prior_index=0
				while IFS= read -r prior_path; do
					[ -n "$prior_path" ] || continue
					prior_index=$((prior_index + 1))
					prior_module=$recovery_directory/prior-modules/$module_name.$prior_index.backup
					if ! try_atomic_install_file "$prior_module" "$prior_path" ||
						! cmp -s "$prior_module" "$prior_path"; then
						rollback_failed=1
						rollback_note="$rollback_note prior $module_name module retained at $prior_module;"
					fi
				done < "$prior_paths"
				restored_count=$(find "${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE" -type f \
					\( -name "$module_name.ko" -o -name "$module_name.ko.xz" \
					-o -name "$module_name.ko.gz" -o -name "$module_name.ko.zst" \) \
					-print 2>/dev/null | awk 'END { print NR + 0 }')
				[ "$restored_count" -eq "$prior_index" ] || {
					rollback_failed=1
					rollback_note="$rollback_note $module_name path-set restoration failed;"
				}
			done
		fi
		if [ "$dkms_install_attempted" -eq 1 ]; then
			if ! restored_old_status=$(dkms status -m "$PROJECT_NAME" -v "$old_version" 2>&1) ||
				[ "$restored_old_status" != "$old_status" ]; then
				rollback_failed=1
				rollback_note="$rollback_note old DKMS lifecycle restoration failed (expected: ${old_status:-absent}; got: ${restored_old_status:-unavailable});"
			elif [ "$old_was_installed" -eq 1 ]; then
				for module_name in $MODULE_NAMES; do
					old_built_module=$(find "${DKMS_STATE_DIR:-/var/lib/dkms}/$PROJECT_NAME/$old_version/$KERNEL_RELEASE" \
						-type f -name "$module_name.ko" -print 2>/dev/null | head -n 1)
					old_installed_module=$(modinfo -k "$KERNEL_RELEASE" -n "$module_name" 2>/dev/null || true)
					if [ -z "$old_built_module" ] || [ ! -f "$old_installed_module" ] ||
						! cmp -s "$old_built_module" "$old_installed_module"; then
						rollback_failed=1
						rollback_note="$rollback_note old installed $module_name checksum restoration failed;"
					fi
				done
			fi
		fi
		if [ "$source_created" -eq 1 ] && [ "$new_source_retained" -eq 0 ] &&
			! rm -rf "$PROJECT_SOURCE_DIR"; then
			rollback_failed=1
			rollback_note="$rollback_note new source removal failed: $PROJECT_SOURCE_DIR;"
		fi
		if [ -n "$stage_directory" ] && [ -d "$stage_directory" ] &&
			! rm -rf "$stage_directory"; then
			rollback_failed=1
			rollback_note="$rollback_note staged source cleanup failed: $stage_directory;"
		fi
		if [ "$rollback_failed" -eq 0 ] && [ -n "$recovery_directory" ] &&
			[ -d "$recovery_directory" ] && ! rm -rf "$recovery_directory"; then
			rollback_failed=1
			rollback_note="$rollback_note transaction recovery cleanup failed: $recovery_directory;"
		fi
	fi
	if [ "$rollback_failed" -ne 0 ]; then
		if [ -n "$recovery_directory" ] && [ -d "$recovery_directory" ]; then
			rollback_note="$rollback_note recovery artifacts retained at $recovery_directory;"
		fi
		printf 'ERROR: transaction failed with status %s; rollback also failed:%s\n' \
			"$transaction_status" "$rollback_note" >&2
		exit 1
	fi
	exit "$transaction_status"
}
trap rollback EXIT HUP INT TERM

source_parent=$(dirname -- "$PROJECT_SOURCE_DIR")
mkdir -p "$source_parent"
recovery_directory=$(mktemp -d "$source_parent/.${PROJECT_NAME}.transaction.XXXXXX")
stage_directory=$(mktemp -d "$source_parent/.${PROJECT_NAME}.stage.XXXXXX")
mkdir -p "$stage_directory/src" "$stage_directory/scripts" "$stage_directory/LICENSES"
chmod 0755 "$stage_directory" "$stage_directory/src" "$stage_directory/scripts" "$stage_directory/LICENSES"
install -m 0644 "$repo_root/Makefile" "$repo_root/dkms.conf" "$repo_root/LICENSE" "$stage_directory/"
install -m 0644 "$repo_root/LICENSES/GPL-2.0-only.txt" "$stage_directory/LICENSES/"
install -m 0644 "$repo_root/LICENSES/UPSTREAM.md" "$stage_directory/LICENSES/"
install -m 0644 "$repo_root/src/ft5426_protocol.h" "$repo_root/src/raspits_ft5426.c" \
	"$repo_root/src/panel_rockpi_rpi_touchscreen.c" "$stage_directory/src/"
install -m 0755 "$repo_root/scripts/dkms-make.sh" "$stage_directory/scripts/"
source_digest()
{
	(
		cd "$1"
		sha256sum Makefile dkms.conf src/ft5426_protocol.h src/raspits_ft5426.c \
			src/panel_rockpi_rpi_touchscreen.c \
			scripts/dkms-make.sh LICENSE LICENSES/GPL-2.0-only.txt LICENSES/UPSTREAM.md | sha256sum | awk '{print $1}'
	)
}
expected_source_digest=$(source_digest "$stage_directory")

if [ -e "$PROJECT_SOURCE_DIR" ]; then
	[ -d "$PROJECT_SOURCE_DIR" ] || die "DKMS source path is not a directory: $PROJECT_SOURCE_DIR"
	[ -f "$PROJECT_SOURCE_DIR/dkms.conf" ] || die "DKMS source path is not owned by this project: $PROJECT_SOURCE_DIR"
	if ! diff -qr "$stage_directory" "$PROJECT_SOURCE_DIR" >/dev/null; then
		die "same-version DKMS source differs: $PROJECT_SOURCE_DIR (bump PROJECT_VERSION)"
	fi
	rm -rf "$stage_directory"
	stage_directory=
else
	mv "$stage_directory" "$PROJECT_SOURCE_DIR"
	stage_directory=
	source_created=1
fi
[ "$(source_digest "$PROJECT_SOURCE_DIR")" = "$expected_source_digest" ] ||
	die 'installed DKMS source checksum verification failed'

if [ "$new_was_registered" -eq 0 ]; then
	dkms_add_attempted=1
	dkms add -m "$PROJECT_NAME" -v "$PROJECT_VERSION" ||
		die 'DKMS package could not be added'
fi
dkms build -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE"

mkdir -p "$recovery_directory/prior-modules"
for module_name in $MODULE_NAMES; do
	prior_paths=$recovery_directory/prior-modules/$module_name.paths
	find "${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE" -type f \
		\( -name "$module_name.ko" -o -name "$module_name.ko.xz" \
		-o -name "$module_name.ko.gz" -o -name "$module_name.ko.zst" \) \
		-print > "$prior_paths" 2>/dev/null || true
	prior_index=0
	while IFS= read -r prior_module_path; do
		[ -n "$prior_module_path" ] || continue
		prior_index=$((prior_index + 1))
		prior_module_backup=$recovery_directory/prior-modules/$module_name.$prior_index.backup
		cp "$prior_module_path" "$prior_module_backup"
		cmp -s "$prior_module_path" "$prior_module_backup" ||
			die "recovery snapshot verification failed for $prior_module_path"
	done < "$prior_paths"
done
: > "$recovery_directory/prior-modules.snapshot-complete"
dkms_install_attempted=1
dkms install -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE"

expected_dkms_status="$PROJECT_NAME/$PROJECT_VERSION, $KERNEL_RELEASE, $ARCH: installed"
dkms_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION") ||
	die "cannot verify DKMS status for $PROJECT_NAME/$PROJECT_VERSION"
printf '%s\n' "$dkms_status" | grep -Fxq "$expected_dkms_status" ||
	die "DKMS did not report exact installed state: $expected_dkms_status"
for module_name in $MODULE_NAMES; do
	built_module=$(find "$dkms_state_root/$PROJECT_NAME/$PROJECT_VERSION/$KERNEL_RELEASE" \
		-type f -name "$module_name.ko" -print 2>/dev/null | head -n 1)
	[ -n "$built_module" ] || die "cannot locate the DKMS-built $module_name module"
	installed_module=$(modinfo -k "$KERNEL_RELEASE" -n "$module_name")
	[ -f "$installed_module" ] || die "installed module not found: $installed_module"
	built_checksum=$(sha256sum "$built_module" | awk '{print $1}')
	installed_checksum=$(sha256sum "$installed_module" | awk '{print $1}')
	[ "$built_checksum" = "$installed_checksum" ] ||
		die "installed $module_name checksum does not match the DKMS build"
	[ "$(modinfo -F license "$built_module")" = 'GPL v2' ] &&
		[ "$(modinfo -F license "$installed_module")" = 'GPL v2' ] ||
		die "$module_name built or installed module license is not GPL v2"
	built_vermagic=$(modinfo -F vermagic "$built_module")
	installed_vermagic=$(modinfo -F vermagic "$installed_module")
	[ "$built_vermagic" = "$installed_vermagic" ] ||
		die "$module_name built and installed vermagic differ"
	case $built_vermagic in
	"$KERNEL_RELEASE "*) ;;
	*) die "$module_name vermagic does not match $KERNEL_RELEASE" ;;
	esac
	case $module_name in
	raspits_ft5426) expected_alias='of:N*T*Craspits_ft5426' ;;
	panel_rockpi_rpi_touchscreen) expected_alias='of:N*T*Crockpi,rpi-7inch-touchscreen-panel' ;;
	*) die "no module metadata policy for $module_name" ;;
	esac
	modinfo -F alias "$built_module" | grep -Fxq "$expected_alias" ||
		die "$module_name built module is missing device-tree alias $expected_alias"
	modinfo -F alias "$installed_module" | grep -Fxq "$expected_alias" ||
		die "$module_name installed module is missing device-tree alias $expected_alias"
done

if [ ! -e "$overlay_destination" ]; then
	overlay_created=1
	atomic_install_file "$overlay_output" "$overlay_destination"
elif ! cmp -s "$overlay_output" "$overlay_destination"; then
	previous_overlay_file=$(mktemp "$BOOT_DIRECTORY/.${PROJECT_NAME}.overlay-backup.XXXXXX")
	overlay_backup_created=1
	cp "$overlay_destination" "$previous_overlay_file"
	overlay_replaced=1
	atomic_install_file "$overlay_output" "$overlay_destination"
fi
cmp "$overlay_output" "$overlay_destination" || die 'installed DTBO checksum verification failed'

if [ ! -e "$backup_file" ]; then
	cp "$ARMBIAN_ENV" "$backup_file"
	sha256sum "$backup_file" > "$backup_file.sha256"
	backup_created=1
fi
[ -f "$backup_file.sha256" ] || die "boot backup checksum not found: $backup_file.sha256"
sha256sum -c "$backup_file.sha256" >/dev/null || die "boot backup checksum verification failed: $backup_file"
add_overlay_token "$ARMBIAN_ENV" "$OVERLAY_TOKEN"
[ "$(awk -v token="$OVERLAY_TOKEN" '
	/^[[:space:]]*user_overlays[[:space:]]*=/ {
		value = $0
		sub(/^[^=]*=/, "", value)
		n = split(value, tokens, /[[:space:]]+/)
		for (i = 1; i <= n; i++) if (tokens[i] == token) count++
	}
	END { print count + 0 }
' "$ARMBIAN_ENV")" -eq 1 ] || die 'boot configuration does not contain exactly one project overlay token'
[ "$(source_digest "$PROJECT_SOURCE_DIR")" = "$expected_source_digest" ] ||
	die 'final installed DKMS source checksum verification failed'
cmp "$overlay_output" "$overlay_destination" || die 'final installed DTBO checksum verification failed'
completed=1
if [ "$overlay_replaced" -eq 1 ]; then
	rm -f "$previous_overlay_file"
	previous_overlay_file=
	overlay_backup_created=0
	overlay_replaced=0
fi
rm -rf "$recovery_directory"
recovery_directory=
trap - EXIT HUP INT TERM

if [ "$old_registered" -eq 1 ]; then
	if dkms remove -m "$PROJECT_NAME" -v "$old_version" --all; then
		if [ "$old_source_owned" -eq 1 ]; then
			rm -rf "$old_source"
		fi
	else
		printf 'WARNING: installed %s/%s; retained old DKMS %s and source %s because removal failed\n' \
			"$PROJECT_NAME" "$PROJECT_VERSION" "$old_version" "$old_source" >&2
	fi
elif [ "$old_source_owned" -eq 1 ]; then
	rm -rf "$old_source"
fi

printf 'PASS: installed %s/%s and verified both modules, source, backup, boot token, and DTBO checksums\n' \
	"$PROJECT_NAME" "$PROJECT_VERSION"
printf 'NEXT: power off; follow docs/wiring.md; boot with HDMI; run the README first-boot checks.\n'
printf 'ROLLBACK: sudo sh scripts/uninstall.sh (or use docs/recovery.md offline).\n'
