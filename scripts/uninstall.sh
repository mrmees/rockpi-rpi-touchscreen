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

require_command awk chmod cmp cp diff dkms find grep mkdir mktemp mv rm
overlay_destination=$OVERLAY_DIRECTORY/$OVERLAY_NAME.dtbo

if [ "$dry_run" -eq 1 ]; then
	temporary_config=$(mktemp "${ARMBIAN_ENV}.XXXXXX") || die 'cannot create dry-run temporary configuration'
	trap 'rm -f "$temporary_config"' HUP INT TERM EXIT
	cp "$ARMBIAN_ENV" "$temporary_config"
	remove_overlay_token "$temporary_config" "$OVERLAY_TOKEN"
	printf 'REMOVE: %s\n' "$overlay_destination"
	printf 'REMOVE: %s\n' "$PROJECT_SOURCE_DIR"
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
dkms_removed=0
rollback_failed=0
rollback_note=
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

restore_module_paths()
{
	[ -f "$transaction_directory/modules.snapshot-complete" ] || return 1
	for module_name in $MODULE_NAMES; do
		current=$transaction_directory/modules/$module_name.current
		find "${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE" -type f \
			\( -name "$module_name.ko" -o -name "$module_name.ko.xz" \
			-o -name "$module_name.ko.gz" -o -name "$module_name.ko.zst" \) \
			-print > "$current" 2>/dev/null || true
		while IFS= read -r module_path; do
			[ -z "$module_path" ] || rm -f "$module_path" || return 1
		done < "$current"
		index=0
		while IFS= read -r module_path; do
			[ -n "$module_path" ] || continue
			index=$((index + 1))
			backup=$transaction_directory/modules/$module_name.$index.backup
			try_atomic_install_file "$backup" "$module_path" || return 1
			cmp -s "$backup" "$module_path" || return 1
		done < "$transaction_directory/modules/$module_name.paths"
	done
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
	[ "$dkms_removed" -eq 1 ] || return 0
	if ! dkms add -m "$PROJECT_NAME" -v "$PROJECT_VERSION" >/dev/null 2>&1; then
		current_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null || true)
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
	restore_module_paths || return 1
	restored_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" 2>/dev/null || true)
	[ "$restored_status" = "$dkms_status" ]
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
		rollback_note="$rollback_note DKMS lifecycle restore failed;"
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
snapshot_module_paths
: > "$transaction_directory/snapshot-complete"
trap rollback_uninstall EXIT HUP INT TERM

if [ "$dkms_registered" -eq 1 ]; then
	if ! dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all; then
		printf 'ERROR: DKMS removal failed; retained source: %s\n' "$PROJECT_SOURCE_DIR" >&2
		exit 1
	fi
	dkms_removed=1
	remaining_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION") ||
		die "cannot verify DKMS removal for $PROJECT_NAME/$PROJECT_VERSION; retained source: $PROJECT_SOURCE_DIR"
	if printf '%s\n' "$remaining_status" | dkms_status_has_version "$PROJECT_VERSION"; then
		die "DKMS removal did not clear $PROJECT_NAME/$PROJECT_VERSION; retained source: $PROJECT_SOURCE_DIR"
	fi
fi

remove_overlay_token "$ARMBIAN_ENV" "$OVERLAY_TOKEN"
rm -f "$overlay_destination"
if [ "$source_present" -eq 1 ]; then
	rm -rf "$PROJECT_SOURCE_DIR"
fi
completed=1
trap - EXIT HUP INT TERM
rm -rf "$transaction_directory"
printf 'PASS: removed %s/%s assets\n' "$PROJECT_NAME" "$PROJECT_VERSION"
