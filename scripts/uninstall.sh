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

require_command awk chmod cp dkms grep mktemp mv rm
overlay_destination=$OVERLAY_DIRECTORY/$OVERLAY_NAME.dtbo

if [ "$dry_run" -eq 1 ]; then
	temporary_config=$(mktemp "${ARMBIAN_ENV}.XXXXXX") || die 'cannot create dry-run temporary configuration'
	trap 'rm -f "$temporary_config"' HUP INT TERM EXIT
	cp "$ARMBIAN_ENV" "$temporary_config"
	remove_overlay_token "$temporary_config" "$OVERLAY_TOKEN"
	printf 'REMOVE: %s\n' "$overlay_destination"
	printf 'REMOVE: %s\n' "$PROJECT_SOURCE_DIR"
	printf 'DKMS REMOVE: %s/%s\n' "$PROJECT_NAME" "$PROJECT_VERSION"
	grep -m 1 '^[[:space:]]*user_overlays[[:space:]]*=' "$temporary_config" || printf 'user_overlays=\n'
	rm -f "$temporary_config"
	trap - HUP INT TERM EXIT
	exit 0
fi

remove_overlay_token "$ARMBIAN_ENV" "$OVERLAY_TOKEN"
rm -f "$overlay_destination"
dkms_status=$(dkms status -m "$PROJECT_NAME" -v "$PROJECT_VERSION") ||
	die "cannot determine DKMS registration state for $PROJECT_NAME/$PROJECT_VERSION"
if printf '%s\n' "$dkms_status" | grep -Fq "$PROJECT_NAME/$PROJECT_VERSION"; then
	if ! dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all; then
		printf 'ERROR: DKMS removal failed; retained source: %s\n' "$PROJECT_SOURCE_DIR" >&2
		exit 1
	fi
fi
rm -rf "$PROJECT_SOURCE_DIR"
printf 'PASS: removed %s/%s assets\n' "$PROJECT_NAME" "$PROJECT_VERSION"
