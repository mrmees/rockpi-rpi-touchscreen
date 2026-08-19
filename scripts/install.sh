#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

require_root
require_command awk cp date dirname dkms grep install mkdir mktemp mv rm sed sha256sum tail

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
overlay_created=0
dkms_registration_created=0
backup_created=0
completed=0
backup_file=${BACKUP_PATH:-$ARMBIAN_ENV.$PROJECT_NAME.$(date -u +%Y%m%dT%H%M%SZ).bak}

rollback()
{
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$completed" -ne 1 ]; then
		if [ "$backup_created" -eq 1 ] && [ -f "$backup_file" ]; then
			cp "$backup_file" "$ARMBIAN_ENV" || true
		fi
		if [ "$overlay_created" -eq 1 ]; then
			rm -f "$overlay_destination" || true
		fi
		if [ "$dkms_registration_created" -eq 1 ]; then
			dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all >/dev/null 2>&1 || true
		fi
		if [ "$source_created" -eq 1 ]; then
			rm -rf "$PROJECT_SOURCE_DIR" || true
		fi
	fi
	exit "$status"
}
trap rollback EXIT HUP INT TERM

if [ ! -e "$PROJECT_SOURCE_DIR" ]; then
	mkdir -p "${DKMS_TREE:-/usr/src}"
	stage_directory=$(mktemp -d "${DKMS_TREE:-/usr/src}/.${PROJECT_NAME}.XXXXXX")
	trap 'rm -rf "$stage_directory"; rollback' HUP INT TERM EXIT
	cp -a "$repo_root/." "$stage_directory/"
	mv "$stage_directory" "$PROJECT_SOURCE_DIR"
	source_created=1
	trap rollback EXIT HUP INT TERM
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
trap - EXIT HUP INT TERM

printf 'PASS: installed %s DKMS package and %s\n' "$PROJECT_NAME" "$OVERLAY_TOKEN"
