#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

dry_run=0
case ${1:-} in
'') ;;
--dry-run) dry_run=1 ;;
*) die "usage: $0 [--dry-run]" ;;
esac

require_root
require_command cp dkms grep install mktemp rm
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
dkms remove -m "$PROJECT_NAME" -v "$PROJECT_VERSION" --all || true
rm -rf "$PROJECT_SOURCE_DIR"
printf 'PASS: removed %s assets\n' "$PROJECT_NAME"
