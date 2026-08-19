#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

require_root
require_command awk chmod cp date dirname dkms grep ln mkdir mktemp mv rm sed sha256sum tail

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
			atomic_install_file "$backup_file" "$ARMBIAN_ENV" || true
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

compiler_config=$KERNEL_BUILD/include/generated/autoconf.h
if [ -r "$compiler_config" ]; then
	kernel_compiler_banner=$(awk -F '"' '/^[[:space:]]*#define[[:space:]]+CONFIG_CC_VERSION_TEXT[[:space:]]+/ { print $2; exit }' "$compiler_config")
	[ -n "$kernel_compiler_banner" ] || die "kernel compiler banner is missing: $compiler_config"
	kernel_compiler_name=$(printf '%s\n' "$kernel_compiler_banner" | awk '{ print $1 }')
	kernel_compiler_major=$(printf '%s\n' "$kernel_compiler_banner" | awk '
		{
			for (i = NF; i > 0; i--)
				if ($i ~ /^[0-9]+\.[0-9]+/) {
					split($i, version, ".")
					print version[1]
					exit
				}
		}')
	compiler_candidate=${MODULE_CC:-$kernel_compiler_name}
	command -v "$compiler_candidate" >/dev/null 2>&1 ||
		die "kernel compiler is not available: $compiler_candidate"
	compiler_candidate=$(command -v "$compiler_candidate")
	compiler_banner=$("$compiler_candidate" --version 2>/dev/null | sed -n '1p')
	if [ "$compiler_banner" != "$kernel_compiler_banner" ] && [ -z "${MODULE_CC:-}" ] &&
		[ -n "$kernel_compiler_major" ] && command -v "$kernel_compiler_name-$kernel_compiler_major" >/dev/null 2>&1; then
		compiler_candidate=$(command -v "$kernel_compiler_name-$kernel_compiler_major")
	fi
	compiler_directory=$PROJECT_SOURCE_DIR/.module-compiler
	mkdir -p "$compiler_directory"
	ln -sf "$compiler_candidate" "$compiler_directory/$kernel_compiler_name"
	compiler_banner=$("$compiler_directory/$kernel_compiler_name" --version 2>/dev/null | sed -n '1p')
	[ "$compiler_banner" = "$kernel_compiler_banner" ] ||
		die "no compiler matches the kernel banner: $kernel_compiler_banner (set MODULE_CC to a matching compiler)"
	PATH=$compiler_directory:$PATH
	export PATH
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
