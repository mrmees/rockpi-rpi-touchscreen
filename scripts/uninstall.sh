#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

dry_run=0
offline_boot_root=
case ${1:-} in
'') ;;
--dry-run) dry_run=1 ;;
--offline-boot-root)
	[ "$#" -eq 2 ] || die "usage: $0 [--dry-run|--offline-boot-root TARGET_ROOT]"
	offline_boot_root=$2
	case $offline_boot_root in
	/*) ;;
	*) die 'offline target root must be an absolute path' ;;
	esac
	[ -d "$offline_boot_root" ] || die "offline target root does not exist: $offline_boot_root"
	;;
*) die "usage: $0 [--dry-run|--offline-boot-root TARGET_ROOT]" ;;
esac

require_root
if [ -n "$offline_boot_root" ]; then
	require_command awk chmod mktemp mv rm
	target_config=$offline_boot_root/boot/armbianEnv.txt
	[ -f "$target_config" ] || die "target boot configuration not found: $target_config"
	remove_overlay_token "$target_config" "$OVERLAY_TOKEN"
	printf 'PASS: removed %s overlay token from %s\n' "$OVERLAY_TOKEN" "$target_config"
	exit 0
fi

require_command awk chmod cmp cp depmod diff dkms find grep ln mkdir mktemp mv rm stat
overlay_destination=$OVERLAY_DIRECTORY/$OVERLAY_NAME.dtbo
touch_mapper_source=$PROJECT_SOURCE_DIR/scripts/map-touchscreen.sh
touch_autostart_source=$PROJECT_SOURCE_DIR/assets/rockpi-rpi-touchscreen-touch-map.desktop

runtime_asset_state()
{
	runtime_source=$1
	runtime_destination=$2
	runtime_mode=$3
	if [ ! -e "$runtime_destination" ] && [ ! -L "$runtime_destination" ]; then
		printf '%s\n' absent
	elif [ -f "$runtime_destination" ] && [ ! -L "$runtime_destination" ] &&
		[ -f "$runtime_source" ] && cmp -s "$runtime_source" "$runtime_destination" &&
		[ "$(stat -c '%a' "$runtime_destination")" = "$runtime_mode" ]; then
		printf '%s\n' owned
	else
		printf '%s\n' modified
	fi
}

runtime_asset_matches()
{
	runtime_match_source=$1
	runtime_match_destination=$2
	runtime_match_mode=$3
	[ -f "$runtime_match_destination" ] && [ ! -L "$runtime_match_destination" ] &&
		cmp -s "$runtime_match_source" "$runtime_match_destination" &&
		[ "$(stat -c '%a' "$runtime_match_destination")" = "$runtime_match_mode" ]
}

if [ "$dry_run" -eq 1 ]; then
	mapper_state=$(runtime_asset_state "$touch_mapper_source" "$TOUCH_MAPPER_DESTINATION" 755)
	autostart_state=$(runtime_asset_state "$touch_autostart_source" "$TOUCH_AUTOSTART_DESTINATION" 644)
	temporary_config=$(mktemp "${ARMBIAN_ENV}.XXXXXX") || die 'cannot create dry-run temporary configuration'
	trap 'rm -f "$temporary_config"' HUP INT TERM EXIT
	cp "$ARMBIAN_ENV" "$temporary_config"
	remove_overlay_token "$temporary_config" "$OVERLAY_TOKEN"
	printf 'REMOVE: %s\n' "$overlay_destination"
	printf 'REMOVE: %s\n' "$PROJECT_SOURCE_DIR"
	case $autostart_state in
	owned) printf 'REMOVE: %s\n' "$TOUCH_AUTOSTART_DESTINATION" ;;
	modified) printf 'RETAIN MODIFIED: %s\n' "$TOUCH_AUTOSTART_DESTINATION" ;;
	esac
	case $mapper_state in
	owned)
		if [ "$autostart_state" = modified ]; then
			printf 'RETAIN DEPENDENCY: %s\n' "$TOUCH_MAPPER_DESTINATION"
		else
			printf 'REMOVE: %s\n' "$TOUCH_MAPPER_DESTINATION"
		fi
		;;
	modified) printf 'RETAIN MODIFIED: %s\n' "$TOUCH_MAPPER_DESTINATION" ;;
	esac
	printf 'CONFIG: %s\n' "$ARMBIAN_ENV"
	for module_name in $MODULE_NAMES; do
		printf 'MODULE: %s\n' "$module_name"
	done
	printf 'DKMS REMOVE: %s/%s\n' "$PROJECT_NAME" "$PROJECT_VERSION"
	grep -m 1 '^[[:space:]]*user_overlays[[:space:]]*=' "$temporary_config" || printf 'user_overlays=\n'
	rm -f "$temporary_config"
	trap - HUP INT TERM EXIT
	exit 0
fi

[ -f "$ARMBIAN_ENV" ] || die "boot configuration not found: $ARMBIAN_ENV"
source_present=0
if [ -e "$PROJECT_SOURCE_DIR" ]; then
	[ -d "$PROJECT_SOURCE_DIR" ] || die "DKMS source path is not a directory: $PROJECT_SOURCE_DIR"
	[ -f "$PROJECT_SOURCE_DIR/dkms.conf" ] &&
		grep -Fxq "PACKAGE_NAME=\"$PROJECT_NAME\"" "$PROJECT_SOURCE_DIR/dkms.conf" &&
		grep -Fxq "PACKAGE_VERSION=\"$PROJECT_VERSION\"" "$PROJECT_SOURCE_DIR/dkms.conf" ||
		die "source path is not owned by this project: $PROJECT_SOURCE_DIR"
	source_present=1
fi

mapper_state=$(runtime_asset_state "$touch_mapper_source" "$TOUCH_MAPPER_DESTINATION" 755)
autostart_state=$(runtime_asset_state "$touch_autostart_source" "$TOUCH_AUTOSTART_DESTINATION" 644)
if [ "$mapper_state" = modified ]; then
	printf 'RETAIN MODIFIED: %s\n' "$TOUCH_MAPPER_DESTINATION"
fi
if [ "$autostart_state" = modified ]; then
	printf 'RETAIN MODIFIED: %s\n' "$TOUCH_AUTOSTART_DESTINATION"
fi

dkms_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION") ||
	die "cannot determine DKMS registration state for $PROJECT_NAME/$PROJECT_VERSION"
dkms_registered=0
if printf '%s\n' "$dkms_status" | dkms_status_has_version "$PROJECT_VERSION"; then
	dkms_registered=1
	[ "$source_present" -eq 1 ] ||
		die "cannot transactionally remove registered DKMS package without owned source: $PROJECT_SOURCE_DIR"
	expected_added="$PROJECT_NAME/$PROJECT_VERSION: added"
	expected_built="$PROJECT_NAME/$PROJECT_VERSION, $KERNEL_RELEASE, $ARCH: built"
	expected_installed="$PROJECT_NAME/$PROJECT_VERSION, $KERNEL_RELEASE, $ARCH: installed"
	case $dkms_status in
	"$expected_added"|"$expected_built"|"$expected_installed") ;;
	*) die "cannot transactionally restore unsupported DKMS lifecycle state: $dkms_status" ;;
	esac
fi

source_parent=$(dirname -- "$PROJECT_SOURCE_DIR")
mkdir -p "$source_parent"
transaction_directory=$(mktemp -d "$source_parent/.${PROJECT_NAME}.uninstall.XXXXXX")
completed=0
dkms_remove_attempted=0
rollback_failed=0
rollback_note=
dependency_index_restore_failed=0
dkms_state_restore_failed=0
mapper_remove_attempted=0
autostart_remove_attempted=0
mapper_claim_held=0
mapper_claim_recovery=
autostart_claim_held=0
autostart_claim_recovery=
mapper_dependency_restore_failed=0
dkms_state_root=${DKMS_STATE_DIR:-/var/lib/dkms}
dkms_state_destination=$dkms_state_root/$PROJECT_NAME/$PROJECT_VERSION
trap 'snapshot_status=$?; trap - EXIT HUP INT TERM; rm -rf "$transaction_directory"; exit "$snapshot_status"' \
	EXIT HUP INT TERM

snapshot_module_paths()
{
	mkdir -p "$transaction_directory/modules"
	for module_name in $MODULE_NAMES; do
		paths=$transaction_directory/modules/$module_name.paths
		find "${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE" -type f \
			\( -name "$module_name.ko" -o -name "$module_name.ko.xz" \
			-o -name "$module_name.ko.gz" -o -name "$module_name.ko.zst" \) \
			-print > "$paths" 2>/dev/null || true
		index=0
		while IFS= read -r module_path; do
			[ -n "$module_path" ] || continue
			index=$((index + 1))
			backup=$transaction_directory/modules/$module_name.$index.backup
			cp "$module_path" "$backup"
			cmp -s "$module_path" "$backup" || die "cannot verify uninstall snapshot: $module_path"
		done < "$paths"
	done
	: > "$transaction_directory/modules.snapshot-complete"
}

snapshot_runtime_asset()
{
	runtime_asset_name=$1
	runtime_source=$2
	runtime_destination=$3
	runtime_expected_mode=$4
	runtime_backup=$transaction_directory/runtime/$runtime_asset_name
	runtime_snapshot_state=modified
	if ! runtime_asset_matches "$runtime_source" "$runtime_destination" "$runtime_expected_mode"; then
		printf 'RETAIN MODIFIED: %s\n' "$runtime_destination"
		return 0
	fi
	if ! cp "$runtime_destination" "$runtime_backup"; then
		if ! runtime_asset_matches "$runtime_source" "$runtime_destination" "$runtime_expected_mode"; then
			rm -f "$runtime_backup" "$runtime_backup.mode" >/dev/null 2>&1 || true
			printf 'RETAIN MODIFIED: %s\n' "$runtime_destination"
			return 0
		fi
		die "cannot snapshot runtime asset: $runtime_destination"
	fi
	chmod "$runtime_expected_mode" "$runtime_backup" ||
		die "cannot snapshot runtime asset mode: $runtime_destination"
	if ! runtime_asset_matches "$runtime_source" "$runtime_backup" "$runtime_expected_mode" ||
		! runtime_asset_matches "$runtime_source" "$runtime_destination" "$runtime_expected_mode"; then
		rm -f "$runtime_backup" "$runtime_backup.mode" >/dev/null 2>&1 || true
		printf 'RETAIN MODIFIED: %s\n' "$runtime_destination"
		return 0
	fi
	printf '%s\n' "$runtime_expected_mode" > "$runtime_backup.mode"
	runtime_snapshot_state=owned
}

snapshot_runtime_assets()
{
	mkdir -p "$transaction_directory/runtime"
	if [ "$mapper_state" = owned ]; then
		snapshot_runtime_asset mapper "$touch_mapper_source" \
			"$TOUCH_MAPPER_DESTINATION" 755
		mapper_state=$runtime_snapshot_state
	fi
	if [ "$autostart_state" = owned ]; then
		snapshot_runtime_asset autostart "$touch_autostart_source" \
			"$TOUCH_AUTOSTART_DESTINATION" 644
		autostart_state=$runtime_snapshot_state
	fi
	: > "$transaction_directory/runtime.snapshot-complete"
}

restore_runtime_asset()
{
	runtime_backup=$1
	runtime_destination=$2
	IFS= read -r runtime_mode < "$runtime_backup.mode" || return 1
	if [ -e "$runtime_destination" ] || [ -L "$runtime_destination" ]; then
		if [ -f "$runtime_destination" ] && [ ! -L "$runtime_destination" ] &&
			cmp -s "$runtime_backup" "$runtime_destination" &&
			[ "$(stat -c '%a' "$runtime_destination")" = "$runtime_mode" ]; then
			return 0
		fi
		printf 'RETAIN MODIFIED: %s\n' "$runtime_destination"
		return 1
	fi
	runtime_directory=$(dirname -- "$runtime_destination")
	runtime_temporary=$(mktemp "$runtime_directory/.${PROJECT_NAME}.restore.XXXXXX") || return 1
	if ! cp "$runtime_backup" "$runtime_temporary" ||
		! chmod "$runtime_mode" "$runtime_temporary"; then
		rm -f "$runtime_temporary"
		return 1
	fi
	if ! ln -T "$runtime_temporary" "$runtime_destination"; then
		rm -f "$runtime_temporary"
		if [ -e "$runtime_destination" ] || [ -L "$runtime_destination" ]; then
			printf 'RETAIN MODIFIED: %s\n' "$runtime_destination"
		fi
		return 1
	fi
	rm -f "$runtime_temporary" || return 1
	runtime_asset_matches "$runtime_backup" "$runtime_destination" "$runtime_mode"
}

restore_runtime_claim()
{
	runtime_claim=$1
	runtime_destination=$2
	runtime_claim_identity=$(object_identity "$runtime_claim" || true)
	[ -n "$runtime_claim_identity" ] || return 1
	if [ -e "$runtime_destination" ] || [ -L "$runtime_destination" ]; then
		return 1
	fi
	mv -n -T "$runtime_claim" "$runtime_destination" || return 1
	[ ! -e "$runtime_claim" ] && [ ! -L "$runtime_claim" ] &&
		[ "$(object_identity "$runtime_destination" || true)" = "$runtime_claim_identity" ]
}

claim_runtime_asset()
{
	runtime_asset_name=$1
	runtime_destination=$2
	runtime_source=$3
	runtime_mode=$4
	runtime_claim_state=error
	runtime_claim_recovery=
	runtime_directory=$(dirname -- "$runtime_destination")
	runtime_claim=$(mktemp "$runtime_directory/.${PROJECT_NAME}.uninstall.$runtime_asset_name.XXXXXX") ||
		return 1
	runtime_claim_recovery=$runtime_claim
	if ! mv -f "$runtime_destination" "$runtime_claim"; then
		if [ ! -e "$runtime_destination" ] && [ ! -L "$runtime_destination" ] &&
			runtime_asset_matches "$runtime_source" "$runtime_claim" "$runtime_mode"; then
			return 1
		fi
		if [ -e "$runtime_destination" ] || [ -L "$runtime_destination" ]; then
			runtime_claim_recovery=$runtime_destination
			if ! runtime_asset_matches "$runtime_source" "$runtime_destination" "$runtime_mode"; then
				printf 'RETAIN MODIFIED: %s\n' "$runtime_destination"
			fi
		fi
		rm -f "$runtime_claim" >/dev/null 2>&1 || true
		return 1
	fi
	if runtime_asset_matches "$runtime_source" "$runtime_claim" "$runtime_mode"; then
		if ! rm -f "$runtime_claim"; then
			return 1
		fi
		runtime_claim_recovery=
		runtime_claim_state=removed
		return 0
	fi
	printf 'RETAIN MODIFIED: %s\n' "$runtime_destination"
	if restore_runtime_claim "$runtime_claim" "$runtime_destination"; then
		runtime_claim_state=modified
		return 0
	fi
	return 1
}

restore_runtime_assets()
{
	[ -f "$transaction_directory/runtime.snapshot-complete" ] || return 1
	runtime_restore_failed=0
	mapper_restored=1
	if [ "$mapper_dependency_restore_failed" -eq 1 ]; then
		runtime_restore_failed=1
		mapper_restored=0
		rollback_note="$rollback_note touch mapper dependency restoration failed: $TOUCH_MAPPER_DESTINATION;"
	elif [ "$mapper_claim_held" -eq 1 ]; then
		runtime_restore_failed=1
		mapper_restored=0
		rollback_note="$rollback_note touch mapper claim retained at $mapper_claim_recovery;"
	elif [ "$mapper_remove_attempted" -eq 1 ] &&
		! restore_runtime_asset "$transaction_directory/runtime/mapper" "$TOUCH_MAPPER_DESTINATION"; then
		runtime_restore_failed=1
		mapper_restored=0
		rollback_note="$rollback_note touch mapper restoration failed: $TOUCH_MAPPER_DESTINATION;"
	fi
	if [ "$autostart_remove_attempted" -eq 1 ]; then
		if [ "$mapper_restored" -eq 0 ]; then
			runtime_restore_failed=1
			rollback_note="$rollback_note touch autostart retained because touch mapper restoration failed: $TOUCH_AUTOSTART_DESTINATION;"
		elif ! restore_runtime_asset "$transaction_directory/runtime/autostart" "$TOUCH_AUTOSTART_DESTINATION"; then
		runtime_restore_failed=1
		rollback_note="$rollback_note touch autostart restoration failed: $TOUCH_AUTOSTART_DESTINATION;"
		fi
	fi
	if [ "$autostart_claim_held" -eq 1 ]; then
		runtime_restore_failed=1
		rollback_note="$rollback_note touch autostart claim retained at $autostart_claim_recovery;"
	fi
	[ "$runtime_restore_failed" -eq 0 ]
}

restore_module_paths()
{
	[ -f "$transaction_directory/modules.snapshot-complete" ] || return 1
	module_paths_restore_failed=0
	for module_name in $MODULE_NAMES; do
		current=$transaction_directory/modules/$module_name.current
		find "${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE" -type f \
			\( -name "$module_name.ko" -o -name "$module_name.ko.xz" \
			-o -name "$module_name.ko.gz" -o -name "$module_name.ko.zst" \) \
			-print > "$current" 2>/dev/null || true
		while IFS= read -r module_path; do
			[ -z "$module_path" ] || rm -f "$module_path" || module_paths_restore_failed=1
		done < "$current"
		index=0
		while IFS= read -r module_path; do
			[ -n "$module_path" ] || continue
			index=$((index + 1))
			backup=$transaction_directory/modules/$module_name.$index.backup
			if ! try_atomic_install_file "$backup" "$module_path" ||
				! cmp -s "$backup" "$module_path"; then
				module_paths_restore_failed=1
			fi
		done < "$transaction_directory/modules/$module_name.paths"
		restored_count=$(find "${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE" -type f \
			\( -name "$module_name.ko" -o -name "$module_name.ko.xz" \
			-o -name "$module_name.ko.gz" -o -name "$module_name.ko.zst" \) \
			-print 2>/dev/null | awk 'END { print NR + 0 }')
		[ "$restored_count" -eq "$index" ] || module_paths_restore_failed=1
	done
	if ! depmod -a "$KERNEL_RELEASE"; then
		dependency_index_restore_failed=1
		module_paths_restore_failed=1
	fi
	[ "$module_paths_restore_failed" -eq 0 ]
}

snapshot_dkms_state_tree()
{
	if [ -e "$dkms_state_destination" ]; then
		[ -d "$dkms_state_destination" ] ||
			die "DKMS state path is not a directory: $dkms_state_destination"
		cp -a "$dkms_state_destination" "$transaction_directory/dkms-state"
		diff -qr "$dkms_state_destination" "$transaction_directory/dkms-state" >/dev/null ||
			die 'cannot verify DKMS state-tree snapshot'
		: > "$transaction_directory/dkms-state.present"
	fi
	: > "$transaction_directory/dkms-state.snapshot-complete"
}

restore_dkms_state_tree()
{
	[ -f "$transaction_directory/dkms-state.snapshot-complete" ] || return 1
	rm -rf "$dkms_state_destination" || return 1
	if [ -f "$transaction_directory/dkms-state.present" ]; then
		mkdir -p "$(dirname -- "$dkms_state_destination")" || return 1
		cp -a "$transaction_directory/dkms-state" "$dkms_state_destination" || return 1
		diff -qr "$transaction_directory/dkms-state" "$dkms_state_destination" >/dev/null || return 1
	else
		[ ! -e "$dkms_state_destination" ] || return 1
	fi
}

restore_source()
{
	[ "$source_present" -eq 1 ] || return 0
	mkdir -p "$PROJECT_SOURCE_DIR" || return 1
	cp -a "$transaction_directory/source/." "$PROJECT_SOURCE_DIR/" || return 1
	diff -qr "$transaction_directory/source" "$PROJECT_SOURCE_DIR" >/dev/null 2>&1
}

restore_dkms()
{
	[ "$dkms_remove_attempted" -eq 1 ] || return 0
	dkms_restore_failed=0
	dependency_index_restore_failed=0
	dkms_state_restore_failed=0
	current_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null) || return 1
	if [ "$current_status" != "$dkms_status" ]; then
		if printf '%s\n' "$current_status" | dkms_status_has_version "$PROJECT_VERSION"; then
			dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all >/dev/null 2>&1 || true
			current_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null) || return 1
			printf '%s\n' "$current_status" | dkms_status_has_version "$PROJECT_VERSION" && return 1
		fi
		if ! dkms add -m "$PROJECT_NAME" -v "$PROJECT_VERSION" >/dev/null 2>&1; then
			current_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null) || return 1
			printf '%s\n' "$current_status" | dkms_status_has_version "$PROJECT_VERSION" || return 1
		fi
		expected_built="$PROJECT_NAME/$PROJECT_VERSION, $KERNEL_RELEASE, $ARCH: built"
		expected_installed="$PROJECT_NAME/$PROJECT_VERSION, $KERNEL_RELEASE, $ARCH: installed"
		if printf '%s\n' "$dkms_status" | grep -Fxq "$expected_built" ||
			printf '%s\n' "$dkms_status" | grep -Fxq "$expected_installed"; then
			dkms build -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE" >/dev/null 2>&1 || return 1
		fi
		if printf '%s\n' "$dkms_status" | grep -Fxq "$expected_installed"; then
			dkms install -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE" >/dev/null 2>&1 || return 1
		fi
	fi
	if ! restore_dkms_state_tree; then
		dkms_state_restore_failed=1
		dkms_restore_failed=1
	fi
	if ! restore_module_paths; then
		dkms_restore_failed=1
	fi
	restored_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null || true)
	[ "$restored_status" = "$dkms_status" ] || dkms_restore_failed=1
	[ "$dkms_restore_failed" -eq 0 ]
}

rollback_uninstall()
{
	transaction_status=$?
	trap - EXIT HUP INT TERM
	[ "$completed" -eq 0 ] || exit "$transaction_status"
	if ! restore_source; then
		rollback_failed=1
		rollback_note="$rollback_note source restore failed;"
	fi
	if ! restore_runtime_assets; then
		rollback_failed=1
	fi
	if ! try_atomic_install_file "$transaction_directory/armbianEnv.txt" "$ARMBIAN_ENV"; then
		rollback_failed=1
		rollback_note="$rollback_note boot configuration restore failed;"
	fi
	if [ -f "$transaction_directory/overlay.present" ]; then
		if ! try_atomic_install_file "$transaction_directory/overlay.dtbo" "$overlay_destination"; then
			rollback_failed=1
			rollback_note="$rollback_note DTBO restore failed;"
		fi
	elif ! rm -f "$overlay_destination"; then
		rollback_failed=1
		rollback_note="$rollback_note unexpected DTBO cleanup failed;"
	fi
	if ! restore_dkms; then
		rollback_failed=1
		if [ "$dkms_state_restore_failed" -eq 1 ]; then
			rollback_note="$rollback_note DKMS state-tree restore failed;"
		fi
		if [ "$dependency_index_restore_failed" -eq 1 ]; then
			rollback_note="$rollback_note dependency index refresh failed for $KERNEL_RELEASE;"
		fi
		if [ "$dkms_state_restore_failed" -eq 0 ] &&
			[ "$dependency_index_restore_failed" -eq 0 ]; then
			rollback_note="$rollback_note DKMS lifecycle restore failed;"
		fi
	fi
	if [ "$rollback_failed" -eq 0 ]; then
		rm -rf "$transaction_directory"
	else
		printf 'ERROR: uninstall failed with status %s; rollback also failed:%s recovery retained at %s\n' \
			"$transaction_status" "$rollback_note" "$transaction_directory" >&2
		exit 1
	fi
	exit "$transaction_status"
}

cp "$ARMBIAN_ENV" "$transaction_directory/armbianEnv.txt"
cmp -s "$ARMBIAN_ENV" "$transaction_directory/armbianEnv.txt" || die 'cannot verify boot configuration snapshot'
if [ -f "$overlay_destination" ]; then
	cp "$overlay_destination" "$transaction_directory/overlay.dtbo"
	cmp -s "$overlay_destination" "$transaction_directory/overlay.dtbo" || die 'cannot verify DTBO snapshot'
	: > "$transaction_directory/overlay.present"
fi
if [ "$source_present" -eq 1 ]; then
	cp -a "$PROJECT_SOURCE_DIR" "$transaction_directory/source"
	diff -qr "$PROJECT_SOURCE_DIR" "$transaction_directory/source" >/dev/null || die 'cannot verify source snapshot'
fi
snapshot_dkms_state_tree
snapshot_module_paths
snapshot_runtime_assets
: > "$transaction_directory/snapshot-complete"
trap rollback_uninstall EXIT HUP INT TERM

if [ "$dkms_registered" -eq 1 ]; then
	dkms_remove_attempted=1
	if ! dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all; then
		printf 'ERROR: DKMS removal failed; retained source: %s\n' "$PROJECT_SOURCE_DIR" >&2
		exit 1
	fi
	remaining_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION") ||
		die "cannot verify DKMS removal for $PROJECT_NAME/$PROJECT_VERSION; retained source: $PROJECT_SOURCE_DIR"
	if printf '%s\n' "$remaining_status" | dkms_status_has_version "$PROJECT_VERSION"; then
		die "DKMS removal did not clear $PROJECT_NAME/$PROJECT_VERSION; retained source: $PROJECT_SOURCE_DIR"
	fi
fi

remove_overlay_token "$ARMBIAN_ENV" "$OVERLAY_TOKEN"
rm -f "$overlay_destination"
if [ "$autostart_state" = owned ]; then
	if ! claim_runtime_asset autostart "$TOUCH_AUTOSTART_DESTINATION" \
		"$touch_autostart_source" 644; then
		autostart_claim_held=1
		autostart_claim_recovery=$runtime_claim_recovery
		rollback_note="$rollback_note touch autostart claim retained at $autostart_claim_recovery;"
		exit 1
	fi
	case $runtime_claim_state in
	removed)
		autostart_remove_attempted=1
		autostart_state=absent
		;;
	absent) autostart_state=absent ;;
	modified) autostart_state=modified ;;
	*) die "unknown touch autostart claim state: $runtime_claim_state" ;;
	esac
fi
if [ "$mapper_state" = owned ]; then
	if [ "$autostart_state" = modified ]; then
		printf 'RETAIN DEPENDENCY: %s\n' "$TOUCH_MAPPER_DESTINATION"
	else
		if ! claim_runtime_asset mapper "$TOUCH_MAPPER_DESTINATION" \
			"$touch_mapper_source" 755; then
			mapper_claim_held=1
			mapper_claim_recovery=$runtime_claim_recovery
			rollback_note="$rollback_note touch mapper claim retained at $mapper_claim_recovery;"
			exit 1
		fi
		case $runtime_claim_state in
		removed)
			mapper_remove_attempted=1
			if [ -e "$TOUCH_AUTOSTART_DESTINATION" ] || [ -L "$TOUCH_AUTOSTART_DESTINATION" ]; then
				printf 'RETAIN MODIFIED: %s\n' "$TOUCH_AUTOSTART_DESTINATION"
				if ! restore_runtime_asset "$transaction_directory/runtime/mapper" \
					"$TOUCH_MAPPER_DESTINATION"; then
					mapper_dependency_restore_failed=1
					rollback_note="$rollback_note touch mapper dependency restoration failed: $TOUCH_MAPPER_DESTINATION;"
				else
					mapper_remove_attempted=0
					printf 'RETAIN DEPENDENCY: %s\n' "$TOUCH_MAPPER_DESTINATION"
					rollback_note="$rollback_note touch mapper retained because touch autostart appeared after mapper claim: $TOUCH_MAPPER_DESTINATION;"
				fi
				exit 1
			fi
			;;
		absent|modified) ;;
		*) die "unknown touch mapper claim state: $runtime_claim_state" ;;
		esac
	fi
fi
if [ "$source_present" -eq 1 ]; then
	rm -rf "$PROJECT_SOURCE_DIR"
fi
completed=1
trap - EXIT HUP INT TERM
if ! rm -rf "$transaction_directory"; then
	printf 'ERROR: uninstall completed but recovery cleanup failed; recovery retained at %s\n' \
		"$transaction_directory" >&2
	exit 1
fi
printf 'PASS: removed %s/%s assets\n' "$PROJECT_NAME" "$PROJECT_VERSION"
