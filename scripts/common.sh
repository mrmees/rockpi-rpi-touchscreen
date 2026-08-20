#!/bin/sh

PROJECT_NAME=rockpi-rpi-touchscreen
PROJECT_VERSION=0.2.2
PROJECT_SOURCE_DIR=${DKMS_TREE:-/usr/src}/${PROJECT_NAME}-${PROJECT_VERSION}
MODULE_NAMES='raspits_ft5426 panel_rockpi_rpi_touchscreen'
OVERLAY_NAME=rockpi-4b-plus-rpi-touchscreen
OVERLAY_TOKEN=$OVERLAY_NAME
BOOT_DIRECTORY=${BOOT_DIR:-/boot}
ARMBIAN_ENV=${ARMBIAN_ENV:-$BOOT_DIRECTORY/armbianEnv.txt}
OVERLAY_DIRECTORY=${OVERLAY_DIR:-$BOOT_DIRECTORY/overlay-user}
DTB_DIRECTORY=${DTB_ROOT:-$BOOT_DIRECTORY/dtb}
KERNEL_RELEASE=${KERNEL_RELEASE:-$(uname -r)}
ARCH=${ARCH:-$(uname -m)}
KERNEL_BUILD=${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE/build

die()
{
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_command()
{
	for required_command do
		command -v "$required_command" >/dev/null 2>&1 ||
			die "required command not found: $required_command"
	done
}

require_root()
{
	[ "$(id -u)" -eq 0 ] || die 'this command must be run as root'
}

dkms_status_has_version()
{
	version=$1
	prefix=$PROJECT_NAME/$version
	awk -v prefix="$prefix" '
		index($0, prefix) == 1 {
			separator = substr($0, length(prefix) + 1, 1)
			if (separator == "," || separator == ":") found = 1
		}
		END { exit found ? 0 : 1 }
	'
}

active_dtb()
{
	[ -r "$ARMBIAN_ENV" ] || die "cannot read Armbian environment: $ARMBIAN_ENV"
	fdtfile=$(sed -n 's/^[[:space:]]*fdtfile[[:space:]]*=[[:space:]]*\([^[:space:]#][^[:space:]#]*\).*$/\1/p' "$ARMBIAN_ENV" | tail -n 1)
	[ -n "$fdtfile" ] || die "fdtfile is absent or empty in: $ARMBIAN_ENV"
	case $fdtfile in
	/*) printf '%s\n' "$fdtfile" ;;
	*) printf '%s/%s\n' "$DTB_DIRECTORY" "$fdtfile" ;;
	esac
}

atomic_install_file()
{
	try_atomic_install_file "$@" || die "cannot atomically install $1 as $2"
}

try_atomic_install_file()
{
	source_file=$1
	destination_file=$2
	destination_dir=$(dirname -- "$destination_file")
	mkdir -p "$destination_dir" || return 1
	temporary_file=$(mktemp "$destination_dir/.${PROJECT_NAME}.XXXXXX") || return 1
	if ! cp "$source_file" "$temporary_file"; then
		rm -f "$temporary_file"
		return 1
	fi
	if ! chmod 0644 "$temporary_file"; then
		rm -f "$temporary_file"
		return 1
	fi
	if ! mv -f "$temporary_file" "$destination_file"; then
		rm -f "$temporary_file"
		return 1
	fi
}

atomic_replace_temp()
{
	temporary_file=$1
	destination_file=$2
	chmod 0644 "$temporary_file" || {
		rm -f "$temporary_file"
		die "cannot set mode on temporary file for $destination_file"
	}
	mv -f "$temporary_file" "$destination_file" || {
		rm -f "$temporary_file"
		die "cannot atomically replace $destination_file"
	}
}

add_overlay_token()
{
	config_file=$1
	token=$2
	[ -r "$config_file" ] || die "cannot read boot configuration: $config_file"
	temporary_file=$(mktemp "${config_file}.XXXXXX") || die "cannot create boot configuration temporary file"
	awk -v token="$token" '
		BEGIN { changed = 0 }
		/^[[:space:]]*user_overlays[[:space:]]*=/ && !changed {
			line = $0
			prefix = line
			sub(/=.*/, "", prefix)
			value = line
			sub(/^[^=]*=/, "", value)
			n = split(value, tokens, /[[:space:]]+/)
			for (i = 1; i <= n; i++)
				if (tokens[i] == token) {
					print line
					changed = 1
					next
				}
			if (value == "")
				print prefix "=" token
			else
				print line " " token
			changed = 1
			next
		}
		{ print }
		END { if (!changed) print "user_overlays=" token }
	' "$config_file" > "$temporary_file" || {
		rm -f "$temporary_file"
		die "cannot update boot configuration"
	}
	atomic_replace_temp "$temporary_file" "$config_file"
}

remove_overlay_token()
{
	config_file=$1
	token=$2
	[ -r "$config_file" ] || die "cannot read boot configuration: $config_file"
	temporary_file=$(mktemp "${config_file}.XXXXXX") || die "cannot create boot configuration temporary file"
	awk -v token="$token" '
		/^[[:space:]]*user_overlays[[:space:]]*=/ {
			line = $0
			prefix = line
			sub(/=.*/, "", prefix)
			value = line
			sub(/^[^=]*=/, "", value)
			n = split(value, tokens, /[[:space:]]+/)
			out = ""
			for (i = 1; i <= n; i++)
				if (tokens[i] != "" && tokens[i] != token)
					out = out (out == "" ? "" : " ") tokens[i]
			print prefix "=" out
			next
		}
		{ print }
	' "$config_file" > "$temporary_file" || {
		rm -f "$temporary_file"
		die "cannot update boot configuration"
	}
	atomic_replace_temp "$temporary_file" "$config_file"
}
