#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

require_root
require_command awk cat chmod cmp cp date diff dirname dkms find grep head install mkdir mktemp modinfo mv rm sed sha256sum tail

module_content_checksum()
{
	module_file=$1
	checksum_input=$module_file
	checksum_temporary=
	case $module_file in
	*.ko.xz)
		require_command xz
		checksum_temporary=$(mktemp)
		if ! xz -dc "$module_file" > "$checksum_temporary"; then
			rm -f "$checksum_temporary"
			return 1
		fi
		checksum_input=$checksum_temporary
		;;
	*.ko.gz)
		require_command gzip
		checksum_temporary=$(mktemp)
		if ! gzip -dc "$module_file" > "$checksum_temporary"; then
			rm -f "$checksum_temporary"
			return 1
		fi
		checksum_input=$checksum_temporary
		;;
	*.ko.zst)
		require_command zstd
		checksum_temporary=$(mktemp)
		if ! zstd -q -dc "$module_file" > "$checksum_temporary"; then
			rm -f "$checksum_temporary"
			return 1
		fi
		checksum_input=$checksum_temporary
		;;
	esac
	if ! checksum_record=$(sha256sum "$checksum_input"); then
		[ -z "$checksum_temporary" ] || rm -f "$checksum_temporary"
		return 1
	fi
	checksum=${checksum_record%% *}
	[ -z "$checksum_temporary" ] || rm -f "$checksum_temporary"
	[ -n "$checksum" ] || return 1
	printf '%s\n' "$checksum"
}

dkms_lifecycle_phase()
{
	lifecycle_status=$1
	lifecycle_version=$2
	case $lifecycle_status in
	'') printf '%s\n' absent ;;
	"$PROJECT_NAME/$lifecycle_version: added") printf '%s\n' added ;;
	"$PROJECT_NAME/$lifecycle_version, $KERNEL_RELEASE, $ARCH: built") printf '%s\n' built ;;
	"$PROJECT_NAME/$lifecycle_version, $KERNEL_RELEASE, $ARCH: installed") printf '%s\n' installed ;;
	*) printf '%s\n' unsupported ;;
	esac
}

find_dkms_module_artifact()
{
	artifact_root=$1
	artifact_module=$2
	find "$artifact_root" -type f \
		\( -name "$artifact_module.ko" -o -name "$artifact_module.ko.xz" \
		-o -name "$artifact_module.ko.gz" -o -name "$artifact_module.ko.zst" \) \
		-print 2>/dev/null | head -n 1
}

validator=${VALIDATE_SCRIPT:-$script_dir/validate.sh}
[ -x "$validator" ] || [ -f "$validator" ] || die "validation script not found: $validator"
sh "$validator" --offline

repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
overlay_output=${BUILD_DIR:-$repo_root/build}/$OVERLAY_NAME.dtbo
overlay_destination=$OVERLAY_DIRECTORY/$OVERLAY_NAME.dtbo
[ -f "$overlay_output" ] || die "validated overlay not found: $overlay_output"
[ -f "$ARMBIAN_ENV" ] || die "boot configuration not found: $ARMBIAN_ENV"

old_version=0.2.3
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
old_lifecycle_phase=$(dkms_lifecycle_phase "$old_status" "$old_version")
[ "$old_lifecycle_phase" != unsupported ] ||
	die "old DKMS lifecycle is not a single restorable target-kernel state: ${old_status:-absent}"
old_source_owned=0
if [ -f "$old_source/dkms.conf" ] &&
	grep -Fq 'PACKAGE_NAME="rockpi-rpi-touchscreen"' "$old_source/dkms.conf" &&
	grep -Fq "PACKAGE_VERSION=\"$old_version\"" "$old_source/dkms.conf"; then
	old_source_owned=1
fi
old_source_faithful=0
if [ "$old_source_owned" -eq 1 ] &&
	grep -Fxq 'BUILT_MODULE_NAME[0]="raspits_ft5426"' "$old_source/dkms.conf" &&
	grep -Fxq 'BUILT_MODULE_LOCATION[0]="."' "$old_source/dkms.conf" &&
	grep -Fxq 'DEST_MODULE_LOCATION[0]="/updates/dkms"' "$old_source/dkms.conf" &&
	grep -Fxq 'BUILT_MODULE_NAME[1]="panel_rockpi_rpi_touchscreen"' "$old_source/dkms.conf" &&
	grep -Fxq 'BUILT_MODULE_LOCATION[1]="."' "$old_source/dkms.conf" &&
	grep -Fxq 'DEST_MODULE_LOCATION[1]="/updates/dkms"' "$old_source/dkms.conf" &&
	[ "$(grep -Ec '^[[:space:]]*BUILT_MODULE_NAME\[[0-9]+\][[:space:]]*=' "$old_source/dkms.conf")" -eq 2 ] &&
	[ "$(grep -Ec '^[[:space:]]*BUILT_MODULE_LOCATION\[[0-9]+\][[:space:]]*=' "$old_source/dkms.conf")" -eq 2 ] &&
	[ "$(grep -Ec '^[[:space:]]*DEST_MODULE_LOCATION\[[0-9]+\][[:space:]]*=' "$old_source/dkms.conf")" -eq 2 ]; then
	old_source_faithful=1
fi
if [ "$old_registered" -eq 1 ]; then
	[ "$old_source_faithful" -eq 1 ] ||
		die "registered old DKMS source is not the faithful two-module $old_version release: $old_source"
fi
dkms_state_root=${DKMS_STATE_DIR:-/var/lib/dkms}
if [ "$old_was_installed" -eq 1 ]; then
	[ "$old_source_owned" -eq 1 ] ||
		die "installed old DKMS source is missing or unowned: $old_source"
	for module_name in $OLD_MODULE_NAMES; do
		old_built_baseline=$(find_dkms_module_artifact \
			"$dkms_state_root/$PROJECT_NAME/$old_version/$KERNEL_RELEASE" "$module_name")
		old_installed_baseline=$(modinfo -k "$KERNEL_RELEASE" -n "$module_name" 2>/dev/null || true)
		[ -n "$old_built_baseline" ] && [ -f "$old_installed_baseline" ] ||
			die "old installed $module_name module does not match its DKMS build; refusing migration"
		if ! old_built_checksum=$(module_content_checksum "$old_built_baseline"); then
			die "cannot verify old DKMS-built $module_name module content"
		fi
		if ! old_installed_checksum=$(module_content_checksum "$old_installed_baseline"); then
			die "cannot verify old installed $module_name module content"
		fi
		[ "$old_built_checksum" = "$old_installed_checksum" ] ||
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
new_lifecycle_phase=$(dkms_lifecycle_phase "$new_status_before" "$PROJECT_VERSION")
[ "$new_lifecycle_phase" != unsupported ] ||
	die "new DKMS lifecycle is not a single restorable target-kernel state: ${new_status_before:-absent}"

source_created=0
overlay_created=0
overlay_backup_created=0
overlay_replaced=0
previous_overlay_file=
new_dkms_mutation_attempted=0
dkms_install_attempted=0
old_retirement_attempted=0
old_source_snapshot_complete=0
new_dkms_state_snapshot_complete=0
old_dkms_state_snapshot_complete=0
backup_created=0
completed=0
stage_directory=
recovery_directory=
backup_file=${BACKUP_PATH:-$ARMBIAN_ENV.$PROJECT_NAME.$(date -u +%Y%m%dT%H%M%SZ).bak}

restore_dkms_lifecycle()
{
	restore_version=$1
	restore_phase=$2
	restore_expected=$3
	if ! restore_current=$(dkms status -m "$PROJECT_NAME" -v "$restore_version" 2>/dev/null); then
		return 1
	fi
	if [ "$restore_current" != "$restore_expected" ]; then
		if [ -n "$restore_current" ] &&
			! dkms remove -m "$PROJECT_NAME" -v "$restore_version" --all >/dev/null 2>&1; then
			return 1
		fi
		if ! restore_absent=$(dkms status -m "$PROJECT_NAME" -v "$restore_version" 2>/dev/null) ||
			[ -n "$restore_absent" ]; then
			return 1
		fi
		case $restore_phase in
		absent) ;;
		added)
			dkms add -m "$PROJECT_NAME" -v "$restore_version" >/dev/null 2>&1 || return 1
			;;
		built)
			dkms add -m "$PROJECT_NAME" -v "$restore_version" >/dev/null 2>&1 || return 1
			dkms build -m "$PROJECT_NAME" -v "$restore_version" -k "$KERNEL_RELEASE" >/dev/null 2>&1 || return 1
			;;
		installed)
			dkms add -m "$PROJECT_NAME" -v "$restore_version" >/dev/null 2>&1 || return 1
			dkms build -m "$PROJECT_NAME" -v "$restore_version" -k "$KERNEL_RELEASE" >/dev/null 2>&1 || return 1
			dkms install -m "$PROJECT_NAME" -v "$restore_version" -k "$KERNEL_RELEASE" >/dev/null 2>&1 || return 1
			;;
		*) return 1 ;;
		esac
	fi
	restore_final=$(dkms status -m "$PROJECT_NAME" -v "$restore_version" 2>/dev/null) &&
		[ "$restore_final" = "$restore_expected" ]
}

restore_dkms_state_tree()
{
	restore_state_version=$1
	restore_state_snapshot=$2
	restore_state_complete=$3
	restore_state_destination=$dkms_state_root/$PROJECT_NAME/$restore_state_version
	[ "$restore_state_complete" -eq 1 ] || return 0
	rm -rf "$restore_state_destination" || return 1
	if [ -d "$restore_state_snapshot" ]; then
		mkdir -p "$(dirname -- "$restore_state_destination")" || return 1
		cp -a "$restore_state_snapshot" "$restore_state_destination" || return 1
		diff -qr "$restore_state_snapshot" "$restore_state_destination" >/dev/null || return 1
	else
		[ ! -e "$restore_state_destination" ] || return 1
	fi
}

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
			elif ! rm -f "$backup_file" "$backup_file.sha256"; then
				rollback_failed=1
				rollback_note="$rollback_note restored boot configuration but could not remove transaction backup $backup_file;"
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
		if [ "$new_dkms_mutation_attempted" -eq 1 ]; then
			if ! restore_dkms_lifecycle "$PROJECT_VERSION" "$new_lifecycle_phase" "$new_status_before" ||
				! restore_dkms_state_tree "$PROJECT_VERSION" \
					"$recovery_directory/new-dkms-state" "$new_dkms_state_snapshot_complete" ||
				! new_status_restored=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null) ||
				[ "$new_status_restored" != "$new_status_before" ]; then
				rollback_failed=1
				new_source_retained=1
				rollback_note="$rollback_note DKMS registration baseline restoration failed; new source retained at $PROJECT_SOURCE_DIR;"
			fi
		fi
		if [ "$old_retirement_attempted" -eq 1 ] && [ "$old_source_owned" -eq 1 ] &&
			[ "$old_source_snapshot_complete" -eq 1 ]; then
			if ! rm -rf "$old_source" ||
				! cp -a "$recovery_directory/old-source" "$old_source" ||
				! diff -qr "$recovery_directory/old-source" "$old_source" >/dev/null; then
				rollback_failed=1
				rollback_note="$rollback_note old source restoration failed; snapshot retained at $recovery_directory/old-source;"
			fi
		fi
		if [ "$dkms_install_attempted" -eq 1 ] || [ "$old_retirement_attempted" -eq 1 ]; then
			old_reinstall_failed=0
			if [ "$dkms_install_attempted" -eq 1 ] && [ "$old_was_installed" -eq 1 ] &&
				old_current_before_restore=$(dkms status -m "$PROJECT_NAME" -v "$old_version" 2>/dev/null) &&
				[ "$old_current_before_restore" = "$old_status" ] &&
				! dkms install -m "$PROJECT_NAME" -v "$old_version" -k "$KERNEL_RELEASE" >/dev/null 2>&1; then
				old_reinstall_failed=1
			fi
			if [ "$old_reinstall_failed" -eq 1 ] ||
				! restore_dkms_lifecycle "$old_version" "$old_lifecycle_phase" "$old_status" ||
				! restore_dkms_state_tree "$old_version" \
					"$recovery_directory/old-dkms-state" "$old_dkms_state_snapshot_complete" ||
				! old_status_restored=$(dkms status -m "$PROJECT_NAME" -v "$old_version" 2>/dev/null) ||
				[ "$old_status_restored" != "$old_status" ]; then
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
		if [ "$dkms_install_attempted" -eq 1 ] || [ "$old_retirement_attempted" -eq 1 ]; then
			if ! restored_old_status=$(dkms status -m "$PROJECT_NAME" -v "$old_version" 2>&1) ||
				[ "$restored_old_status" != "$old_status" ]; then
				rollback_failed=1
				rollback_note="$rollback_note old DKMS lifecycle restoration failed (expected: ${old_status:-absent}; got: ${restored_old_status:-unavailable});"
			elif [ "$old_was_installed" -eq 1 ]; then
				for module_name in $OLD_MODULE_NAMES; do
					old_checksum_restoration_failed=0
					old_built_module=$(find_dkms_module_artifact \
						"$dkms_state_root/$PROJECT_NAME/$old_version/$KERNEL_RELEASE" "$module_name")
					old_installed_module=$(modinfo -k "$KERNEL_RELEASE" -n "$module_name" 2>/dev/null || true)
					if [ -z "$old_built_module" ] || [ ! -f "$old_installed_module" ]; then
						old_checksum_restoration_failed=1
					elif ! old_built_checksum=$(module_content_checksum "$old_built_module"); then
						old_checksum_restoration_failed=1
					elif ! old_installed_checksum=$(module_content_checksum "$old_installed_module"); then
						old_checksum_restoration_failed=1
					elif [ "$old_built_checksum" != "$old_installed_checksum" ]; then
						old_checksum_restoration_failed=1
					fi
					if [ "$old_checksum_restoration_failed" -eq 1 ]; then
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
if [ "$old_source_owned" -eq 1 ]; then
	cp -a "$old_source" "$recovery_directory/old-source"
	diff -qr "$old_source" "$recovery_directory/old-source" >/dev/null ||
		die 'old DKMS source recovery snapshot verification failed'
	old_source_snapshot_complete=1
fi
if [ -d "$dkms_state_root/$PROJECT_NAME/$PROJECT_VERSION" ]; then
	cp -a "$dkms_state_root/$PROJECT_NAME/$PROJECT_VERSION" \
		"$recovery_directory/new-dkms-state"
	diff -qr "$dkms_state_root/$PROJECT_NAME/$PROJECT_VERSION" \
		"$recovery_directory/new-dkms-state" >/dev/null ||
		die 'new DKMS state recovery snapshot verification failed'
fi
new_dkms_state_snapshot_complete=1
if [ -d "$dkms_state_root/$PROJECT_NAME/$old_version" ]; then
	cp -a "$dkms_state_root/$PROJECT_NAME/$old_version" \
		"$recovery_directory/old-dkms-state"
	diff -qr "$dkms_state_root/$PROJECT_NAME/$old_version" \
		"$recovery_directory/old-dkms-state" >/dev/null ||
		die 'old DKMS state recovery snapshot verification failed'
fi
old_dkms_state_snapshot_complete=1
mkdir -p "$stage_directory/src" "$stage_directory/scripts" "$stage_directory/LICENSES"
chmod 0755 "$stage_directory" "$stage_directory/src" "$stage_directory/scripts" "$stage_directory/LICENSES"
install -m 0644 "$repo_root/Makefile" "$repo_root/dkms.conf" "$repo_root/LICENSE" "$stage_directory/"
install -m 0644 "$repo_root/LICENSES/GPL-2.0-only.txt" "$stage_directory/LICENSES/"
install -m 0644 "$repo_root/LICENSES/UPSTREAM.md" "$stage_directory/LICENSES/"
install -m 0644 "$repo_root/src/ft5426_protocol.h" "$repo_root/src/raspits_ft5426.c" \
	"$repo_root/src/panel_rockpi_rpi_touchscreen.c" "$repo_root/src/display_compat.h" \
	"$repo_root/src/display_compat_core.h" "$repo_root/src/display_compat_core.c" \
	"$repo_root/src/display_compat_main.c" "$stage_directory/src/"
install -m 0755 "$repo_root/scripts/dkms-make.sh" "$stage_directory/scripts/"
source_digest()
{
	(
		cd "$1"
		sha256sum Makefile dkms.conf src/ft5426_protocol.h src/raspits_ft5426.c \
			src/panel_rockpi_rpi_touchscreen.c src/display_compat.h \
			src/display_compat_core.h src/display_compat_core.c src/display_compat_main.c \
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
	new_dkms_mutation_attempted=1
	dkms add -m "$PROJECT_NAME" -v "$PROJECT_VERSION" ||
		die 'DKMS package could not be added'
fi
new_dkms_mutation_attempted=1
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
	built_module=$(find_dkms_module_artifact \
		"$dkms_state_root/$PROJECT_NAME/$PROJECT_VERSION/$KERNEL_RELEASE" "$module_name")
	[ -n "$built_module" ] || die "cannot locate the DKMS-built $module_name module"
	installed_module=$(modinfo -k "$KERNEL_RELEASE" -n "$module_name")
	[ -f "$installed_module" ] || die "installed module not found: $installed_module"
	if ! built_checksum=$(module_content_checksum "$built_module"); then
		die "cannot verify DKMS-built $module_name module content"
	fi
	if ! installed_checksum=$(module_content_checksum "$installed_module"); then
		die "cannot verify installed $module_name module content"
	fi
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
	rockpi_rk3399_display_compat) expected_alias='of:N*T*Crockpi,rk3399-dsi1-rpi-touchscreen-compat' ;;
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
if [ "$old_registered" -eq 1 ]; then
	old_retirement_attempted=1
	dkms remove -m "$PROJECT_NAME" -v "$old_version" --all ||
		die "old DKMS $old_version retirement failed"
	retired_old_status=$(dkms status -m "$PROJECT_NAME" -v "$old_version") ||
		die "cannot verify retired old DKMS $old_version lifecycle"
	[ -z "$retired_old_status" ] ||
		die "old DKMS $old_version lifecycle remained after retirement: $retired_old_status"
	if [ "$old_source_owned" -eq 1 ]; then
		rm -rf "$old_source" || die "old DKMS source retirement failed: $old_source"
		[ ! -e "$old_source" ] || die "old DKMS source remained after retirement: $old_source"
	fi
elif [ "$old_source_owned" -eq 1 ]; then
	old_retirement_attempted=1
	rm -rf "$old_source" || die "old DKMS source retirement failed: $old_source"
	[ ! -e "$old_source" ] || die "old DKMS source remained after retirement: $old_source"
fi
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

printf 'PASS: installed %s/%s and verified all three modules, source, backup, boot token, and DTBO checksums\n' \
	"$PROJECT_NAME" "$PROJECT_VERSION"
printf 'NEXT: installation is complete; no automatic power action occurs. Obtain fresh authorization before any reboot or shutdown.\n'
printf 'NEXT: first authorized boot: keep HDMI disconnected; validate DSI-1, RGB, and physical touch; then hot-plug HDMI.\n'
printf 'ROLLBACK: sudo sh scripts/uninstall.sh (or use docs/recovery.md offline).\n'
