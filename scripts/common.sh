#!/bin/sh

PROJECT_NAME=rockpi-rpi-touchscreen
PROJECT_VERSION=0.2.5
SUPPORTED_KERNEL_RELEASE=6.18.43-current-rockchip64
PROJECT_SOURCE_DIR=${DKMS_TREE:-/usr/src}/${PROJECT_NAME}-${PROJECT_VERSION}
MODULE_NAMES='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426'
OLD_MODULE_NAMES=$MODULE_NAMES
OVERLAY_NAME=rockpi-4b-plus-rpi-touchscreen
OVERLAY_TOKEN=$OVERLAY_NAME
BOOT_DIRECTORY=${BOOT_DIR:-/boot}
ARMBIAN_ENV=${ARMBIAN_ENV:-$BOOT_DIRECTORY/armbianEnv.txt}
OVERLAY_DIRECTORY=${OVERLAY_DIR:-$BOOT_DIRECTORY/overlay-user}
DTB_DIRECTORY=${DTB_ROOT:-$BOOT_DIRECTORY/dtb}
KERNEL_RELEASE=${KERNEL_RELEASE:-$(uname -r)}
ARCH=${ARCH:-$(uname -m)}
KERNEL_BUILD=${MODULES_DIR:-/lib/modules}/$KERNEL_RELEASE/build
LIBEXEC_DIRECTORY=${LIBEXEC_DIR:-/usr/libexec}
XDG_AUTOSTART_DIRECTORY=${XDG_AUTOSTART_DIR:-/etc/xdg/autostart}
TOUCH_MAPPER_DESTINATION=$LIBEXEC_DIRECTORY/rockpi-rpi-touchscreen-map-touch
TOUCH_AUTOSTART_DESTINATION=$XDG_AUTOSTART_DIRECTORY/rockpi-rpi-touchscreen-touch-map.desktop
PROTECTED_XORG_CONFIGURATION=${PROTECTED_XORG_PATH:-/etc/X11/xorg.conf.d/20-dfrobot-display.conf}
protected_xorg_attestation_started=0
protected_xorg_baseline_identity=
protected_xorg_baseline_checksum=
protected_xorg_error=

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

require_supported_kernel_release()
{
	[ "$KERNEL_RELEASE" = "$SUPPORTED_KERNEL_RELEASE" ] ||
		die "unsupported kernel release: $KERNEL_RELEASE (expected $SUPPORTED_KERNEL_RELEASE)"
}

capture_protected_xorg_attestation()
{
	protected_xorg_attestation_started=0
	protected_xorg_baseline_identity=
	protected_xorg_baseline_checksum=
	protected_xorg_error=
	if [ ! -f "$PROTECTED_XORG_CONFIGURATION" ] ||
		[ -L "$PROTECTED_XORG_CONFIGURATION" ] ||
		[ ! -r "$PROTECTED_XORG_CONFIGURATION" ]; then
		protected_xorg_error="protected Xorg path must be a readable regular file: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	if ! protected_identity_before=$(stat -c '%d:%i:%f:%a:%u:%g' -- \
		"$PROTECTED_XORG_CONFIGURATION" 2>/dev/null); then
		protected_xorg_error="cannot identify protected Xorg file: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	if ! protected_checksum_record=$(sha256sum -- "$PROTECTED_XORG_CONFIGURATION" 2>/dev/null); then
		protected_xorg_error="cannot hash protected Xorg file: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	protected_checksum=${protected_checksum_record%% *}
	if ! protected_identity_after=$(stat -c '%d:%i:%f:%a:%u:%g' -- \
		"$PROTECTED_XORG_CONFIGURATION" 2>/dev/null) ||
		[ "$protected_identity_before" != "$protected_identity_after" ] ||
		[ ! -f "$PROTECTED_XORG_CONFIGURATION" ] ||
		[ -L "$PROTECTED_XORG_CONFIGURATION" ] ||
		[ ! -r "$PROTECTED_XORG_CONFIGURATION" ] ||
		[ -z "$protected_checksum" ]; then
		protected_xorg_error="protected Xorg path changed while capturing its baseline: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	protected_xorg_baseline_identity=$protected_identity_after
	protected_xorg_baseline_checksum=$protected_checksum
	protected_xorg_attestation_started=1
}

attest_protected_xorg_unchanged()
{
	protected_xorg_error=
	if [ "$protected_xorg_attestation_started" -ne 1 ]; then
		protected_xorg_error="protected Xorg baseline is unavailable: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	if [ ! -f "$PROTECTED_XORG_CONFIGURATION" ] ||
		[ -L "$PROTECTED_XORG_CONFIGURATION" ] ||
		[ ! -r "$PROTECTED_XORG_CONFIGURATION" ]; then
		protected_xorg_error="protected Xorg path is no longer a readable regular file: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	if ! protected_identity_before=$(stat -c '%d:%i:%f:%a:%u:%g' -- \
		"$PROTECTED_XORG_CONFIGURATION" 2>/dev/null); then
		protected_xorg_error="cannot identify protected Xorg file after transaction handling: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	if ! protected_checksum_record=$(sha256sum -- "$PROTECTED_XORG_CONFIGURATION" 2>/dev/null); then
		protected_xorg_error="cannot hash protected Xorg file after transaction handling: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	protected_checksum=${protected_checksum_record%% *}
	if ! protected_identity_after=$(stat -c '%d:%i:%f:%a:%u:%g' -- \
		"$PROTECTED_XORG_CONFIGURATION" 2>/dev/null) ||
		[ "$protected_identity_before" != "$protected_identity_after" ]; then
		protected_xorg_error="protected Xorg path changed during final attestation: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	if [ "$protected_identity_after" != "$protected_xorg_baseline_identity" ]; then
		protected_xorg_error="protected Xorg object, type, mode, or ownership changed during transaction: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	if [ "$protected_checksum" != "$protected_xorg_baseline_checksum" ]; then
		protected_xorg_error="protected Xorg content changed during transaction: $PROTECTED_XORG_CONFIGURATION"
		return 1
	fi
	return 0
}

source_release_manifest()
{
	case $1 in
	0.2.4)
		# Exact source release at 7f4b23bfb09247f31f017866308e73d2b321f94a,
		# the committed tree immediately before 0.2.5 packaging.
		cat <<'EOF'
d|755||LICENSES
d|755||scripts
d|755||src
f|644|edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6|LICENSE
f|644|edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6|LICENSES/GPL-2.0-only.txt
f|644|4aa0e8346d39b950e458d0297d0b945c8c4a1ba5cf446030e872b2e34594bb5a|LICENSES/UPSTREAM.md
f|644|109f548f08c67f11415ac9d5e4a9217c95b1138e9153c41b6400653ba1ef9d55|Makefile
f|644|b5d2b84ab77ac23ab242160c1f00d3e2a752858041c694d017d71bdfefe6c0be|dkms.conf
f|755|6d936c60de7bc4044592981f5d81e01d2c3ed3d93d6bc6b72282bde5e4fd8abf|scripts/dkms-make.sh
f|644|c804e9c522f2c4a2fe0022233c08dffbb2a9a0e29c950e9673bb299ff9ee8f7d|src/display_compat.h
f|644|61c22988bd66fd6b383246f6eace27f082a07a5f2eb8a2f77dd40b1a9ff48db1|src/display_compat_core.c
f|644|b45f838a08c0442b739dd0494e058f10cd9a9f81d7962658cffd1a9345e944c3|src/display_compat_core.h
f|644|36c04fece0717b5ddc5e5a5d942a94b04e612a4dee4c825c498f9d8db4b8270d|src/display_compat_main.c
f|644|14f5b7bbed7f0be412d7a4a1c9c7f459b66266fe60dcfdf37ee2025598969dd1|src/ft5426_protocol.h
f|644|cfe5235869a8a9df094456e87cd7c19fc538335c832698cfb9b368b0eb7e54d2|src/panel_rockpi_rpi_touchscreen.c
f|644|711bbef47e24f82119d8650def28da25ed28e35079cd658f1f0af5c16d892bd4|src/raspits_ft5426.c
EOF
		;;
	0.2.5)
		cat <<'EOF'
d|755||LICENSES
d|755||assets
d|755||scripts
d|755||src
f|644|edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6|LICENSE
f|644|edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6|LICENSES/GPL-2.0-only.txt
f|644|4aa0e8346d39b950e458d0297d0b945c8c4a1ba5cf446030e872b2e34594bb5a|LICENSES/UPSTREAM.md
f|644|109f548f08c67f11415ac9d5e4a9217c95b1138e9153c41b6400653ba1ef9d55|Makefile
f|644|19b30895e66f09757df8975a6975b6d02c630a508f5e2cbd8531c7cce5a65dd1|assets/rockpi-rpi-touchscreen-touch-map.desktop
f|644|3645807791a32a5cbd441b04631f4b961f45767eb8712a1007d022d6d869b2b0|dkms.conf
f|755|b36d8eb9f8f2c6406125a1713b51ec0291cbc6cb3ee186835f785e1cd7819fc8|scripts/dkms-make.sh
f|755|b2f332b54ad003da2e1f783fffb3a8edcb8640df75a77b3c16e54b8ccbdfa904|scripts/map-touchscreen.sh
f|644|c804e9c522f2c4a2fe0022233c08dffbb2a9a0e29c950e9673bb299ff9ee8f7d|src/display_compat.h
f|644|61c22988bd66fd6b383246f6eace27f082a07a5f2eb8a2f77dd40b1a9ff48db1|src/display_compat_core.c
f|644|b45f838a08c0442b739dd0494e058f10cd9a9f81d7962658cffd1a9345e944c3|src/display_compat_core.h
f|644|36c04fece0717b5ddc5e5a5d942a94b04e612a4dee4c825c498f9d8db4b8270d|src/display_compat_main.c
f|644|14f5b7bbed7f0be412d7a4a1c9c7f459b66266fe60dcfdf37ee2025598969dd1|src/ft5426_protocol.h
f|644|cfe5235869a8a9df094456e87cd7c19fc538335c832698cfb9b368b0eb7e54d2|src/panel_rockpi_rpi_touchscreen.c
f|644|711bbef47e24f82119d8650def28da25ed28e35079cd658f1f0af5c16d892bd4|src/raspits_ft5426.c
EOF
		;;
	*) return 1 ;;
	esac
}

source_tree_matches_release()
{
	source_root=$1
	source_version=$2
	source_ownership_error=
	if [ ! -d "$source_root" ] || [ -L "$source_root" ] ||
		[ "$(stat -c '%a' -- "$source_root" 2>/dev/null || true)" != 755 ]; then
		source_ownership_error="source root is not an exact mode-755 directory: $source_root"
		return 1
	fi
	if ! source_manifest=$(source_release_manifest "$source_version"); then
		source_ownership_error="no source ownership manifest for release $source_version"
		return 1
	fi
	source_expected_layout=$(printf '%s\n' "$source_manifest" |
		awk -F '|' '{ print $1 "|" $2 "|" $4 }' | LC_ALL=C sort)
	if ! source_actual_layout=$(cd "$source_root" &&
		find . -mindepth 1 -printf '%y|%m|%P\n' | LC_ALL=C sort); then
		source_ownership_error="cannot enumerate source tree: $source_root"
		return 1
	fi
	if [ "$source_actual_layout" != "$source_expected_layout" ]; then
		source_ownership_error="source paths, types, or modes differ from release $source_version: $source_root"
		return 1
	fi
	if ! printf '%s\n' "$source_manifest" |
		while IFS='|' read -r source_kind source_mode source_checksum source_relative; do
			[ "$source_kind" = f ] || continue
			source_file=$source_root/$source_relative
			[ -f "$source_file" ] && [ ! -L "$source_file" ] || exit 1
			[ "$(stat -c '%a' -- "$source_file" 2>/dev/null || true)" = "$source_mode" ] || exit 1
			source_checksum_record=$(sha256sum -- "$source_file" 2>/dev/null) || exit 1
			[ "${source_checksum_record%% *}" = "$source_checksum" ] || exit 1
		done; then
		source_ownership_error="source bytes changed from release $source_version: $source_root"
		return 1
	fi
	if ! source_final_layout=$(cd "$source_root" &&
		find . -mindepth 1 -printf '%y|%m|%P\n' | LC_ALL=C sort) ||
		[ "$source_final_layout" != "$source_expected_layout" ]; then
		source_ownership_error="source tree changed during release $source_version verification: $source_root"
		return 1
	fi
	return 0
}

try_retire_owned_source_tree()
{
	retire_source=$1
	retire_version=$2
	retire_recovery_root=$3
	source_retirement_recovery=$retire_source
	source_retirement_result=error
	if ! source_tree_matches_release "$retire_source" "$retire_version"; then
		source_retirement_result=unowned
		return 1
	fi
	if [ -e "$retire_recovery_root" ] || [ -L "$retire_recovery_root" ] ||
		! mkdir -m 0700 "$retire_recovery_root"; then
		source_retirement_recovery=$retire_recovery_root
		return 1
	fi
	retire_claim=$retire_recovery_root/source
	source_retirement_recovery=$retire_claim
	if ! mv -T "$retire_source" "$retire_claim"; then
		if [ -d "$retire_claim" ] && [ ! -L "$retire_claim" ] &&
			[ ! -e "$retire_source" ] && [ ! -L "$retire_source" ]; then
			source_retirement_result=ambiguous
			return 1
		fi
		if [ -e "$retire_source" ] || [ -L "$retire_source" ]; then
			source_retirement_recovery=$retire_source
		fi
		rmdir "$retire_recovery_root" >/dev/null 2>&1 || true
		return 1
	fi
	if ! source_tree_matches_release "$retire_claim" "$retire_version"; then
		source_retirement_result=changed
		if [ ! -e "$retire_source" ] && [ ! -L "$retire_source" ] &&
			mv -n -T "$retire_claim" "$retire_source" &&
			[ ! -e "$retire_claim" ] && [ ! -L "$retire_claim" ]; then
			source_retirement_recovery=$retire_source
			rmdir "$retire_recovery_root" >/dev/null 2>&1 || true
		fi
		return 1
	fi
	if ! printf '%s\n' "$source_manifest" |
		while IFS='|' read -r source_kind source_mode source_checksum source_relative; do
			[ "$source_kind" = f ] || continue
			source_file=$retire_claim/$source_relative
			[ -f "$source_file" ] && [ ! -L "$source_file" ] || exit 1
			[ "$(stat -c '%a' -- "$source_file" 2>/dev/null || true)" = "$source_mode" ] || exit 1
			source_checksum_record=$(sha256sum -- "$source_file" 2>/dev/null) || exit 1
			[ "${source_checksum_record%% *}" = "$source_checksum" ] || exit 1
			rm -f -- "$source_file" || exit 1
			[ ! -e "$source_file" ] && [ ! -L "$source_file" ] || exit 1
		done; then
		source_retirement_result=cleanup-failed
		return 1
	fi
	case $retire_version in
	0.2.4) retire_directories='LICENSES scripts src' ;;
	0.2.5) retire_directories='LICENSES assets scripts src' ;;
	*) source_retirement_result=error; return 1 ;;
	esac
	for retire_directory in $retire_directories; do
		rmdir -- "$retire_claim/$retire_directory" || {
			source_retirement_result=cleanup-failed
			return 1
		}
	done
	if ! rmdir -- "$retire_claim" || ! rmdir -- "$retire_recovery_root"; then
		source_retirement_result=cleanup-failed
		return 1
	fi
	source_retirement_recovery=
	source_retirement_result=removed
	return 0
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
	destination_mode=${3:-0644}
	destination_dir=$(dirname -- "$destination_file")
	mkdir -p "$destination_dir" || return 1
	temporary_file=$(mktemp "$destination_dir/.${PROJECT_NAME}.XXXXXX") || return 1
	if ! cp "$source_file" "$temporary_file"; then
		rm -f "$temporary_file"
		return 1
	fi
	if ! chmod "$destination_mode" "$temporary_file"; then
		rm -f "$temporary_file"
		return 1
	fi
	if ! mv -f "$temporary_file" "$destination_file"; then
		rm -f "$temporary_file"
		return 1
	fi
}

regular_file_matches()
{
	match_source=$1
	match_destination=$2
	match_mode=$3
	[ -f "$match_destination" ] && [ ! -L "$match_destination" ] &&
		cmp -s "$match_source" "$match_destination" &&
		[ "$(stat -c '%a' "$match_destination")" = "$match_mode" ]
}

object_identity()
{
	stat -c '%d:%i:%f' -- "$1" 2>/dev/null
}

try_publish_file_no_replace()
{
	publish_source=$1
	publish_destination=$2
	publish_mode=$3
	publish_result=error
	publish_recovery=
	publish_directory=$(dirname -- "$publish_destination")
	mkdir -p "$publish_directory" || return 1
	publish_temporary=$(mktemp "$publish_directory/.${PROJECT_NAME}.publish.XXXXXX") || return 1
	publish_recovery=$publish_temporary
	if ! cp "$publish_source" "$publish_temporary" ||
		! chmod "$publish_mode" "$publish_temporary"; then
		rm -f "$publish_temporary" || true
		return 1
	fi
	if ln -T "$publish_temporary" "$publish_destination"; then
		publish_temporary_identity=$(object_identity "$publish_temporary" || true)
		publish_destination_identity=$(object_identity "$publish_destination" || true)
		if [ -z "$publish_temporary_identity" ] ||
			[ "$publish_temporary_identity" != "$publish_destination_identity" ] ||
			! regular_file_matches "$publish_source" "$publish_temporary" "$publish_mode" ||
			! regular_file_matches "$publish_source" "$publish_destination" "$publish_mode"; then
			publish_result=ambiguous
			return 1
		fi
		if ! rm -f "$publish_temporary"; then
			publish_result=ambiguous
			return 1
		fi
		publish_recovery=
		publish_result=created
		return 0
	fi
	if [ -e "$publish_destination" ] || [ -L "$publish_destination" ]; then
		publish_temporary_identity=$(object_identity "$publish_temporary" || true)
		publish_destination_identity=$(object_identity "$publish_destination" || true)
		if [ -n "$publish_temporary_identity" ] &&
			[ "$publish_temporary_identity" = "$publish_destination_identity" ]; then
			publish_result=ambiguous
			return 1
		fi
		if rm -f "$publish_temporary"; then
			publish_recovery=
			publish_result=collision
		else
			publish_result=ambiguous
		fi
		return 1
	fi
	if rm -f "$publish_temporary"; then
		publish_recovery=
	else
		publish_result=ambiguous
	fi
	return 1
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
