#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

require_root
require_command awk chmod cp date dirname dkms grep mkdir mktemp mv rm rmdir sed sha256sum tail

validator=${VALIDATE_SCRIPT:-$script_dir/validate.sh}
[ -x "$validator" ] || [ -f "$validator" ] || die "validation script not found: $validator"
sh "$validator" --offline

repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
overlay_source=$repo_root/overlays/$OVERLAY_NAME.dts
overlay_output=${BUILD_DIR:-$repo_root/build}/$OVERLAY_NAME.dtbo
overlay_destination=$OVERLAY_DIRECTORY/$OVERLAY_NAME.dtbo
[ -f "$overlay_source" ] || die "overlay source not found: $overlay_source"
[ -f "$overlay_output" ] || die "validated overlay not found: $overlay_output"
[ -f "$ARMBIAN_ENV" ] || die "boot configuration not found: $ARMBIAN_ENV"

source_created=0
source_swapped=0
stage_directory=
previous_source_directory=
overlay_created=0
dkms_registration_created=0
backup_created=0
completed=0
backup_file=${BACKUP_PATH:-$ARMBIAN_ENV.$PROJECT_NAME.$(date -u +%Y%m%dT%H%M%SZ).bak}

rollback()
{
	transaction_status=$?
	trap - EXIT HUP INT TERM
	rollback_failed=0
	rollback_note=
	manual_source_backup=
	if [ "$completed" -ne 1 ]; then
		if [ "$backup_created" -eq 1 ] && [ -f "$backup_file" ]; then
			if ! atomic_install_file "$backup_file" "$ARMBIAN_ENV"; then
				rollback_failed=1
				rollback_note="$rollback_note boot configuration backup retained at $backup_file;"
			fi
		fi
		if [ "$overlay_created" -eq 1 ]; then
			if ! rm -f "$overlay_destination"; then
				rollback_failed=1
				rollback_note="$rollback_note overlay removal failed: $overlay_destination;"
			fi
		fi
		if [ "$dkms_registration_created" -eq 1 ]; then
			if ! dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all >/dev/null 2>&1; then
				rollback_failed=1
				rollback_note="$rollback_note DKMS registration removal failed;"
			fi
		fi
		if [ "$source_created" -eq 1 ]; then
			if ! rm -rf "$PROJECT_SOURCE_DIR"; then
				rollback_failed=1
				rollback_note="$rollback_note new source removal failed: $PROJECT_SOURCE_DIR;"
			fi
		fi
		if [ "$source_swapped" -eq 1 ] && [ -n "$previous_source_directory" ] && [ -d "$previous_source_directory" ]; then
			if ! rm -rf "$PROJECT_SOURCE_DIR"; then
				rollback_failed=1
				manual_source_backup=$previous_source_directory
				rollback_note="$rollback_note replacement source removal failed;"
			elif ! mv "$previous_source_directory" "$PROJECT_SOURCE_DIR"; then
				rollback_failed=1
				manual_source_backup=$previous_source_directory
				rollback_note="$rollback_note prior source restoration failed;"
			fi
		fi
		if [ -n "$stage_directory" ] && [ -d "$stage_directory" ]; then
			if ! rm -rf "$stage_directory"; then
				rollback_failed=1
				rollback_note="$rollback_note staged source cleanup failed: $stage_directory;"
			fi
		fi
	fi
	if [ "$rollback_failed" -ne 0 ]; then
		printf 'ERROR: transaction failed with status %s; rollback also failed: %s\n' \
			"$transaction_status" "$rollback_note" >&2
		if [ -n "$manual_source_backup" ]; then
			printf 'ERROR: manual recovery source backup: %s\n' "$manual_source_backup" >&2
		fi
		exit 1
	fi
	exit "$transaction_status"
}
trap rollback EXIT HUP INT TERM

source_parent=$(dirname -- "$PROJECT_SOURCE_DIR")
mkdir -p "$source_parent"
if [ -e "$PROJECT_SOURCE_DIR" ]; then
	[ -d "$PROJECT_SOURCE_DIR" ] || die "DKMS source path is not a directory: $PROJECT_SOURCE_DIR"
	[ -f "$PROJECT_SOURCE_DIR/dkms.conf" ] || die "DKMS source path is not owned by this project: $PROJECT_SOURCE_DIR"
fi
stage_directory=$(mktemp -d "$source_parent/.${PROJECT_NAME}.stage.XXXXXX")
cp -a "$repo_root/." "$stage_directory/"
[ -f "$stage_directory/dkms.conf" ] || die "staged DKMS source is missing dkms.conf"
[ -x "$stage_directory/scripts/dkms-make.sh" ] || die "staged DKMS source is missing compiler helper"

if [ ! -e "$PROJECT_SOURCE_DIR" ]; then
	mv "$stage_directory" "$PROJECT_SOURCE_DIR"
	stage_directory=
	source_created=1
else
	previous_source_directory=$(mktemp -d "$source_parent/.${PROJECT_NAME}.previous.XXXXXX")
	rmdir "$previous_source_directory"
	mv "$PROJECT_SOURCE_DIR" "$previous_source_directory"
	source_swapped=1
	mv "$stage_directory" "$PROJECT_SOURCE_DIR"
	stage_directory=
fi

if dkms add -m "$PROJECT_NAME" -v "$PROJECT_VERSION"; then
	dkms_registration_created=1
else
	dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" | grep -Fq "$PROJECT_NAME/$PROJECT_VERSION" ||
		die 'DKMS package could not be added or found'
fi
dkms build -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE"
dkms install -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE"

if [ ! -e "$overlay_destination" ]; then
	atomic_install_file "$overlay_output" "$overlay_destination"
	overlay_created=1
fi

if [ ! -e "$backup_file" ]; then
	cp "$ARMBIAN_ENV" "$backup_file"
	sha256sum "$backup_file" | awk -v config="$ARMBIAN_ENV" '{ print $1 "  " config }' > "$backup_file.sha256"
	backup_created=1
fi
add_overlay_token "$ARMBIAN_ENV" "$OVERLAY_TOKEN"
completed=1
if [ "$source_swapped" -eq 1 ]; then
	rm -rf "$previous_source_directory"
	previous_source_directory=
	source_swapped=0
fi
trap - EXIT HUP INT TERM

printf 'PASS: installed %s DKMS package and %s\n' "$PROJECT_NAME" "$OVERLAY_TOKEN"
