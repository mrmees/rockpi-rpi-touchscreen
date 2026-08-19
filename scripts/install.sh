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

source_created=0
overlay_created=0
overlay_replaced=0
previous_overlay_file=
dkms_registration_created=0
backup_created=0
completed=0
stage_directory=
backup_file=${BACKUP_PATH:-$ARMBIAN_ENV.$PROJECT_NAME.$(date -u +%Y%m%dT%H%M%SZ).bak}

rollback()
{
	transaction_status=$?
	trap - EXIT HUP INT TERM
	rollback_failed=0
	rollback_note=
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
			else
				rollback_failed=1
				rollback_note="$rollback_note prior overlay retained at $previous_overlay_file;"
			fi
		fi
		if [ "$dkms_registration_created" -eq 1 ] &&
			! dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all >/dev/null 2>&1; then
			rollback_failed=1
			rollback_note="$rollback_note DKMS registration removal failed;"
		fi
		if [ "$source_created" -eq 1 ] && ! rm -rf "$PROJECT_SOURCE_DIR"; then
			rollback_failed=1
			rollback_note="$rollback_note new source removal failed: $PROJECT_SOURCE_DIR;"
		fi
		if [ -n "$stage_directory" ] && [ -d "$stage_directory" ] &&
			! rm -rf "$stage_directory"; then
			rollback_failed=1
			rollback_note="$rollback_note staged source cleanup failed: $stage_directory;"
		fi
	fi
	if [ "$rollback_failed" -ne 0 ]; then
		printf 'ERROR: transaction failed with status %s; rollback also failed:%s\n' \
			"$transaction_status" "$rollback_note" >&2
		exit 1
	fi
	exit "$transaction_status"
}
trap rollback EXIT HUP INT TERM

source_parent=$(dirname -- "$PROJECT_SOURCE_DIR")
mkdir -p "$source_parent"
stage_directory=$(mktemp -d "$source_parent/.${PROJECT_NAME}.stage.XXXXXX")
mkdir -p "$stage_directory/src" "$stage_directory/scripts" "$stage_directory/LICENSES"
chmod 0755 "$stage_directory" "$stage_directory/src" "$stage_directory/scripts" "$stage_directory/LICENSES"
install -m 0644 "$repo_root/Makefile" "$repo_root/dkms.conf" "$repo_root/LICENSE" "$stage_directory/"
install -m 0644 "$repo_root/LICENSES/GPL-2.0-only.txt" "$stage_directory/LICENSES/"
install -m 0644 "$repo_root/LICENSES/UPSTREAM.md" "$stage_directory/LICENSES/"
install -m 0644 "$repo_root/src/ft5426_protocol.h" "$repo_root/src/raspits_ft5426.c" "$stage_directory/src/"
install -m 0755 "$repo_root/scripts/dkms-make.sh" "$stage_directory/scripts/"
source_digest()
{
	(
		cd "$1"
		sha256sum Makefile dkms.conf src/ft5426_protocol.h src/raspits_ft5426.c \
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

if dkms add -m "$PROJECT_NAME" -v "$PROJECT_VERSION"; then
	dkms_registration_created=1
else
	dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION" | grep -Fq "$PROJECT_NAME/$PROJECT_VERSION" ||
		die 'DKMS package could not be added or found'
fi
dkms build -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE"
dkms install -m "$PROJECT_NAME" -v "$PROJECT_VERSION" -k "$KERNEL_RELEASE"

dkms_state_root=${DKMS_STATE_DIR:-/var/lib/dkms}
built_module=$(find "$dkms_state_root/$PROJECT_NAME/$PROJECT_VERSION/$KERNEL_RELEASE" \
	-type f -name raspits_ft5426.ko -print 2>/dev/null | head -n 1)
[ -n "$built_module" ] || die 'cannot locate the DKMS-built module for checksum verification'
installed_module=$(modinfo -k "$KERNEL_RELEASE" -n raspits_ft5426)
[ -f "$installed_module" ] || die "installed module not found: $installed_module"
cmp "$built_module" "$installed_module" || die 'installed module checksum does not match the DKMS build'

if [ ! -e "$overlay_destination" ]; then
	atomic_install_file "$overlay_output" "$overlay_destination"
	overlay_created=1
elif ! cmp -s "$overlay_output" "$overlay_destination"; then
	previous_overlay_file=$(mktemp "$BOOT_DIRECTORY/.${PROJECT_NAME}.overlay-backup.XXXXXX")
	cp "$overlay_destination" "$previous_overlay_file"
	atomic_install_file "$overlay_output" "$overlay_destination"
	overlay_replaced=1
fi
cmp "$overlay_output" "$overlay_destination" || die 'installed DTBO checksum verification failed'

if [ ! -e "$backup_file" ]; then
	cp "$ARMBIAN_ENV" "$backup_file"
	sha256sum "$backup_file" > "$backup_file.sha256"
	backup_created=1
fi
add_overlay_token "$ARMBIAN_ENV" "$OVERLAY_TOKEN"
completed=1
if [ "$overlay_replaced" -eq 1 ]; then
	rm -f "$previous_overlay_file"
	previous_overlay_file=
	overlay_replaced=0
fi
trap - EXIT HUP INT TERM

old_version=0.1.0
old_source=${DKMS_TREE:-/usr/src}/${PROJECT_NAME}-${old_version}
if dkms status -m "$PROJECT_NAME" -v "$old_version" 2>/dev/null | grep -Fq "$PROJECT_NAME/$old_version"; then
	if dkms remove -m "$PROJECT_NAME" -v "$old_version" --all; then
		rm -rf "$old_source"
	else
		printf 'WARNING: installed %s/%s; retained old DKMS %s and source %s because removal failed\n' \
			"$PROJECT_NAME" "$PROJECT_VERSION" "$old_version" "$old_source" >&2
	fi
elif [ -f "$old_source/dkms.conf" ] &&
	grep -Fq 'PACKAGE_NAME="rockpi-rpi-touchscreen"' "$old_source/dkms.conf" &&
	grep -Fq 'PACKAGE_VERSION="0.1.0"' "$old_source/dkms.conf"; then
	rm -rf "$old_source"
fi

printf 'PASS: installed %s/%s and verified module, source, and DTBO checksums\n' "$PROJECT_NAME" "$PROJECT_VERSION"
printf 'NEXT: power off; follow docs/wiring.md; boot with HDMI; run the README first-boot checks.\n'
printf 'ROLLBACK: sudo sh scripts/uninstall.sh (or use docs/recovery.md offline).\n'
