#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workdir=$(mktemp -d)

cleanup()
{
	rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_equal()
{
	actual=$1
	expected=$2
	message=$3
	[ "$actual" = "$expected" ] || fail "$message (got: $actual; expected: $expected)"
}

assert_file_absent()
{
	[ ! -e "$1" ] || fail "expected absent: $1"
}

make_sandbox()
{
	sandbox=$1
	mkdir -p "$sandbox/boot/overlay-user" "$sandbox/usr-src" \
		"$sandbox/modules/6.18.43-current-rockchip64/build" "$sandbox/bin" \
		"$sandbox/etc/X11/xorg.conf.d" "$sandbox/usr-libexec" \
		"$sandbox/etc/xdg/autostart" "$sandbox/etc/lightdm/lightdm.conf.d"
	cat > "$sandbox/boot/armbianEnv.txt" <<'EOF'
verbosity=1
user_overlays=spi-test
extraargs=console=ttyS2
EOF
	printf '%s\n' 'Section "Monitor"' '  Identifier "protected-hdmi"' 'EndSection' > \
		"$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf"
	cat > "$sandbox/bin/dkms" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "${DKMS_LOG:?}"
[ -z "${DKMS_PATH_LOG:-}" ] || printf '%s\n' "$PATH" > "$DKMS_PATH_LOG"
version=
kernel=
previous=
for argument do
	case $previous in
	-v) version=$argument ;;
	-k) kernel=$argument ;;
	esac
	previous=$argument
done
arch=${ARCH:?}
tuple=$version'|'$kernel'|'$arch

append_unique()
{
	line=$1
	file=$2
	[ -f "$file" ] && grep -Fxq "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

write_build_artifact()
{
	artifact_module=$1
	artifact_payload=$2
	directory=${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/$arch/module
	raw=$directory/$artifact_module.ko
	printf '%s\n' "$artifact_payload-module-$version-$kernel" > "$raw"
	case ${DKMS_BUILD_COMPRESSION:-none} in
	none) ;;
	xz) xz -c "$raw" > "$raw.xz"; rm -f "$raw" ;;
	gz) gzip -c "$raw" > "$raw.gz"; rm -f "$raw" ;;
	zst)
		{ printf '%s\n' 'FAKE-ZSTD'; cat "$raw"; } > "$raw.zst"
		rm -f "$raw"
		;;
	*) exit 43 ;;
	esac
}

find_build_artifact()
{
	artifact_module=$1
	find "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/$arch/module" -type f \
		\( -name "$artifact_module.ko" -o -name "$artifact_module.ko.xz" -o -name "$artifact_module.ko.gz" \
		-o -name "$artifact_module.ko.zst" \) -print | head -n 1
}

install_build_artifact()
{
	artifact_module=$1
	built=$(find_build_artifact "$artifact_module")
	[ -n "$built" ] || exit 44
	destination=${MODULES_DIR:?}/$kernel/updates/dkms/$artifact_module.ko
	case ${DKMS_INSTALL_COMPRESSION:-same} in
	same) cp "$built" "$destination${built#*"$artifact_module.ko"}" ;;
	none)
		case $built in
		*.xz) xz -dc "$built" > "$destination" ;;
		*.gz) gzip -dc "$built" > "$destination" ;;
		*) cp "$built" "$destination" ;;
		esac
		;;
	gz)
		case $built in
		*.xz) xz -dc "$built" | gzip -c > "$destination.gz" ;;
		*.gz) cp "$built" "$destination.gz" ;;
		*) gzip -c "$built" > "$destination.gz" ;;
		esac
		;;
	*) exit 45 ;;
	esac
}

installed_artifact_exists()
{
	artifact_module=$1
	find "${MODULES_DIR:?}/$kernel/updates/dkms" -type f \
		\( -name "$artifact_module.ko" -o -name "$artifact_module.ko.xz" -o -name "$artifact_module.ko.gz" \
		-o -name "$artifact_module.ko.zst" \) -print -quit | grep -q .
}

remove_version_records()
{
	file=$1
	[ -f "$file" ] || return 0
	awk -F '|' -v version="$version" '$1 != version' "$file" > "$file.tmp"
	mv "$file.tmp" "$file"
}

	case $1 in
	add)
	if [ -f "${DKMS_ADDED_STATE:?}" ] && grep -Fxq "$version" "$DKMS_ADDED_STATE"; then
		exit 1
	fi
		printf '%s\n' "$version" >> "$DKMS_ADDED_STATE"
		;;
	build)
		grep -Fxq "$version" "${DKMS_ADDED_STATE:?}" || exit 20
		mkdir -p "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/$arch/module"
		case $version in
		0.2.5)
			write_build_artifact rockpi_rk3399_display_compat provider
			write_build_artifact panel_rockpi_rpi_touchscreen panel
			write_build_artifact raspits_ft5426 touch
			;;
		0.2.6)
			for module in rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426; do
				printf 'build %s %s\n' "$version" "$module" >> "${DKMS_MODULE_LOG:?}"
				case $module in
				rockpi_rk3399_display_compat) payload=provider ;;
				panel_rockpi_rpi_touchscreen) payload=panel ;;
				raspits_ft5426) payload=touch ;;
				esac
				write_build_artifact "$module" "$payload"
				if [ "${DKMS_FAIL_BUILD_MODULE:-}" = "$module" ]; then
					exit 22
				fi
			done
			;;
		*) exit 19 ;;
		esac
		append_unique "$tuple" "${DKMS_BUILT_STATE:?}"
		;;
	install)
		grep -Fxq "$tuple" "${DKMS_BUILT_STATE:?}" || exit 21
		if [ "$version" = 0.2.5 ] && [ "${DKMS_FAIL_OLD_REINSTALL:-0}" -eq 1 ]; then
			exit 26
		fi
		mkdir -p "${MODULES_DIR:?}/$kernel/updates/dkms"
		case $version in
		0.2.5) install_modules='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
		0.2.6) install_modules='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
		*) exit 18 ;;
		esac
		for module in $install_modules; do
			if [ "$version" = 0.2.6 ]; then
				printf 'install %s %s\n' "$version" "$module" >> "${DKMS_MODULE_LOG:?}"
				case $module in
				panel_rockpi_rpi_touchscreen)
					installed_artifact_exists rockpi_rk3399_display_compat || exit 40
					;;
				raspits_ft5426)
					installed_artifact_exists rockpi_rk3399_display_compat || exit 41
					installed_artifact_exists panel_rockpi_rpi_touchscreen || exit 42
					;;
				esac
			fi
			install_build_artifact "$module"
			DEPMOD_INTERNAL=1 depmod -a "$kernel"
			if [ "$version" = 0.2.6 ] && [ "${DKMS_FAIL_INSTALL_MODULE:-}" = "$module" ]; then
				exit 25
			fi
		done
		if [ "$version" = 0.2.5 ]; then
			: > "${DKMS_OLD_REINSTALL_MARKER:?}"
		fi
		if [ "$version" = 0.2.5 ] && [ -n "${DKMS_CORRUPT_OLD_REINSTALL_MODULE:-}" ]; then
			printf '%s\n' corrupt-old-reinstall > \
				"${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/$arch/module/${DKMS_CORRUPT_OLD_REINSTALL_MODULE}.ko"
		fi
		if [ "$version" = 0.2.6 ] && [ -n "${DKMS_FAIL_CHECKSUM_MODULE:-}" ]; then
			printf '%s\n' corrupt-new-install > \
				"${MODULES_DIR:?}/$kernel/updates/dkms/${DKMS_FAIL_CHECKSUM_MODULE}.ko"
		fi
		if [ "${DKMS_NEW_STATUS_PHASE:-}" = built ] && [ "$version" = 0.2.6 ]; then
			exit 0
	fi
	if [ -f "${DKMS_INSTALLED_STATE:?}" ]; then
		awk -F '|' -v version="$version" -v kernel="$kernel" -v arch="$arch" \
			'$1 == version || $2 != kernel || $3 != arch' "$DKMS_INSTALLED_STATE" > "$DKMS_INSTALLED_STATE.tmp"
		mv "$DKMS_INSTALLED_STATE.tmp" "$DKMS_INSTALLED_STATE"
	fi
	append_unique "$tuple" "${DKMS_INSTALLED_STATE:?}"
	if [ -f "${DKMS_ACTIVE_STATE:?}" ]; then
		awk -F '|' -v kernel="$kernel" '$1 != kernel' "$DKMS_ACTIVE_STATE" > "$DKMS_ACTIVE_STATE.tmp"
		mv "$DKMS_ACTIVE_STATE.tmp" "$DKMS_ACTIVE_STATE"
	fi
	printf '%s|%s\n' "$kernel" "$version" >> "$DKMS_ACTIVE_STATE"
	;;
status)
	[ "${DKMS_STATUS_FAIL_VERSION:-}" != "$version" ] || exit 24
	if [ "${DKMS_STATUS_FAIL_AFTER_REMOVE:-0}" -eq 1 ] && [ -f "${DKMS_REMOVE_MARKER:?}" ] &&
		[ ! -e "${DKMS_STATUS_FAILED_MARKER:?}" ]; then
		: > "$DKMS_STATUS_FAILED_MARKER"
		exit 28
	fi
	found_lifecycle=0
	if [ -f "${DKMS_INSTALLED_STATE:?}" ]; then
		while IFS='|' read -r record_version record_kernel record_arch; do
			[ -z "$version" ] || [ "$record_version" = "$version" ] || continue
			printf '%s\n' "rockpi-rpi-touchscreen/$record_version, $record_kernel, $record_arch: installed"
			found_lifecycle=1
		done < "$DKMS_INSTALLED_STATE"
	fi
	if [ -f "${DKMS_BUILT_STATE:?}" ]; then
		while IFS='|' read -r record_version record_kernel record_arch; do
			[ -z "$version" ] || [ "$record_version" = "$version" ] || continue
			if ! [ -f "$DKMS_INSTALLED_STATE" ] ||
				! grep -Fxq "$record_version|$record_kernel|$record_arch" "$DKMS_INSTALLED_STATE"; then
				printf '%s\n' "rockpi-rpi-touchscreen/$record_version, $record_kernel, $record_arch: built"
				found_lifecycle=1
			fi
		done < "$DKMS_BUILT_STATE"
	fi
	if [ "$found_lifecycle" -eq 0 ] && [ -f "${DKMS_ADDED_STATE:?}" ]; then
		while IFS= read -r record_version; do
			[ -z "$version" ] || [ "$record_version" = "$version" ] || continue
			printf '%s\n' "rockpi-rpi-touchscreen/$record_version: added"
		done < "$DKMS_ADDED_STATE"
	fi
	;;
		remove)
			if [ "$version" = 0.2.5 ] && [ -n "${DKMS_OLD_RETIREMENT_ATTEMPT_MARKER:-}" ] &&
				[ -f "${LIBEXEC_DIR:?}/rockpi-rpi-touchscreen-map-touch" ] &&
				cmp "${DKMS_TREE:?}/rockpi-rpi-touchscreen-0.2.6/scripts/map-touchscreen.sh" \
					"${LIBEXEC_DIR:?}/rockpi-rpi-touchscreen-map-touch" >/dev/null 2>&1; then
			: > "$DKMS_OLD_RETIREMENT_ATTEMPT_MARKER"
		fi
		if [ "$version" = 0.2.6 ] && [ "${DKMS_REMOVE_GENUINE_FAIL:-0}" -eq 1 ]; then
			exit 23
		fi
		if [ "${DKMS_REQUIRE_NEW_STATE_BEFORE_OLD_REMOVE:-0}" -eq 1 ] && [ "$version" = 0.2.5 ]; then
			grep -Eq '(^|[[:space:]])rockpi-4b-plus-rpi-touchscreen($|[[:space:]])' \
				"${BOOT_DIR:?}/armbianEnv.txt" || exit 31
			[ -f "${BOOT_DIR:?}/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] || exit 32
			[ -f "${DKMS_TREE:?}/rockpi-rpi-touchscreen-0.2.6/src/display_compat_main.c" ] || exit 35
			[ -f "${BACKUP_PATH:?}" ] && [ -f "${BACKUP_PATH:?}.sha256" ] || exit 36
			sha256sum -c "${BACKUP_PATH:?}.sha256" >/dev/null || exit 37
			cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.6/6.18.43-current-rockchip64/aarch64/module/rockpi_rk3399_display_compat.ko" \
				"${MODULES_DIR:?}/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko" || exit 33
			cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.6/6.18.43-current-rockchip64/aarch64/module/panel_rockpi_rpi_touchscreen.ko" \
				"${MODULES_DIR:?}/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko" || exit 34
			cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.6/6.18.43-current-rockchip64/aarch64/module/raspits_ft5426.ko" \
				"${MODULES_DIR:?}/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko" || exit 33
			cmp "${DKMS_TREE:?}/rockpi-rpi-touchscreen-0.2.6/scripts/map-touchscreen.sh" \
				"${LIBEXEC_DIR:?}/rockpi-rpi-touchscreen-map-touch" || exit 51
			cmp "${DKMS_TREE:?}/rockpi-rpi-touchscreen-0.2.6/assets/rockpi-rpi-touchscreen-touch-map.desktop" \
				"${XDG_AUTOSTART_DIR:?}/rockpi-rpi-touchscreen-touch-map.desktop" || exit 52
			cmp "${DKMS_TREE:?}/rockpi-rpi-touchscreen-0.2.6/assets/90-rockpi-greeter-no-blank.conf" \
				"${LIGHTDM_CONFIG_DIR:?}/90-rockpi-greeter-no-blank.conf" || exit 55
			[ "$(stat -c '%a' "${LIBEXEC_DIR:?}/rockpi-rpi-touchscreen-map-touch")" = 755 ] || exit 53
			[ "$(stat -c '%a' "${XDG_AUTOSTART_DIR:?}/rockpi-rpi-touchscreen-touch-map.desktop")" = 644 ] || exit 54
			[ "$(stat -c '%a' "${LIGHTDM_CONFIG_DIR:?}/90-rockpi-greeter-no-blank.conf")" = 644 ] || exit 56
			[ "$(cat "${DKMS_ACTIVE_STATE:?}")" = '6.18.43-current-rockchip64|0.2.6' ] || exit 38
			if [ -f "${DKMS_INSTALLED_STATE:?}" ] &&
				grep -Fxq '0.2.5|6.18.43-current-rockchip64|aarch64' "$DKMS_INSTALLED_STATE"; then
				exit 39
		fi
		: > "${DKMS_NEW_ACTIVE_VERIFIED_MARKER:?}"
	fi
	if [ -f "${DKMS_ACTIVE_STATE:?}" ]; then
		: > "$DKMS_ACTIVE_STATE.tmp"
		while IFS='|' read -r active_kernel active_version; do
			if [ "$active_version" = "$version" ] &&
					{ [ -z "$kernel" ] || [ "$active_kernel" = "$kernel" ]; }; then
					case $version in
					0.2.5) remove_modules='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
					0.2.6) remove_modules='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
					*) remove_modules= ;;
					esac
					for module in $remove_modules; do
						rm -f "${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko" \
							"${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko.xz" \
							"${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko.gz" \
							"${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko.zst"
						DEPMOD_INTERNAL=1 depmod -a "$active_kernel"
						if [ "$version" = 0.2.6 ] && [ "${DKMS_FAIL_REMOVE_MODULE:-}" = "$module" ]; then
							exit 27
						fi
					done
			else
				printf '%s|%s\n' "$active_kernel" "$active_version" >> "$DKMS_ACTIVE_STATE.tmp"
			fi
		done < "$DKMS_ACTIVE_STATE"
		mv "$DKMS_ACTIVE_STATE.tmp" "$DKMS_ACTIVE_STATE"
	fi
	if [ -f "${DKMS_ADDED_STATE:?}" ]; then
		grep -Fxv "$version" "$DKMS_ADDED_STATE" > "$DKMS_ADDED_STATE.tmp" || true
		mv "$DKMS_ADDED_STATE.tmp" "$DKMS_ADDED_STATE"
	fi
	remove_version_records "${DKMS_BUILT_STATE:?}"
	remove_version_records "${DKMS_INSTALLED_STATE:?}"
	rm -rf "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version"
	[ -z "${DKMS_REMOVE_MARKER:-}" ] || : > "$DKMS_REMOVE_MARKER"
	if [ "$version" = 0.2.5 ] && [ "${DKMS_FAIL_OLD_REMOVE_AFTER_MUTATION:-0}" -eq 1 ] &&
		[ ! -e "${DKMS_OLD_REMOVE_FAILED_MARKER:?}" ]; then
		: > "$DKMS_OLD_REMOVE_FAILED_MARKER"
		exit 46
	fi
	;;
esac
if [ "$version" = 0.2.6 ] && [ "${DKMS_FAIL_ON:-}" = "$1" ]; then
	exit 1
fi
EOF
	chmod +x "$sandbox/bin/dkms"
	cat > "$sandbox/bin/depmod" <<'EOF'
#!/bin/sh
set -eu
printf 'internal=%s args=%s\n' "${DEPMOD_INTERNAL:-0}" "$*" >> "${DEPMOD_LOG:?}"
if [ "${DEPMOD_FAIL_EXTERNAL:-0}" -eq 1 ] && [ "${DEPMOD_INTERNAL:-0}" -ne 1 ]; then
	exit 48
fi
kernel=
for argument do
	case $argument in
	-*) ;;
	*) kernel=$argument ;;
	esac
done
[ -n "$kernel" ] || exit 49
module_root=${MODULES_DIR:?}/$kernel
mkdir -p "$module_root"
find "$module_root" -type f \
	\( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.gz' -o -name '*.ko.zst' \) \
	-print | LC_ALL=C sort | sed "s|^$module_root/||; s|$|:|" > "$module_root/modules.dep.tmp"
/bin/mv "$module_root/modules.dep.tmp" "$module_root/modules.dep"
sed 's/^/alias fake:/' "$module_root/modules.dep" > "$module_root/modules.alias"
EOF
	chmod +x "$sandbox/bin/depmod"
	cat > "$sandbox/bin/modinfo" <<'EOF'
#!/bin/sh
set -eu
kernel=
field=
module=
while [ "$#" -gt 0 ]; do
	case $1 in
	-k) kernel=$2; shift 2 ;;
	-n) module=$2; shift 2 ;;
	-F) field=$2; module=$3; shift 3 ;;
	*) module=$1; shift ;;
	esac
done
if [ -z "$field" ]; then
	dependency_index=${MODULES_DIR:?}/$kernel/modules.dep
	[ -f "$dependency_index" ] || exit 1
	module_relative=$(awk -F: -v module="$module" '
		{
			n = split($1, components, "/")
			base = components[n]
			if (base == module ".ko" || base == module ".ko.xz" ||
			    base == module ".ko.gz" || base == module ".ko.zst") {
				print $1
				exit
			}
		}
	' "$dependency_index")
	[ -n "$module_relative" ] || exit 1
	module_path=${MODULES_DIR:?}/$kernel/$module_relative
	[ -n "$module_path" ] && [ -f "$module_path" ] || exit 1
	if [ -n "${DKMS_CORRUPT_COMPRESSED_OLD_ROLLBACK_MODULE:-}" ] &&
		[ "$module" = "$DKMS_CORRUPT_COMPRESSED_OLD_ROLLBACK_MODULE" ] &&
		[ -f "${DKMS_OLD_REINSTALL_MARKER:?}" ]; then
		printf '%s\n' corrupt-compressed-old-installed > "$module_path"
	fi
	printf '%s\n' "$module_path"
	exit 0
fi
	case $field in
	license) printf '%s\n' 'GPL v2' ;;
	vermagic) printf '%s\n' '6.18.43-current-rockchip64 SMP mod_unload aarch64' ;;
	alias)
		module_base=${module##*/}
		module_base=${module_base%.xz}
		module_base=${module_base%.gz}
		module_base=${module_base%.zst}
		case $module_base in
		rockpi_rk3399_display_compat.ko) printf '%s\n' "${MODINFO_PROVIDER_ALIAS:-of:N*T*Crockpi,rk3399-dsi1-rpi-touchscreen-compat}" ;;
		raspits_ft5426.ko) printf '%s\n' 'of:N*T*Craspits_ft5426' ;;
	panel_rockpi_rpi_touchscreen.ko) printf '%s\n' "${MODINFO_PANEL_ALIAS:-of:N*T*Crockpi,rpi-7inch-touchscreen-panel}" ;;
	*) exit 1 ;;
	esac
	;;
*) exit 1 ;;
esac
EOF
	chmod +x "$sandbox/bin/modinfo"
	cat > "$sandbox/bin/zstd" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "${ZSTD_LOG:?}"
input=
for argument do
	case $argument in
	-*) ;;
	*) input=$argument ;;
	esac
done
[ -n "$input" ] && [ "$(sed -n '1p' "$input")" = 'FAKE-ZSTD' ] || exit 47
sed -n '2,$p' "$input"
EOF
	chmod +x "$sandbox/bin/zstd"
	cat > "$sandbox/bin/id" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = '-u' ]; then
	printf '0\n'
	exit 0
fi
exec /usr/bin/id "$@"
EOF
	chmod +x "$sandbox/bin/id"
	cat > "$sandbox/bin/install" <<'EOF'
#!/bin/sh
set -eu
last=
for argument do
	last=$argument
done
if [ -n "${INSTALL_FORBIDDEN_TARGET:-}" ] && [ "$last" = "$INSTALL_FORBIDDEN_TARGET" ]; then
	exit 1
fi
if [ -n "${INSTALL_FAIL_TARGET:-}" ] && [ "$last" = "$INSTALL_FAIL_TARGET" ]; then
	exit 1
fi
exec /usr/bin/install "$@"
EOF
	chmod +x "$sandbox/bin/install"
cat > "$sandbox/bin/mv" <<'EOF'
#!/bin/sh
set -eu
last=
source=
for argument do
	last=$argument
	case $argument in
	-*) ;;
	*) [ -n "$source" ] || source=$argument ;;
	esac
done
printf '%s\n' "$*" >> "${MV_LOG:?}"
[ -z "${OP_LOG:-}" ] || printf 'mv %s\n' "$*" >> "$OP_LOG"
if [ -n "${MV_FAIL_ALWAYS_TARGET:-}" ] && [ "$last" = "$MV_FAIL_ALWAYS_TARGET" ]; then
	exit 1
fi
if [ -n "${MV_FAIL_SOURCE:-}" ] && [ "$source" = "$MV_FAIL_SOURCE" ]; then
	exit 1
fi
case ${MV_FAIL_ROLLBACK_PREFIX:-} in
'') ;;
*) case $1 in
   "${MV_FAIL_ROLLBACK_PREFIX}"*) exit 1 ;;
   esac ;;
esac
if [ -n "${MV_FAIL_TARGET:-}" ] && [ "$last" = "$MV_FAIL_TARGET" ] &&
	[ ! -e "${MV_FAIL_ONCE_MARKER:?}" ]; then
	: > "$MV_FAIL_ONCE_MARKER"
	exit 1
fi
if [ -n "${MV_CREATE_FILE_BEFORE_TARGET:-}" ] && [ "$last" = "$MV_CREATE_FILE_BEFORE_TARGET" ]; then
	printf '%s\n' raced-runtime-asset > "$last"
	chmod 0600 "$last"
fi
if [ -n "${MV_MUTATE_SOURCE_TREE:-}" ] && [ "$source" = "$MV_MUTATE_SOURCE_TREE" ]; then
	printf '%s\n' raced-source-data > "$source/local-race"
	chmod 0600 "$source/local-race"
fi
/bin/mv "$@"
if [ -n "${MV_FAIL_AFTER_SOURCE:-}" ] && [ "$source" = "$MV_FAIL_AFTER_SOURCE" ] &&
	[ ! -e "${MV_FAIL_AFTER_SOURCE_MARKER:?}" ]; then
	: > "$MV_FAIL_AFTER_SOURCE_MARKER"
	exit 1
fi
if [ -n "${MV_CREATE_FILE_AFTER_SOURCE:-}" ] && [ "$2" = "$MV_CREATE_FILE_AFTER_SOURCE" ]; then
	printf '%s\n' raced-runtime-asset > "${MV_CREATE_FILE_AFTER_TARGET:?}"
	chmod 0600 "${MV_CREATE_FILE_AFTER_TARGET:?}"
fi
if [ -n "${MV_REPLACE_SYMLINK_AFTER_TARGET:-}" ] &&
	[ "$last" = "${MV_REPLACE_SYMLINK_TRIGGER:?}" ]; then
	/bin/rm -f "$MV_REPLACE_SYMLINK_AFTER_TARGET"
	/bin/ln -s "${MV_REPLACE_SYMLINK_VALUE:?}" "$MV_REPLACE_SYMLINK_AFTER_TARGET"
fi
if [ -n "${MV_CORRUPT_AFTER_TARGET:-}" ] && [ "$last" = "$MV_CORRUPT_AFTER_TARGET" ]; then
	printf '%s\n' corrupt-runtime-asset > "$last"
fi
if [ -n "${MV_CORRUPT_FILE_AFTER_TARGET:-}" ] &&
	[ "$last" = "${MV_CORRUPT_FILE_TRIGGER:?}" ]; then
	if [ -z "${MV_CORRUPT_FILE_AFTER_ONCE_MARKER:-}" ] ||
		[ ! -e "$MV_CORRUPT_FILE_AFTER_ONCE_MARKER" ]; then
		[ -z "${MV_CORRUPT_FILE_AFTER_ONCE_MARKER:-}" ] || : > "$MV_CORRUPT_FILE_AFTER_ONCE_MARKER"
		printf '%s\n' "${MV_CORRUPT_FILE_CONTENT:-corrupt-runtime-asset}" > "$MV_CORRUPT_FILE_AFTER_TARGET"
		[ -z "${MV_CORRUPT_FILE_MODE:-}" ] ||
			chmod "$MV_CORRUPT_FILE_MODE" "$MV_CORRUPT_FILE_AFTER_TARGET"
	fi
fi
if [ -n "${MV_FAIL_AFTER_TARGET:-}" ] && [ "$last" = "$MV_FAIL_AFTER_TARGET" ] &&
	[ ! -e "${MV_FAIL_AFTER_ONCE_MARKER:?}" ]; then
	: > "$MV_FAIL_AFTER_ONCE_MARKER"
	exit 1
fi
EOF
chmod +x "$sandbox/bin/mv"
	cat > "$sandbox/bin/ln" <<'EOF'
#!/bin/sh
set -eu
last=
for argument do
	last=$argument
done
[ -z "${OP_LOG:-}" ] || printf 'ln %s\n' "$*" >> "$OP_LOG"
if [ -n "${LN_CREATE_FILE_BEFORE_TARGET:-}" ] && [ "$last" = "$LN_CREATE_FILE_BEFORE_TARGET" ]; then
	printf '%s\n' raced-runtime-asset > "$last"
	chmod 0600 "$last"
fi
if [ -n "${LN_CREATE_SYMLINK_BEFORE_TARGET:-}" ] && [ "$last" = "$LN_CREATE_SYMLINK_BEFORE_TARGET" ]; then
	/bin/ln -s "${LN_CREATE_SYMLINK_VALUE:?}" "$last"
fi
if [ -n "${LN_CREATE_DIRECTORY_BEFORE_TARGET:-}" ] && [ "$last" = "$LN_CREATE_DIRECTORY_BEFORE_TARGET" ]; then
	mkdir "$last"
fi
if [ -n "${LN_FAIL_BEFORE_TARGET:-}" ] && [ "$last" = "$LN_FAIL_BEFORE_TARGET" ] &&
	[ ! -e "${LN_FAIL_BEFORE_TARGET_MARKER:?}" ]; then
	: > "$LN_FAIL_BEFORE_TARGET_MARKER"
	exit 1
fi
/bin/ln "$@"
if [ -n "${LN_CORRUPT_AFTER_TARGET:-}" ] && [ "$last" = "$LN_CORRUPT_AFTER_TARGET" ]; then
	printf '%s\n' corrupt-runtime-asset > "$last"
fi
if [ -n "${LN_CORRUPT_FILE_AFTER_TARGET:-}" ] &&
	[ "$last" = "${LN_CORRUPT_FILE_TRIGGER:?}" ]; then
	printf '%s\n' corrupt-runtime-asset > "$LN_CORRUPT_FILE_AFTER_TARGET"
fi
if [ -n "${LN_FAIL_AFTER_TARGET:-}" ] && [ "$last" = "$LN_FAIL_AFTER_TARGET" ] &&
	[ ! -e "${LN_FAIL_AFTER_TARGET_MARKER:?}" ]; then
	: > "$LN_FAIL_AFTER_TARGET_MARKER"
	exit 1
fi
EOF
	chmod +x "$sandbox/bin/ln"
	cat > "$sandbox/bin/cp" <<'EOF'
#!/bin/sh
set -eu
source_file=
destination_file=
old_state_restore=0
for argument do
	case $argument in
	-*) ;;
	*) [ -n "$source_file" ] || source_file=$argument ;;
	esac
	destination_file=$argument
	if [ "${CP_FAIL_ARCHIVE:-}" = 1 ] && [ "$argument" = '-a' ]; then
		exit 1
	fi
done
case $source_file in
*"/.rockpi-rpi-touchscreen.transaction."*"/old-dkms-state") old_state_restore=1 ;;
esac
if [ "${CP_FAIL_PRIVATE_BOOT_RESTORE:-0}" -eq 1 ]; then
	case $source_file in
	*"/.rockpi-rpi-touchscreen.transaction."*"/current-armbianEnv.txt") exit 50 ;;
	esac
fi
if [ -n "${CP_FAIL_SNAPSHOT_MODULE:-}" ]; then
	case $source_file:$destination_file in
	*"/modules/6.18.43-current-rockchip64/"*"/$CP_FAIL_SNAPSHOT_MODULE.ko:"*"/.rockpi-rpi-touchscreen.transaction."*"/prior-modules/"*) exit 29 ;;
	esac
fi
if [ -n "${CP_MUTATE_RUNTIME_SOURCE:-}" ] && [ "$source_file" = "$CP_MUTATE_RUNTIME_SOURCE" ]; then
	case $destination_file in
	*"/.rockpi-rpi-touchscreen.uninstall."*"/runtime/"*)
		case ${CP_MUTATE_RUNTIME_KIND:-file} in
		file)
			printf '%s\n' pre-snapshot-local-edit > "$source_file"
			chmod 0755 "$source_file"
			;;
		symlink)
			/bin/rm -f "$source_file"
			/bin/ln -s "${CP_MUTATE_RUNTIME_SYMLINK_TARGET:?}" "$source_file"
			;;
		directory)
			/bin/rm -f "$source_file"
			mkdir "$source_file"
			printf '%s\n' local-directory-data > "$source_file/local-data"
			;;
		*) exit 61 ;;
		esac
		;;
	esac
fi
/bin/cp "$@"
if [ "${DKMS_CORRUPT_UNINSTALL_STATE_RESTORE:-0}" -eq 1 ]; then
	case $source_file in
	*"/.rockpi-rpi-touchscreen.uninstall."*"/dkms-state")
		mkdir -p "$destination_file/transaction-metadata"
		printf '%s\n' corrupt-uninstall-state > "$destination_file/transaction-metadata/baseline"
		;;
	esac
fi
if [ "$old_state_restore" -eq 1 ] && [ -n "${DKMS_CORRUPT_OLD_REINSTALL_MODULE:-}" ]; then
	printf '%s\n' corrupt-old-state-restore > \
		"$destination_file/6.18.43-current-rockchip64/aarch64/module/${DKMS_CORRUPT_OLD_REINSTALL_MODULE}.ko"
fi
if [ "$old_state_restore" -eq 1 ] &&
	[ -n "${DKMS_CORRUPT_COMPRESSED_OLD_ROLLBACK_MODULE:-}" ]; then
	printf '%s\n' corrupt-compressed-old-build > \
		"$destination_file/6.18.43-current-rockchip64/aarch64/module/${DKMS_CORRUPT_COMPRESSED_OLD_ROLLBACK_MODULE}.ko.xz"
fi
EOF
	chmod +x "$sandbox/bin/cp"
	cat > "$sandbox/bin/rm" <<'EOF'
#!/bin/sh
set -eu
last=
for argument do
	last=$argument
done
[ -z "${RM_LOG:-}" ] || printf '%s\n' "$*" >> "$RM_LOG"
[ -z "${OP_LOG:-}" ] || printf 'rm %s\n' "$*" >> "$OP_LOG"
case ${RM_FAIL_TRANSACTION_ROOT_PREFIX:-} in
'') ;;
*) case $last in
   "${RM_FAIL_TRANSACTION_ROOT_PREFIX}"*)
		remainder=${last#"${RM_FAIL_TRANSACTION_ROOT_PREFIX}"}
		case $remainder in
		*/*) ;;
		*) exit 30 ;;
		esac
		;;
   esac ;;
esac
if [ -n "${RM_FAIL_SOURCE_RETIREMENT_BASENAME:-}" ]; then
	case $last in
	*"source-retirement/source/${RM_FAIL_SOURCE_RETIREMENT_BASENAME}")
		[ -z "${RM_CORRUPT_FILE_ON_FAILURE:-}" ] ||
			printf '%s\n' corrupt-runtime-asset > "$RM_CORRUPT_FILE_ON_FAILURE"
		exit 30
		;;
	esac
fi
if [ -n "${RM_FAIL_TARGET:-}" ] && [ "$last" = "$RM_FAIL_TARGET" ]; then
	exit 30
fi
case ${RM_FAIL_PREFIX:-} in
'') ;;
*) case $last in
   "${RM_FAIL_PREFIX}"*) exit 30 ;;
   esac ;;
esac
case ${RM_FAIL_PREFIX_SECOND:-} in
'') ;;
*) case $last in
   "${RM_FAIL_PREFIX_SECOND}"*) exit 30 ;;
   esac ;;
esac
/bin/rm "$@"
rm_status=$?
[ "$rm_status" -eq 0 ] || exit "$rm_status"
if [ -n "${RM_REPLACE_PUBLICATION_TEMP_PREFIX:-}" ] &&
	[ ! -e "${RM_REPLACE_PUBLICATION_MARKER:?}" ]; then
	case $last in
	"${RM_REPLACE_PUBLICATION_TEMP_PREFIX}"*)
		replacement_temporary=${RM_REPLACE_PUBLICATION_DESTINATION:?}.replacement.$$
		/bin/cp "${RM_REPLACE_PUBLICATION_SOURCE:?}" "$replacement_temporary"
		/bin/chmod "${RM_REPLACE_PUBLICATION_MODE:?}" "$replacement_temporary"
		/bin/mv -f "$replacement_temporary" "$RM_REPLACE_PUBLICATION_DESTINATION"
		/usr/bin/stat -c '%d:%i:%f' "$RM_REPLACE_PUBLICATION_DESTINATION" > \
			"${RM_REPLACE_PUBLICATION_IDENTITY_FILE:?}"
		: > "$RM_REPLACE_PUBLICATION_MARKER"
		;;
	esac
fi
exit 0
EOF
	chmod +x "$sandbox/bin/rm"
	cat > "$sandbox/bin/sha256sum" <<'EOF'
#!/bin/sh
set -eu
printf 'PWD=%s ARGS=%s\n' "$PWD" "$*" >> "${SHA256_LOG:?}"
exec /usr/bin/sha256sum "$@"
EOF
	chmod +x "$sandbox/bin/sha256sum"
	cat > "$sandbox/validate-pass.sh" <<'EOF'
#!/bin/sh
set -eu
mkdir -p "${BUILD_DIR:?}"
: > "${BUILD_DIR}/rockpi-4b-plus-rpi-touchscreen.dtbo"
printf '%s\n' validated >> "${VALIDATE_LOG:?}"
EOF
	chmod +x "$sandbox/validate-pass.sh"
	cat > "$sandbox/validate-fail.sh" <<'EOF'
#!/bin/sh
printf '%s\n' rejected >> "${VALIDATE_LOG:?}"
exit 1
EOF
	chmod +x "$sandbox/validate-fail.sh"
}

run_install()
{
	sandbox=$1
	validator=$2
	shift 2
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	protected_before=
	if [ "${SKIP_WRAPPER_PROTECTED_CHECK:-0}" -ne 1 ]; then
		protected_before=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	fi
	status=0
	BOOT_DIR="$sandbox/boot" DKMS_TREE="$sandbox/usr-src" \
	MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=${INSTALL_KERNEL_RELEASE:-6.18.43-current-rockchip64} \
	LIBEXEC_DIR="$sandbox/usr-libexec" XDG_AUTOSTART_DIR="$sandbox/etc/xdg/autostart" \
	LIGHTDM_CONFIG_DIR="$sandbox/etc/lightdm/lightdm.conf.d" \
	BUILD_DIR="$sandbox/build" BACKUP_PATH="$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak" \
	VALIDATE_SCRIPT="$validator" VALIDATE_LOG="$sandbox/validate.log" \
	DKMS_LOG="$sandbox/dkms.log" DKMS_PATH_LOG="$sandbox/dkms.path" \
	DKMS_ADDED_STATE="$sandbox/dkms-added.state" DKMS_BUILT_STATE="$sandbox/dkms-built.state" \
	DKMS_INSTALLED_STATE="$sandbox/dkms-installed.state" DKMS_ACTIVE_STATE="$sandbox/dkms-active.state" \
		DKMS_REMOVE_MARKER="$sandbox/dkms-remove.marker" DKMS_STATUS_FAILED_MARKER="$sandbox/dkms-status-failed.marker" \
		DKMS_OLD_REMOVE_FAILED_MARKER="$sandbox/dkms-old-remove-failed.marker" \
		DKMS_OLD_REINSTALL_MARKER="$sandbox/dkms-old-reinstall.marker" \
		DKMS_NEW_ACTIVE_VERIFIED_MARKER="$sandbox/dkms-new-active-verified.marker" \
		DKMS_MODULE_LOG="$sandbox/dkms-module.log" SHA256_LOG="$sandbox/sha256.log" \
		ZSTD_LOG="$sandbox/zstd.log" DEPMOD_LOG="$sandbox/depmod.log" \
		DKMS_STATE_DIR="$sandbox/var-lib-dkms" \
		ARCH=aarch64 MV_LOG="$sandbox/mv.log" PROTECTED_XORG_PATH="$protected" \
		PATH="$sandbox/bin:$PATH" \
		sh "$repo_root/scripts/install.sh" "$@" || status=$?
	if [ "${SKIP_WRAPPER_PROTECTED_CHECK:-0}" -ne 1 ]; then
		protected_after=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
		assert_equal "$protected_after" "$protected_before" \
			'installer changed protected HDMI Xorg configuration'
	fi
	return "$status"
}

test_installer_rejects_unsupported_kernel_before_validation_or_mutation()
{
	sandbox=$workdir/unsupported-install-kernel
	make_sandbox "$sandbox"
	supported=6.18.43-current-rockchip64
	unsupported=$supported-extra
	before=$(cat "$sandbox/boot/armbianEnv.txt")
	if INSTALL_KERNEL_RELEASE=$unsupported \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted an unsupported kernel release'
	fi
	grep -Fq "unsupported kernel release: $unsupported (expected $supported)" "$sandbox/output" ||
		fail 'installer did not report the exact supported-kernel boundary'
	[ ! -e "$sandbox/validate.log" ] || fail 'unsupported install kernel reached validation'
	[ ! -s "$sandbox/dkms.log" ] || fail 'unsupported install kernel reached DKMS mutation'
	assert_equal "$(cat "$sandbox/boot/armbianEnv.txt")" "$before" \
		'unsupported install kernel changed boot configuration'
	printf 'PASS: installer rejects unsupported kernels before validation or mutation\n'
}

assert_module_matches_build()
{
	sandbox=$1
	version=$2
	module=$3
	built=$(find "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/$version/6.18.43-current-rockchip64/aarch64/module" \
		-type f \( -name "$module.ko" -o -name "$module.ko.xz" -o -name "$module.ko.gz" \
		-o -name "$module.ko.zst" \) -print | head -n 1)
	installed=$(find "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms" \
		-type f \( -name "$module.ko" -o -name "$module.ko.xz" -o -name "$module.ko.gz" \
		-o -name "$module.ko.zst" \) -print | head -n 1)
	[ -n "$built" ] && [ -f "$built" ] || fail "missing built module: $module"
	[ -n "$installed" ] && [ -f "$installed" ] || fail "missing installed module: $module"
	if ! built_checksum=$(module_content_checksum "$built"); then
		fail "cannot checksum built module: $module"
	fi
	if ! installed_checksum=$(module_content_checksum "$installed"); then
		fail "cannot checksum installed module: $module"
	fi
	assert_equal "$built_checksum" "$installed_checksum" \
		"installed module differs from DKMS build: $module"
}

assert_runtime_assets_match_source()
{
	sandbox=$1
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	lightdm=$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf
	cmp "$repo_root/scripts/map-touchscreen.sh" "$source/scripts/map-touchscreen.sh" ||
		fail 'immutable source mapper differs from the repository asset'
	cmp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" \
		"$source/assets/rockpi-rpi-touchscreen-touch-map.desktop" ||
		fail 'immutable source autostart differs from the repository asset'
	cmp "$repo_root/assets/90-rockpi-greeter-no-blank.conf" \
		"$source/assets/90-rockpi-greeter-no-blank.conf" ||
		fail 'immutable source LightDM policy differs from the repository asset'
	assert_equal "$(stat -c '%a' "$source/scripts/map-touchscreen.sh")" '755' \
		'immutable source mapper mode'
	assert_equal "$(stat -c '%a' "$source/assets/rockpi-rpi-touchscreen-touch-map.desktop")" '644' \
		'immutable source autostart mode'
	assert_equal "$(stat -c '%a' "$source/assets/90-rockpi-greeter-no-blank.conf")" '644' \
		'immutable source LightDM policy mode'
	cmp "$source/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'installed mapper differs from immutable source'
	cmp "$source/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$autostart" ||
		fail 'installed autostart differs from immutable source'
	cmp "$source/assets/90-rockpi-greeter-no-blank.conf" "$lightdm" ||
		fail 'installed LightDM policy differs from immutable source'
	assert_equal "$(stat -c '%a' "$mapper")" '755' 'installed mapper mode'
	assert_equal "$(stat -c '%a' "$autostart")" '644' 'installed autostart mode'
	assert_equal "$(stat -c '%a' "$lightdm")" '644' 'installed LightDM policy mode'
}

module_content_checksum()
{
	module_file=$1
	checksum_input=$module_file
	checksum_temporary=
	case $module_file in
	*.ko.xz)
		checksum_temporary=$(mktemp)
		xz -dc "$module_file" > "$checksum_temporary" || {
			rm -f "$checksum_temporary"
			return 1
		}
		checksum_input=$checksum_temporary
		;;
	*.ko.gz)
		checksum_temporary=$(mktemp)
		gzip -dc "$module_file" > "$checksum_temporary" || {
			rm -f "$checksum_temporary"
			return 1
		}
		checksum_input=$checksum_temporary
		;;
	*.ko.zst)
		checksum_temporary=$(mktemp)
		zstd -q -dc "$module_file" > "$checksum_temporary" || {
			rm -f "$checksum_temporary"
			return 1
		}
		checksum_input=$checksum_temporary
		;;
	esac
	if ! checksum_record=$(/usr/bin/sha256sum "$checksum_input"); then
		[ -z "$checksum_temporary" ] || rm -f "$checksum_temporary"
		return 1
	fi
	checksum=${checksum_record%% *}
	[ -z "$checksum_temporary" ] || rm -f "$checksum_temporary"
	[ -n "$checksum" ] || return 1
	printf '%s\n' "$checksum"
}

sandbox_dkms_status()
{
	sandbox=$1
	version=$2
	DKMS_LOG="$sandbox/dkms.log" DKMS_ADDED_STATE="$sandbox/dkms-added.state" \
	DKMS_BUILT_STATE="$sandbox/dkms-built.state" DKMS_INSTALLED_STATE="$sandbox/dkms-installed.state" \
	DKMS_ACTIVE_STATE="$sandbox/dkms-active.state" DKMS_STATE_DIR="$sandbox/var-lib-dkms" \
	DKMS_REMOVE_MARKER="$sandbox/dkms-remove.marker" DKMS_STATUS_FAILED_MARKER="$sandbox/dkms-status-failed.marker" \
	DKMS_OLD_REMOVE_FAILED_MARKER="$sandbox/dkms-old-remove-failed.marker" \
	DKMS_NEW_ACTIVE_VERIFIED_MARKER="$sandbox/dkms-new-active-verified.marker" \
	MODULES_DIR="$sandbox/modules" ARCH=aarch64 \
		"$sandbox/bin/dkms" status -m rockpi-rpi-touchscreen -v "$version"
}

refresh_dependency_indexes()
{
	sandbox=$1
	DEPMOD_LOG="$sandbox/depmod.log" MODULES_DIR="$sandbox/modules" DEPMOD_INTERNAL=1 \
		PATH="$sandbox/bin:$PATH" "$sandbox/bin/depmod" -a 6.18.43-current-rockchip64
}

indexed_module_path()
{
	sandbox=$1
	module=$2
	MODULES_DIR="$sandbox/modules" "$sandbox/bin/modinfo" -k 6.18.43-current-rockchip64 -n "$module"
}

run_uninstall()
{
	sandbox=$1
	shift
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	protected_before=
	if [ "${SKIP_WRAPPER_PROTECTED_CHECK:-0}" -ne 1 ]; then
		protected_before=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	fi
	status=0
	BOOT_DIR="$sandbox/boot" DKMS_TREE="$sandbox/usr-src" \
	MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=6.18.43-current-rockchip64 \
	LIBEXEC_DIR="$sandbox/usr-libexec" XDG_AUTOSTART_DIR="$sandbox/etc/xdg/autostart" \
	LIGHTDM_CONFIG_DIR="$sandbox/etc/lightdm/lightdm.conf.d" \
	DKMS_LOG="$sandbox/dkms.log" \
	DKMS_ADDED_STATE="$sandbox/dkms-added.state" DKMS_BUILT_STATE="$sandbox/dkms-built.state" \
	DKMS_INSTALLED_STATE="$sandbox/dkms-installed.state" DKMS_ACTIVE_STATE="$sandbox/dkms-active.state" \
		DKMS_REMOVE_MARKER="$sandbox/dkms-remove.marker" DKMS_STATUS_FAILED_MARKER="$sandbox/dkms-status-failed.marker" \
		DKMS_OLD_REMOVE_FAILED_MARKER="$sandbox/dkms-old-remove-failed.marker" \
		DKMS_NEW_ACTIVE_VERIFIED_MARKER="$sandbox/dkms-new-active-verified.marker" \
		DKMS_MODULE_LOG="$sandbox/dkms-module.log" SHA256_LOG="$sandbox/sha256.log" \
		DEPMOD_LOG="$sandbox/depmod.log" DKMS_STATE_DIR="$sandbox/var-lib-dkms" \
		ARCH=aarch64 MV_LOG="$sandbox/mv.log" RM_LOG="$sandbox/rm.log" \
		PROTECTED_XORG_PATH="$protected" \
		OP_LOG="$sandbox/operations.log" PATH="$sandbox/bin:$PATH" \
		sh "$repo_root/scripts/uninstall.sh" "$@" || status=$?
	if [ "${SKIP_WRAPPER_PROTECTED_CHECK:-0}" -ne 1 ]; then
		protected_after=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
		assert_equal "$protected_after" "$protected_before" \
			'uninstaller changed protected HDMI Xorg configuration'
	fi
	return "$status"
}

run_offline_boot_rollback()
{
	sandbox=$1
	target_root=$2
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	protected_before=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	status=0
	BOOT_DIR="$sandbox/host-boot" DKMS_TREE="$sandbox/host-usr-src" \
		DKMS_LOG="$sandbox/dkms.log" SHA256_LOG="$sandbox/sha256.log" \
		ARCH=aarch64 MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
		PROTECTED_XORG_PATH="$protected" \
		sh "$repo_root/scripts/uninstall.sh" --offline-boot-root "$target_root" || status=$?
	protected_after=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	assert_equal "$protected_after" "$protected_before" \
		'offline rollback changed protected HDMI Xorg configuration'
	return "$status"
}

protected_xorg_hash_count()
{
	protected_path=$1
	log_file=$2
	[ -f "$log_file" ] || {
		printf '0\n'
		return
	}
	awk -v protected_path="$protected_path" '
		index($0, protected_path) { count++ }
		END { print count + 0 }
	' "$log_file"
}

test_production_transactions_attest_protected_xorg_on_success()
{
	sandbox=$workdir/production-protected-success
	make_sandbox "$sandbox"
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	: > "$sandbox/sha256.log"
	SKIP_WRAPPER_PROTECTED_CHECK=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh"
	[ "$(protected_xorg_hash_count "$protected" "$sandbox/sha256.log")" -ge 2 ] ||
		fail 'production installer did not hash protected Xorg before and after mutation'
	: > "$sandbox/sha256.log"
	SKIP_WRAPPER_PROTECTED_CHECK=1 run_uninstall "$sandbox"
	[ "$(protected_xorg_hash_count "$protected" "$sandbox/sha256.log")" -ge 2 ] ||
		fail 'production uninstaller did not hash protected Xorg before and after mutation'
	printf 'PASS: production transactions attest protected Xorg on success\n'
}

test_install_reports_committed_protected_xorg_mutation()
{
	sandbox=$workdir/install-protected-committed-mutation
	make_sandbox "$sandbox"
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	config=$sandbox/boot/armbianEnv.txt
	if SKIP_WRAPPER_PROTECTED_CHECK=1 \
		MV_CORRUPT_FILE_AFTER_TARGET="$protected" MV_CORRUPT_FILE_TRIGGER="$config" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a protected Xorg mutation after committing installation'
	fi
	grep -Fq 'installation committed, but protected Xorg attestation failed:' "$sandbox/output" ||
		fail 'installer did not accurately report committed state after protected Xorg mutation'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'protected Xorg attestation failure pretended the committed installation rolled back'
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" ] ||
		fail 'committed install was rolled back after protected Xorg attestation failure'
	printf 'PASS: install reports committed outcome after protected Xorg mutation\n'
}

test_uninstall_reports_committed_protected_xorg_mutation()
{
	sandbox=$workdir/uninstall-protected-committed-mutation
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	config=$sandbox/boot/armbianEnv.txt
	if SKIP_WRAPPER_PROTECTED_CHECK=1 \
		MV_CORRUPT_FILE_AFTER_TARGET="$protected" MV_CORRUPT_FILE_TRIGGER="$config" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstaller accepted a protected Xorg mutation after committing uninstall'
	fi
	grep -Fq 'uninstall committed, but protected Xorg attestation failed:' "$sandbox/output" ||
		fail 'uninstaller did not accurately report committed state after protected Xorg mutation'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" '' \
		'protected Xorg attestation failure pretended the committed uninstall rolled back'
	[ ! -e "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" ] ||
		fail 'committed uninstall restored source after protected Xorg attestation failure'

	sandbox=$workdir/uninstall-protected-committed-type-change
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	config=$sandbox/boot/armbianEnv.txt
	cp "$protected" "$protected.target"
	if SKIP_WRAPPER_PROTECTED_CHECK=1 \
		MV_REPLACE_SYMLINK_AFTER_TARGET="$protected" \
		MV_REPLACE_SYMLINK_TRIGGER="$config" \
		MV_REPLACE_SYMLINK_VALUE="$protected.target" \
		run_uninstall "$sandbox" > "$sandbox/type-output" 2>&1; then
		fail 'uninstaller accepted a protected Xorg type change after committing uninstall'
	fi
	grep -Fq 'uninstall committed, but protected Xorg attestation failed:' \
		"$sandbox/type-output" ||
		fail 'uninstaller did not report committed state after protected Xorg type change'
	[ -L "$protected" ] || fail 'protected Xorg type-change injection did not take effect'
	printf 'PASS: uninstall reports committed outcome after protected Xorg mutation\n'
}

test_protected_xorg_attestation_runs_after_install_rollback()
{
	sandbox=$workdir/install-protected-rollback-mutation
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	config=$sandbox/boot/armbianEnv.txt
	if SKIP_WRAPPER_PROTECTED_CHECK=1 DKMS_FAIL_OLD_REMOVE_AFTER_MUTATION=1 \
		MV_CORRUPT_FILE_AFTER_TARGET="$protected" MV_CORRUPT_FILE_TRIGGER="$config" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted an injected rollback with protected Xorg mutation'
	fi
	grep -Fq 'rollback completed, but protected Xorg attestation failed:' "$sandbox/output" ||
		fail 'install rollback exit did not report failed protected Xorg attestation'
	[ "$(protected_xorg_hash_count "$protected" "$sandbox/sha256.log")" -ge 2 ] ||
		fail 'install rollback exit did not hash protected Xorg after mutation handling'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'protected Xorg mutation prevented the ordinary install transaction rollback'
	printf 'PASS: protected Xorg attestation runs after install rollback\n'
}

test_protected_xorg_preflight_rejects_missing_unreadable_and_wrong_type()
{
	for variant in missing unreadable symlink; do
		sandbox=$workdir/install-protected-preflight-$variant
		make_sandbox "$sandbox"
		protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
		case $variant in
		missing) rm -f "$protected" ;;
		unreadable) chmod 000 "$protected" ;;
		symlink)
			/bin/mv "$protected" "$protected.target"
			/bin/ln -s "$protected.target" "$protected"
			;;
		esac
		if SKIP_WRAPPER_PROTECTED_CHECK=1 \
			run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
			fail "installer accepted $variant protected Xorg path"
		fi
		grep -Fq "protected Xorg path must be a readable regular file: $protected" \
			"$sandbox/output" ||
			fail "installer did not diagnose $variant protected Xorg path"
		[ ! -e "$sandbox/validate.log" ] ||
			fail "$variant protected Xorg path reached validation"
		[ ! -s "$sandbox/dkms.log" ] ||
			fail "$variant protected Xorg path reached DKMS mutation"
	done

	sandbox=$workdir/uninstall-protected-preflight-type
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	/bin/mv "$protected" "$protected.target"
	/bin/ln -s "$protected.target" "$protected"
	config=$sandbox/boot/armbianEnv.txt
	config_before=$(cat "$config")
	: > "$sandbox/dkms.log"
	if SKIP_WRAPPER_PROTECTED_CHECK=1 run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstaller accepted type-changed protected Xorg path'
	fi
	grep -Fq "protected Xorg path must be a readable regular file: $protected" "$sandbox/output" ||
		fail 'uninstaller did not diagnose type-changed protected Xorg path'
	[ ! -s "$sandbox/dkms.log" ] ||
		fail 'type-changed protected Xorg path reached DKMS mutation during uninstall'
	assert_equal "$(cat "$config")" "$config_before" \
		'type-changed protected Xorg path reached uninstall boot mutation'
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" ] ||
		fail 'type-changed protected Xorg path reached source removal'
	printf 'PASS: protected Xorg preflight rejects missing, unreadable, and wrong-type paths\n'
}

test_boot_configuration_uses_atomic_mv_for_update_and_rollback()
{
	sandbox=$workdir/atomic-boot-config
	make_sandbox "$sandbox"
	config=$sandbox/boot/armbianEnv.txt
	before=$(cat "$config")
	if INSTALL_FORBIDDEN_TARGET="$config" MV_FAIL_TARGET="$config" \
		MV_FAIL_ONCE_MARKER="$sandbox/mv-failed-once" \
		run_install "$sandbox" "$sandbox/validate-pass.sh"; then
		fail 'installer accepted failed atomic boot configuration move'
	fi
	assert_equal "$(cat "$config")" "$before" \
		'failed atomic update restores boot configuration through atomic replacement'
	awk -v target="$config" '$NF == target { count++ } END { exit count == 2 ? 0 : 1 }' \
		"$sandbox/mv.log" || fail 'boot update and rollback must each use mv to the boot configuration'
	printf 'PASS: boot configuration update and rollback use atomic mv\n'
}

test_offline_boot_rollback_changes_only_explicit_target_root()
{
	sandbox=$workdir/offline-boot-rollback
	make_sandbox "$sandbox"
	target_root=$sandbox/target-root
	mkdir -p "$target_root/boot" "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.6"
	printf '%s\n' 'user_overlays=spi-test rockpi-4b-plus-rpi-touchscreen' > "$target_root/boot/armbianEnv.txt"
	: > "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.6/sentinel"
	: > "$sandbox/dkms.log"

	run_offline_boot_rollback "$sandbox" "$target_root"
	assert_equal "$(cat "$target_root/boot/armbianEnv.txt")" 'user_overlays=spi-test' \
		'offline rollback removes only the project token from the explicit target root'
	[ -f "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.6/sentinel" ] ||
		fail 'offline rollback changed the running-host source tree'
	[ ! -s "$sandbox/dkms.log" ] || fail 'offline rollback invoked DKMS'
	printf 'PASS: target-root boot-config-only offline rollback\n'
}

test_install_is_idempotent_and_preserves_unrelated_boot_text()
{
	sandbox=$workdir/idempotent
	make_sandbox "$sandbox"
	original=$(cat "$sandbox/boot/armbianEnv.txt")
	original_checksum=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')

	run_install "$sandbox" "$sandbox/validate-pass.sh"
	after_first=$(cat "$sandbox/boot/armbianEnv.txt")
	expected='verbosity=1
user_overlays=spi-test rockpi-4b-plus-rpi-touchscreen
extraargs=console=ttyS2'
	assert_equal "$after_first" "$expected" 'install adds exactly one project overlay token'
	grep -Fqx "$original_checksum  $sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak" \
		"$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak.sha256" || \
		fail 'backup checksum must describe original boot configuration'
	[ "$(cat "$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak")" = "$original" ] || \
		fail 'backup must equal original boot configuration'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6/dkms.conf" ] || \
		fail 'installer must copy owned DKMS source tree'
	assert_module_matches_build "$sandbox" 0.2.6 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.6 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.6 raspits_ft5426
	[ -f "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] || \
		fail 'installer must install user overlay'
	assert_equal "$(stat -c '%a' "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo")" \
		'644' 'installed overlay mode'

	run_install "$sandbox" "$sandbox/validate-pass.sh"
	assert_equal "$(cat "$sandbox/boot/armbianEnv.txt")" "$after_first" \
		'second install is byte-identical'
	printf 'PASS: idempotent install preserves boot configuration and backup\n'
}

test_install_handoff_requires_authorized_dsi_first_acceptance()
{
	sandbox=$workdir/install-handoff
	make_sandbox "$sandbox"
	output=$(run_install "$sandbox" "$sandbox/validate-pass.sh")
	printf '%s\n' "$output" | grep -Fqx 'NEXT: installation is complete; no automatic power action occurs. Obtain fresh authorization before any reboot or shutdown.' ||
		fail 'installer handoff must require fresh authorization without an automatic power action'
	printf '%s\n' "$output" | grep -Fqx 'NEXT: first authorized boot: keep HDMI disconnected; validate DSI-1, RGB, and physical touch; then hot-plug HDMI.' ||
		fail 'installer handoff must require DSI-first acceptance before HDMI hot-plug'
	if printf '%s\n' "$output" | grep -Fq 'boot with HDMI'; then
		fail 'installer handoff retained the obsolete boot-with-HDMI guidance'
	fi
	printf 'PASS: installer handoff requires authorized DSI-first acceptance\n'
}

test_dkms_make_command_suppresses_automatic_kernelrelease()
{
	grep -Fqx "MAKE[0]=\"'sh' scripts/dkms-make.sh \${kernelver} make KDIR=/lib/modules/\${kernelver}/build modules\"" "$repo_root/dkms.conf" ||
		fail 'DKMS make command must quote make so DKMS does not append KERNELRELEASE'
	printf 'PASS: DKMS make command suppresses automatic KERNELRELEASE\n'
}

test_uninstall_removes_only_project_token_and_dry_run_is_scoped()
{
	sandbox=$workdir/uninstall
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	dry_run=$(run_uninstall "$sandbox" --dry-run)
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ||
		fail 'dry run must print owned overlay path'
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" ||
		fail 'dry run must print owned source path'
	printf '%s\n' "$dry_run" | grep -Fqx "CONFIG: $sandbox/boot/armbianEnv.txt" ||
		fail 'dry run must print the exact boot configuration path'
	printf '%s\n' "$dry_run" | grep -Fqx 'user_overlays=spi-test' ||
		fail 'dry run must print resulting overlay line'
	printf '%s\n' "$dry_run" | grep -Fqx 'MODULE: rockpi_rk3399_display_compat' ||
		fail 'dry run must name the provider module'
	printf '%s\n' "$dry_run" | grep -Fqx 'MODULE: panel_rockpi_rpi_touchscreen' ||
		fail 'dry run must name the panel module'
	printf '%s\n' "$dry_run" | grep -Fqx 'MODULE: raspits_ft5426' ||
		fail 'dry run must name the touch module'
	module_order=$(printf '%s\n' "$dry_run" | sed -n 's/^MODULE: //p')
	assert_equal "$module_order" 'rockpi_rk3399_display_compat
panel_rockpi_rpi_touchscreen
raspits_ft5426' 'dry run must report dependency-safe module order'
	[ -f "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] ||
		fail 'dry run must not remove overlay'

	run_uninstall "$sandbox"
	assert_equal "$(cat "$sandbox/boot/armbianEnv.txt")" \
		'verbosity=1
user_overlays=spi-test
extraargs=console=ttyS2' \
		'uninstall removes only the project overlay token'
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	printf 'PASS: scoped uninstall and dry run\n'
}

test_uninstall_dry_run_lists_runtime_assets()
{
	sandbox=$workdir/uninstall-runtime-dry-run
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	lightdm=$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf
	mapper_before=$(sha256sum "$mapper" | awk '{print $1}')
	autostart_before=$(sha256sum "$autostart" | awk '{print $1}')
	lightdm_before=$(sha256sum "$lightdm" | awk '{print $1}')
	dry_run=$(run_uninstall "$sandbox" --dry-run)
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $mapper" ||
		fail 'runtime dry run did not list the owned touch mapper'
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $autostart" ||
		fail 'runtime dry run did not list the owned touch autostart entry'
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $lightdm" ||
		fail 'runtime dry run did not list the owned LightDM greeter policy'
	assert_equal "$(sha256sum "$mapper" | awk '{print $1}')" "$mapper_before" \
		'runtime dry run changed the touch mapper'
	assert_equal "$(sha256sum "$autostart" | awk '{print $1}')" "$autostart_before" \
		'runtime dry run changed the touch autostart entry'
	assert_equal "$(sha256sum "$lightdm" | awk '{print $1}')" "$lightdm_before" \
		'runtime dry run changed the LightDM greeter policy'
	assert_equal "$(stat -c '%a' "$mapper")" '755' 'runtime dry run changed mapper mode'
	assert_equal "$(stat -c '%a' "$autostart")" '644' 'runtime dry run changed autostart mode'
	assert_equal "$(stat -c '%a' "$lightdm")" '644' 'runtime dry run changed LightDM policy mode'
	printf 'PASS: uninstall dry run lists owned runtime assets without mutation\n'
}

test_uninstall_dry_run_retains_modified_autostart_dependency()
{
	sandbox=$workdir/uninstall-runtime-dry-run-autostart-dependency
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	config=$sandbox/boot/armbianEnv.txt
	dtbo=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
	cp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$autostart"
	chmod 0600 "$autostart"
	mapper_before=$(sha256sum "$mapper" | awk '{print $1}')
	autostart_before=$(sha256sum "$autostart" | awk '{print $1}')
	config_before=$(sha256sum "$config" | awk '{print $1}')
	dtbo_before=$(sha256sum "$dtbo" | awk '{print $1}')
	source_before=$(source_tree_digest "$source")
	dry_run=$(run_uninstall "$sandbox" --dry-run)
	printf '%s\n' "$dry_run" | grep -Fqx "RETAIN MODIFIED: $autostart" ||
		fail 'dry run did not report the modified autostart'
	printf '%s\n' "$dry_run" | grep -Fqx "RETAIN DEPENDENCY: $mapper" ||
		fail 'dry run did not retain the mapper dependency for modified autostart'
	if printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $mapper"; then
		fail 'dry run contradicted real uninstall by removing the mapper dependency'
	fi
	assert_equal "$(sha256sum "$mapper" | awk '{print $1}')" "$mapper_before" \
		'dependency-aware dry run changed mapper bytes'
	assert_equal "$(stat -c '%a' "$mapper")" '755' \
		'dependency-aware dry run changed mapper mode'
	assert_equal "$(sha256sum "$autostart" | awk '{print $1}')" "$autostart_before" \
		'dependency-aware dry run changed autostart bytes'
	assert_equal "$(stat -c '%a' "$autostart")" '600' \
		'dependency-aware dry run changed autostart mode'
	assert_equal "$(sha256sum "$config" | awk '{print $1}')" "$config_before" \
		'dependency-aware dry run changed boot configuration'
	assert_equal "$(sha256sum "$dtbo" | awk '{print $1}')" "$dtbo_before" \
		'dependency-aware dry run changed DTBO bytes'
	assert_equal "$(source_tree_digest "$source")" "$source_before" \
		'dependency-aware dry run changed DKMS source'
	printf 'PASS: dry run retains modified autostart and its mapper dependency without mutation\n'
}

test_uninstall_removes_matching_runtime_assets()
{
	sandbox=$workdir/uninstall-runtime-removal
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	run_uninstall "$sandbox"
	assert_file_absent "$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch"
	assert_file_absent "$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop"
	assert_file_absent "$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf"
	printf 'PASS: uninstall removes matching owned runtime assets\n'
}

test_uninstall_retains_and_reports_modified_lightdm_policy()
{
	sandbox=$workdir/uninstall-modified-lightdm
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	lightdm=$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf
	printf '%s\n' '[Seat:*]' 'xserver-command=X -core' > "$lightdm"
	chmod 0600 "$lightdm"
	lightdm_before=$(sha256sum "$lightdm" | awk '{print $1}')
	output=$(run_uninstall "$sandbox")
	assert_equal "$(sha256sum "$lightdm" | awk '{print $1}')" "$lightdm_before" \
		'uninstall changed a modified LightDM greeter policy'
	assert_equal "$(stat -c '%a' "$lightdm")" '600' \
		'uninstall changed modified LightDM policy mode'
	printf '%s\n' "$output" | grep -Fqx "RETAIN MODIFIED: $lightdm" ||
		fail 'uninstall did not report the retained modified LightDM policy'
	if printf '%s\n' "$output" | grep -Fq 'rollback also failed'; then
		fail 'modified LightDM policy retention reported rollback failure'
	fi
	printf 'PASS: uninstall retains and reports a modified LightDM greeter policy\n'
}

test_uninstall_retains_and_reports_modified_mapper()
{
	sandbox=$workdir/uninstall-modified-mapper
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	printf '%s\n' 'locally modified mapper' > "$mapper"
	chmod 0700 "$mapper"
	mapper_before=$(sha256sum "$mapper" | awk '{print $1}')
	output=$(run_uninstall "$sandbox")
	assert_equal "$(sha256sum "$mapper" | awk '{print $1}')" "$mapper_before" \
		'uninstall changed a modified touch mapper'
	assert_equal "$(stat -c '%a' "$mapper")" '700' 'uninstall changed modified mapper mode'
	printf '%s\n' "$output" | grep -Fqx "RETAIN MODIFIED: $mapper" ||
		fail 'uninstall did not report the retained modified mapper'
	if printf '%s\n' "$output" | grep -Fq 'rollback also failed'; then
		fail 'modified mapper retention reported rollback failure'
	fi
	assert_file_absent "$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	grep -Fqx 'user_overlays=spi-test' "$sandbox/boot/armbianEnv.txt" ||
		fail 'modified mapper retention did not remove the project overlay token'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" '' \
		'modified mapper retention did not remove DKMS state'
	printf 'PASS: uninstall retains and reports a modified mapper\n'
}

test_uninstall_retains_and_reports_modified_autostart()
{
	sandbox=$workdir/uninstall-modified-autostart
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	cp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$autostart"
	chmod 0600 "$autostart"
	autostart_before=$(sha256sum "$autostart" | awk '{print $1}')
	output=$(run_uninstall "$sandbox")
	assert_equal "$(sha256sum "$autostart" | awk '{print $1}')" "$autostart_before" \
		'uninstall changed a modified touch autostart entry'
	assert_equal "$(stat -c '%a' "$autostart")" '600' 'uninstall changed modified autostart mode'
	printf '%s\n' "$output" | grep -Fqx "RETAIN MODIFIED: $autostart" ||
		fail 'uninstall did not report the retained modified autostart entry'
	if printf '%s\n' "$output" | grep -Fq 'rollback also failed'; then
		fail 'modified autostart retention reported rollback failure'
	fi
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'uninstall stranded retained autostart without its mapper dependency'
	assert_equal "$(stat -c '%a' "$mapper")" '755' \
		'uninstall changed the mapper retained for modified autostart'
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	grep -Fqx 'user_overlays=spi-test' "$sandbox/boot/armbianEnv.txt" ||
		fail 'modified autostart retention did not remove the project overlay token'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" '' \
		'modified autostart retention did not remove DKMS state'
	printf 'PASS: uninstall retains modified autostart with its mapper dependency\n'
}

test_uninstall_late_failure_restores_removed_runtime_assets()
{
	sandbox=$workdir/uninstall-runtime-rollback
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	lightdm=$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf
	mapper_before=$(sha256sum "$mapper" | awk '{print $1}')
	autostart_before=$(sha256sum "$autostart" | awk '{print $1}')
	lightdm_before=$(sha256sum "$lightdm" | awk '{print $1}')
	if MV_FAIL_SOURCE="$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a late source-removal failure'
	fi
	if grep -Fq 'rollback also failed' "$sandbox/output"; then
		fail 'late runtime rollback reported failure'
	fi
	autostart_remove_line=$(awk -v source="$autostart" '$1 == "mv" && $3 == source { print NR; exit }' \
		"$sandbox/operations.log")
	mapper_remove_line=$(awk -v source="$mapper" '$1 == "mv" && $3 == source { print NR; exit }' \
		"$sandbox/operations.log")
	source_remove_line=$(awk -v source="$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" \
		'$1 == "mv" && $3 == source { print NR; exit }' "$sandbox/operations.log")
	[ -n "$autostart_remove_line" ] && [ -n "$mapper_remove_line" ] && [ -n "$source_remove_line" ] ||
		fail 'late failure was not injected after runtime asset claims'
	[ "$autostart_remove_line" -lt "$mapper_remove_line" ] &&
		[ "$mapper_remove_line" -lt "$source_remove_line" ] ||
		fail 'uninstall did not claim autostart then mapper before the late failure'
	assert_equal "$(sha256sum "$mapper" | awk '{print $1}')" "$mapper_before" \
		'late rollback did not restore touch mapper bytes'
	assert_equal "$(sha256sum "$autostart" | awk '{print $1}')" "$autostart_before" \
		'late rollback did not restore touch autostart bytes'
	assert_equal "$(sha256sum "$lightdm" | awk '{print $1}')" "$lightdm_before" \
		'late rollback did not restore LightDM policy bytes'
	assert_equal "$(stat -c '%a' "$mapper")" '755' 'late rollback did not restore mapper mode'
	assert_equal "$(stat -c '%a' "$autostart")" '644' 'late rollback did not restore autostart mode'
	assert_equal "$(stat -c '%a' "$lightdm")" '644' 'late rollback did not restore LightDM policy mode'
	printf 'PASS: late uninstall failure restores removed runtime assets exactly\n'
}

test_uninstall_runtime_restore_failure_retains_recovery()
{
	sandbox=$workdir/uninstall-runtime-restore-failure
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	if LN_CREATE_FILE_BEFORE_TARGET="$autostart" \
		MV_FAIL_SOURCE="$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a failed runtime asset restoration'
	fi
	grep -Fq "touch autostart restoration failed: $autostart" "$sandbox/output" ||
		fail 'uninstall did not report the exact failed autostart restoration'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'runtime restoration failure did not fail closed'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'runtime restoration failure discarded transaction recovery'
	[ -f "$recovery/runtime/autostart" ] ||
		fail 'runtime restoration recovery lacks the autostart snapshot'
	grep -Fq "$recovery" "$sandbox/output" ||
		fail 'runtime restoration failure did not report the recovery directory'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'runtime restoration failure did not restore mapper before autostart recovery'
	grep -Fqx 'raced-runtime-asset' "$autostart" ||
		fail 'runtime rollback overwrote an autostart modified after its snapshot'
	printf 'PASS: failed runtime restoration retains named recovery\n'
}

test_uninstall_dry_run_retains_modified_runtime_assets()
{
	sandbox=$workdir/uninstall-runtime-dry-run-modified
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	printf '%s\n' locally-modified-mapper > "$mapper"
	chmod 0700 "$mapper"
	cp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$autostart"
	chmod 0600 "$autostart"
	mapper_before=$(sha256sum "$mapper" | awk '{print $1}')
	autostart_before=$(sha256sum "$autostart" | awk '{print $1}')
	dry_run=$(run_uninstall "$sandbox" --dry-run)
	printf '%s\n' "$dry_run" | grep -Fqx "RETAIN MODIFIED: $mapper" ||
		fail 'modified mapper dry run did not report retention'
	printf '%s\n' "$dry_run" | grep -Fqx "RETAIN MODIFIED: $autostart" ||
		fail 'modified autostart dry run did not report retention'
	assert_equal "$(sha256sum "$mapper" | awk '{print $1}')" "$mapper_before" \
		'modified mapper dry run changed bytes'
	assert_equal "$(sha256sum "$autostart" | awk '{print $1}')" "$autostart_before" \
		'modified autostart dry run changed bytes'
	assert_equal "$(stat -c '%a' "$mapper")" '700' 'modified mapper dry run changed mode'
	assert_equal "$(stat -c '%a' "$autostart")" '600' 'modified autostart dry run changed mode'
	printf 'PASS: dry run retains and reports modified runtime assets\n'
}

test_uninstall_claim_revalidates_modified_runtime_asset()
{
	sandbox=$workdir/uninstall-runtime-claim-race
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	config=$sandbox/boot/armbianEnv.txt
	output=$sandbox/output
	MV_CORRUPT_FILE_AFTER_TARGET="$mapper" MV_CORRUPT_FILE_TRIGGER="$config" \
		run_uninstall "$sandbox" > "$output" 2>&1 ||
		fail 'uninstall rejected a safely retained post-snapshot mapper modification'
	grep -Fqx 'corrupt-runtime-asset' "$mapper" ||
		fail 'uninstall removed the mapper modified after snapshot'
	assert_equal "$(stat -c '%a' "$mapper")" '755' \
		'uninstall changed the mode of the post-snapshot modified mapper'
	grep -Fqx "RETAIN MODIFIED: $mapper" "$output" ||
		fail 'uninstall did not report the post-snapshot modified mapper'
	assert_file_absent "$autostart"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	printf 'PASS: uninstall revalidates and retains a post-snapshot modified mapper\n'
}

test_uninstall_pre_snapshot_byte_edit_is_retained()
{
	sandbox=$workdir/uninstall-pre-snapshot-edit
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	if ! CP_MUTATE_RUNTIME_SOURCE="$mapper" CP_MUTATE_RUNTIME_KIND=file \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall rejected a safely retained pre-snapshot byte edit'
	fi
	grep -Fqx 'pre-snapshot-local-edit' "$mapper" ||
		fail 'uninstall deleted the mapper edited at the snapshot boundary'
	assert_equal "$(stat -c '%a' "$mapper")" '755' \
		'uninstall changed the pre-snapshot mapper mode'
	grep -Fqx "RETAIN MODIFIED: $mapper" "$sandbox/output" ||
		fail 'uninstall did not report the pre-snapshot mapper edit'
	printf 'PASS: uninstall revalidates immutable source at the snapshot boundary\n'
}

test_uninstall_pre_snapshot_type_replacements_are_retained()
{
	for kind in symlink directory; do
		sandbox=$workdir/uninstall-pre-snapshot-$kind
		make_sandbox "$sandbox"
		run_install "$sandbox" "$sandbox/validate-pass.sh"
		mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
		if ! CP_MUTATE_RUNTIME_SOURCE="$mapper" CP_MUTATE_RUNTIME_KIND=$kind \
			CP_MUTATE_RUNTIME_SYMLINK_TARGET=/tmp/local-touch-mapper \
			run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
			fail "uninstall rejected a safely retained pre-snapshot mapper $kind"
		fi
		case $kind in
		symlink)
			[ -L "$mapper" ] || fail 'uninstall changed pre-snapshot mapper symlink type'
			assert_equal "$(readlink "$mapper")" /tmp/local-touch-mapper \
				'uninstall changed pre-snapshot mapper symlink target'
			;;
		directory)
			[ -d "$mapper" ] && [ -f "$mapper/local-data" ] ||
				fail 'uninstall changed pre-snapshot mapper directory contents'
			;;
		esac
		grep -Fqx "RETAIN MODIFIED: $mapper" "$sandbox/output" ||
			fail "uninstall did not report pre-snapshot mapper $kind retention"
	done
	printf 'PASS: uninstall retains pre-snapshot symlink and directory replacements\n'
}

test_uninstall_rename_then_error_retains_named_claim()
{
	sandbox=$workdir/uninstall-rename-then-error
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	if MV_FAIL_AFTER_SOURCE="$autostart" \
		MV_FAIL_AFTER_SOURCE_MARKER="$sandbox/autostart-rename-failed-after" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a claim rename that mutated before error'
	fi
	claim=$(find "$sandbox/etc/xdg/autostart" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.uninstall.autostart.*' -print -quit)
	[ -n "$claim" ] || fail 'rename-then-error discarded the exact held autostart claim'
	cmp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$claim" ||
		fail 'rename-then-error changed held autostart claim bytes'
	assert_equal "$(stat -c '%a' "$claim")" '644' \
		'rename-then-error changed held autostart claim mode'
	grep -Fq "touch autostart claim retained at $claim" "$sandbox/output" ||
		fail 'rename-then-error did not report the nonempty held claim path'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'rename-then-error discarded transaction recovery'
	printf 'PASS: rename-then-error retains and reports the exact held claim\n'
}

test_uninstall_failed_claim_move_retains_edited_recovery()
{
	sandbox=$workdir/uninstall-failed-edited-claim
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	config=$sandbox/boot/armbianEnv.txt
	if MV_CORRUPT_FILE_AFTER_TARGET="$autostart" MV_CORRUPT_FILE_TRIGGER="$config" \
		MV_CORRUPT_FILE_AFTER_ONCE_MARKER="$sandbox/autostart-locally-edited" \
		MV_CORRUPT_FILE_CONTENT=local-byte-edit-before-failed-claim \
		MV_CORRUPT_FILE_MODE=0600 \
		MV_FAIL_AFTER_SOURCE="$autostart" \
		MV_FAIL_AFTER_SOURCE_MARKER="$sandbox/autostart-claim-failed-after" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstaller accepted a failed claim after a local autostart edit'
	fi
	[ -f "$sandbox/autostart-locally-edited" ] &&
		[ -f "$sandbox/autostart-claim-failed-after" ] ||
		fail 'uninstall claim regression did not reach both edit and rename-then-error boundaries'
	claim=$(find "$sandbox/etc/xdg/autostart" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.uninstall.autostart.*' -print -quit)
	[ -n "$claim" ] || fail 'failed uninstall claim move discarded the locally edited autostart recovery'
	[ -f "$claim" ] && [ ! -L "$claim" ] ||
		fail 'failed uninstall claim move changed the edited autostart regular-file type'
	assert_equal "$(cat "$claim")" local-byte-edit-before-failed-claim \
		'failed uninstall claim move changed the edited autostart bytes'
	assert_equal "$(stat -c '%a' "$claim")" 600 \
		'failed uninstall claim move changed the edited autostart mode'
	grep -Fq "touch autostart claim retained at $claim" "$sandbox/output" ||
		fail 'uninstall did not report the exact edited autostart recovery path'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'ambiguous uninstall claim did not retain transaction recovery'
	printf 'PASS: failed uninstall claim move retains exact edited bytes, type, mode, and path\n'
}

test_uninstall_claim_cleanup_failure_reports_nonempty_recovery()
{
	sandbox=$workdir/uninstall-claim-cleanup-failure
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	claim_prefix=$sandbox/etc/xdg/autostart/.rockpi-rpi-touchscreen.uninstall.autostart.
	if RM_FAIL_PREFIX="$claim_prefix" run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a held-claim cleanup failure'
	fi
	claim=$(find "$sandbox/etc/xdg/autostart" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.uninstall.autostart.*' -print -quit)
	[ -n "$claim" ] || fail 'claim cleanup failure discarded the recoverable claim'
	grep -Fq "touch autostart claim retained at $claim" "$sandbox/output" ||
		fail 'claim cleanup failure reported an empty or wrong claim recovery path'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'claim cleanup failure discarded transaction recovery'
	printf 'PASS: claim cleanup failure reports nonempty claim and transaction recovery\n'
}

test_uninstall_claim_preserves_mapper_for_raced_autostart()
{
	sandbox=$workdir/uninstall-runtime-autostart-claim-race
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	output=$sandbox/output
	MV_CREATE_FILE_AFTER_SOURCE="$autostart" MV_CREATE_FILE_AFTER_TARGET="$autostart" \
		run_uninstall "$sandbox" > "$output" 2>&1 &&
		fail 'uninstall accepted a raced autostart dependency conflict'
	grep -Fqx 'raced-runtime-asset' "$autostart" ||
		fail 'uninstall did not retain autostart that appeared after its claim'
	assert_equal "$(stat -c '%a' "$autostart")" '600' \
		'uninstall changed raced autostart mode'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'uninstall stranded raced autostart without mapper dependency'
	grep -Fqx "RETAIN MODIFIED: $autostart" "$output" ||
		fail 'uninstall did not report raced autostart retention'
	grep -Fqx "RETAIN DEPENDENCY: $mapper" "$output" ||
		fail 'uninstall did not report mapper retained for raced autostart'
	grep -Fq 'rollback also failed' "$output" ||
		fail 'raced autostart dependency conflict did not retain recovery'
	printf 'PASS: raced autostart retains mapper dependency and recovery\n'
}

test_uninstall_autostart_claim_collision_retains_recovery()
{
	sandbox=$workdir/uninstall-runtime-autostart-claim-collision
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	config=$sandbox/boot/armbianEnv.txt
	if MV_CORRUPT_FILE_AFTER_TARGET="$autostart" MV_CORRUPT_FILE_TRIGGER="$config" \
		MV_CORRUPT_FILE_AFTER_ONCE_MARKER="$sandbox/autostart-corrupted" \
		MV_CREATE_FILE_BEFORE_TARGET="$autostart" run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a held autostart claim collision'
	fi
	claim=$(find "$sandbox/etc/xdg/autostart" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.uninstall.autostart.*' -print -quit)
	[ -n "$claim" ] || fail 'held autostart claim was discarded after publication collision'
	grep -Fqx 'corrupt-runtime-asset' "$claim" ||
		fail 'held autostart claim bytes were changed after collision'
	assert_equal "$(stat -c '%a' "$claim")" '644' 'held autostart claim mode changed after collision'
	grep -Fqx 'raced-runtime-asset' "$autostart" ||
		fail 'autostart collision destination was overwritten'
	assert_equal "$(stat -c '%a' "$autostart")" '600' \
		'autostart collision destination mode changed'
	grep -Fq "touch autostart claim retained at $claim" "$sandbox/output" ||
		fail 'uninstall did not report held autostart claim path'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'held autostart claim did not retain rollback recovery'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'held autostart claim discarded transaction recovery'
	grep -Fq "$recovery" "$sandbox/output" ||
		fail 'held autostart claim did not report transaction recovery'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'held autostart claim unexpectedly removed mapper dependency'
	printf 'PASS: held autostart claim collision retains both artifacts and recovery\n'
}

test_uninstall_mapper_claim_linearizes_autostart_dependency()
{
	sandbox=$workdir/uninstall-runtime-mapper-claim-race
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	if MV_CREATE_FILE_AFTER_SOURCE="$mapper" MV_CREATE_FILE_AFTER_TARGET="$autostart" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a mapper-claim autostart dependency race'
	fi
	grep -Fqx 'raced-runtime-asset' "$autostart" ||
		fail 'mapper-claim race did not retain appeared autostart'
	assert_equal "$(stat -c '%a' "$autostart")" '600' \
		'mapper-claim race changed appeared autostart mode'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'mapper-claim race stranded autostart without restored mapper'
	assert_equal "$(stat -c '%a' "$mapper")" '755' \
		'mapper-claim race changed restored mapper mode'
	grep -Fqx "RETAIN DEPENDENCY: $mapper" "$sandbox/output" ||
		fail 'mapper-claim race did not report retained mapper dependency'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'mapper-claim race did not retain recovery after dependency restoration'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'mapper-claim race discarded dependency recovery'
	printf 'PASS: mapper claim linearizes autostart dependency restoration\n'
}

test_uninstall_claim_retains_raced_symlink_mapper()
{
	sandbox=$workdir/uninstall-runtime-symlink-claim
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	config=$sandbox/boot/armbianEnv.txt
	symlink_target=/tmp/local-touch-mapper
	MV_REPLACE_SYMLINK_AFTER_TARGET="$mapper" MV_REPLACE_SYMLINK_TRIGGER="$config" \
		MV_REPLACE_SYMLINK_VALUE="$symlink_target" run_uninstall "$sandbox" > "$sandbox/output" 2>&1 ||
		fail 'uninstall rejected a safely retained post-snapshot mapper symlink'
	[ -L "$mapper" ] || fail 'uninstall did not retain post-snapshot mapper symlink type'
	assert_equal "$(readlink "$mapper")" "$symlink_target" \
		'uninstall changed post-snapshot mapper symlink target'
	grep -Fqx "RETAIN MODIFIED: $mapper" "$sandbox/output" ||
		fail 'uninstall did not report post-snapshot mapper symlink retention'
	assert_file_absent "$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop"
	printf 'PASS: post-snapshot mapper symlink is retained without deletion\n'
}

test_uninstall_runtime_restore_publication_never_overwrites_race()
{
	sandbox=$workdir/uninstall-runtime-restore-race
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	if MV_CREATE_FILE_BEFORE_TARGET="$autostart" LN_CREATE_FILE_BEFORE_TARGET="$autostart" \
		MV_FAIL_SOURCE="$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a runtime restore publication race'
	fi
	grep -Fqx 'raced-runtime-asset' "$autostart" ||
		fail 'runtime restore publication overwrote the raced autostart asset'
	assert_equal "$(stat -c '%a' "$autostart")" '600' \
		'runtime restore publication changed raced autostart mode'
	grep -Fqx "RETAIN MODIFIED: $autostart" "$sandbox/output" ||
		fail 'runtime restore publication race did not report retained autostart'
	grep -Fq "touch autostart restoration failed: $autostart" "$sandbox/output" ||
		fail 'runtime restore publication race did not name the failed autostart restoration'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'runtime restore publication race did not retain recovery'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'runtime restore publication race discarded recovery'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'runtime restore publication race did not restore mapper first'
	printf 'PASS: runtime restore publication never overwrites a raced asset\n'
}

test_uninstall_recovery_cleanup_failure_is_reported()
{
	sandbox=$workdir/uninstall-recovery-cleanup-failure
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	recovery_prefix=$sandbox/usr-src/.rockpi-rpi-touchscreen.uninstall.
	if RM_FAIL_TRANSACTION_ROOT_PREFIX="$recovery_prefix" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a failed recovery cleanup'
	fi
	grep -Fq 'uninstall completed but recovery cleanup failed' "$sandbox/output" ||
		fail 'uninstall did not report committed recovery cleanup failure'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'uninstall did not retain failed recovery cleanup artifacts'
	grep -Fq "$recovery" "$sandbox/output" ||
		fail 'uninstall did not name retained recovery cleanup artifacts'
	assert_file_absent "$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch"
	assert_file_absent "$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: committed uninstall reports failed recovery cleanup\n'
}

assert_install_remains_committed_after_cleanup_failure()
{
	sandbox=$1
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'committed cleanup failure changed the installed DKMS lifecycle'
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" ] ||
		fail 'committed cleanup failure removed installed source'
	assert_runtime_assets_match_source "$sandbox"
	[ "$(awk '
		/^[[:space:]]*user_overlays[[:space:]]*=/ {
			for (field = 1; field <= NF; field++)
				if ($field == "rockpi-4b-plus-rpi-touchscreen") count++
		}
		END { print count + 0 }
	' "$sandbox/boot/armbianEnv.txt")" -eq 1 ] ||
		fail 'committed cleanup failure rolled back the boot overlay token'
	cmp "$sandbox/build/rockpi-4b-plus-rpi-touchscreen.dtbo" \
		"$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ||
		fail 'committed cleanup failure rolled back the installed overlay'
}

test_install_prior_overlay_cleanup_failure_reports_commit_and_continues()
{
	sandbox=$workdir/install-prior-overlay-cleanup-failure
	make_sandbox "$sandbox"
	destination=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	printf '%s\n' prior-overlay-recovery > "$destination"
	prior_prefix=$sandbox/boot/.rockpi-rpi-touchscreen.overlay-backup.
	if RM_FAIL_PREFIX="$prior_prefix" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted failed prior-overlay cleanup after commit'
	fi
	grep -Fq 'installation committed, but cleanup failed:' "$sandbox/output" ||
		fail 'prior-overlay cleanup failure did not report committed installation'
	prior_recovery=$(find "$sandbox/boot" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.overlay-backup.*' -print -quit)
	[ -n "$prior_recovery" ] || fail 'prior-overlay cleanup failure discarded recovery'
	grep -Fq "prior overlay recovery retained at $prior_recovery" "$sandbox/output" ||
		fail 'prior-overlay cleanup failure did not name retained recovery'
	grep -Fxq prior-overlay-recovery "$prior_recovery" ||
		fail 'retained prior-overlay recovery bytes changed'
	[ -z "$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)" ] ||
		fail 'prior-overlay cleanup failure prevented transaction recovery cleanup'
	! grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'prior-overlay cleanup failure attempted rollback after commit'
	assert_install_remains_committed_after_cleanup_failure "$sandbox"
	printf 'PASS: prior-overlay cleanup failure reports commit and continues cleanup\n'
}

test_install_reports_every_committed_cleanup_failure()
{
	sandbox=$workdir/install-all-committed-cleanup-failures
	make_sandbox "$sandbox"
	destination=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	printf '%s\n' prior-overlay-recovery > "$destination"
	prior_prefix=$sandbox/boot/.rockpi-rpi-touchscreen.overlay-backup.
	transaction_prefix=$sandbox/usr-src/.rockpi-rpi-touchscreen.transaction.
	if RM_FAIL_PREFIX="$prior_prefix" RM_FAIL_PREFIX_SECOND="$transaction_prefix" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted both committed cleanup failures'
	fi
	grep -Fq 'installation committed, but cleanup failed:' "$sandbox/output" ||
		fail 'combined cleanup failure did not report committed installation'
	prior_recovery=$(find "$sandbox/boot" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.overlay-backup.*' -print -quit)
	transaction_recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$prior_recovery" ] || fail 'combined cleanup failure discarded prior-overlay recovery'
	[ -n "$transaction_recovery" ] || fail 'combined cleanup failure discarded transaction recovery'
	grep -Fq "prior overlay recovery retained at $prior_recovery" "$sandbox/output" ||
		fail 'combined cleanup failure omitted prior-overlay recovery path'
	grep -Fq "transaction recovery retained at $transaction_recovery" "$sandbox/output" ||
		fail 'combined cleanup failure omitted transaction recovery path'
	! grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'combined cleanup failure attempted rollback after commit'
	assert_install_remains_committed_after_cleanup_failure "$sandbox"
	printf 'PASS: installer reports every retained recovery after committed cleanup failures\n'
}

test_failed_validation_does_not_mutate_boot_configuration()
{
	sandbox=$workdir/validation-failure
	make_sandbox "$sandbox"
	before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	if run_install "$sandbox" "$sandbox/validate-fail.sh"; then
		fail 'installer accepted failed validation'
	fi
	after=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	assert_equal "$after" "$before" 'failed validation must not mutate boot configuration'
	assert_file_absent "$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	printf 'PASS: failed validation leaves boot configuration unchanged\n'
}

test_installer_requires_the_panel_specific_alias()
{
	sandbox=$workdir/panel-alias-failure
	make_sandbox "$sandbox"
	if MODINFO_PANEL_ALIAS='of:N*T*Craspits_ft5426' \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted the touch alias for the panel module'
	fi
	grep -Fq 'panel_rockpi_rpi_touchscreen built module is missing device-tree alias' "$sandbox/output" ||
		fail 'installer did not identify the panel module alias failure'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: installer requires distinct touch and panel aliases\n'
}

test_installer_requires_the_provider_specific_alias()
{
	sandbox=$workdir/provider-alias-failure
	make_sandbox "$sandbox"
	if MODINFO_PROVIDER_ALIAS='of:N*T*Craspits_ft5426' \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted the touch alias for the display compatibility provider'
	fi
	grep -Fq 'rockpi_rk3399_display_compat built module is missing device-tree alias' "$sandbox/output" ||
		fail 'installer did not identify the display compatibility provider alias failure'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: installer requires the provider-specific alias\n'
}

test_installer_rejects_built_only_dkms_status()
{
	sandbox=$workdir/built-only-status
	make_sandbox "$sandbox"
	if DKMS_NEW_STATUS_PHASE=built run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted built-only DKMS status as installed'
	fi
	grep -Fq 'DKMS did not report exact installed state' "$sandbox/output" ||
		fail 'installer did not explain the exact installed-state requirement'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko"
	assert_file_absent "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko"
	assert_file_absent "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	printf 'PASS: installer rejects added or built DKMS status as installed\n'
}

test_post_backup_failure_rolls_back_owned_assets_and_boot_configuration()
{
	sandbox=$workdir/rollback
	make_sandbox "$sandbox"
	before=$(cat "$sandbox/boot/armbianEnv.txt")
	if MV_FAIL_TARGET="$sandbox/boot/armbianEnv.txt" \
		MV_FAIL_ONCE_MARKER="$sandbox/mv-failed-once" \
		run_install "$sandbox" "$sandbox/validate-pass.sh"; then
		fail 'installer accepted failed atomic boot configuration write'
	fi
	assert_equal "$(cat "$sandbox/boot/armbianEnv.txt")" "$before" \
		'post-backup failure restores boot configuration'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: post-backup failure rolls back owned assets\n'
}

test_same_version_changed_source_is_rejected()
{
	sandbox=$workdir/immutable-source
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source_file=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6/src/display_compat.h
	printf '\n# changed source\n' >> "$source_file"
	before=$(sha256sum "$source_file" | awk '{print $1}')
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'same-version changed source was accepted'
	fi
	assert_equal "$(sha256sum "$source_file" | awk '{print $1}')" "$before" \
		'immutable same-version source was overwritten'
	grep -Fq 'same-version DKMS source differs' "$sandbox/output" ||
		fail 'source mismatch was not explained'
	printf 'PASS: same-version changed source is rejected\n'
}

test_install_owns_verified_runtime_assets()
{
	sandbox=$workdir/runtime-assets-success
	make_sandbox "$sandbox"
	output=$(run_install "$sandbox" "$sandbox/validate-pass.sh")
	assert_runtime_assets_match_source "$sandbox"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'new DKMS release did not reach exact installed state'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" '' \
		'old DKMS lifecycle unexpectedly remained'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5"
	if printf '%s\n' "$output" | grep -Eq 'rollback also failed|recovery artifacts retained'; then
		fail 'successful runtime asset installation reported rollback failure'
	fi
	printf 'PASS: installer owns verified runtime assets\n'
}

test_preexisting_unrelated_runtime_asset_blocks_before_mutation()
{
	for asset in mapper autostart lightdm; do
		sandbox=$workdir/runtime-preflight-conflict-$asset
		make_sandbox "$sandbox"
		case $asset in
		mapper) destination=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch ;;
		autostart) destination=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop ;;
		lightdm) destination=$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf ;;
		esac
		printf '%s\n' unrelated > "$destination"
		chmod 0644 "$destination"
		before=$(sha256sum "$destination" | awk '{print $1}')
		if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
			fail "installer overwrote an unrelated $asset runtime asset"
		fi
		grep -Fq 'runtime asset conflicts with project ownership' "$sandbox/output" ||
			fail "installer did not explain the $asset runtime ownership conflict"
		assert_equal "$(sha256sum "$destination" | awk '{print $1}')" "$before" \
			"preflight changed the unrelated $asset runtime asset"
		if grep -Eq '^(add|build|install|remove)( |$)' "$sandbox/dkms.log"; then
			fail "$asset runtime preflight conflict reached DKMS mutation"
		fi
		assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
		assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	done
	printf 'PASS: unrelated runtime asset blocks before mutation\n'
}

test_preexisting_wrong_runtime_mode_blocks_before_mutation()
{
	for asset in mapper autostart lightdm; do
		sandbox=$workdir/runtime-preflight-mode-$asset
		make_sandbox "$sandbox"
		case $asset in
		mapper)
			source=$repo_root/scripts/map-touchscreen.sh
			destination=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
			wrong_mode=0644
			;;
		autostart)
			source=$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop
			destination=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
			wrong_mode=0755
			;;
		lightdm)
			source=$repo_root/assets/90-rockpi-greeter-no-blank.conf
			destination=$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf
			wrong_mode=0600
			;;
		esac
		cp "$source" "$destination"
		chmod "$wrong_mode" "$destination"
		if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
			fail "installer accepted a project $asset runtime asset with the wrong mode"
		fi
		grep -Fq 'runtime asset conflicts with project ownership' "$sandbox/output" ||
			fail "installer did not explain the $asset runtime mode conflict"
		assert_equal "$(stat -c '%a' "$destination")" "${wrong_mode#0}" \
			"preflight changed the conflicting $asset runtime asset mode"
		if grep -Eq '^(add|build|install|remove)( |$)' "$sandbox/dkms.log"; then
			fail "$asset runtime mode conflict reached DKMS mutation"
		fi
		assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	done
	printf 'PASS: wrong runtime mode blocks before mutation\n'
}

test_runtime_asset_install_failure_restores_absent_baseline()
{
	sandbox=$workdir/runtime-install-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	capture_migration_baseline "$sandbox"
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	if LN_FAIL_BEFORE_TARGET="$autostart" LN_FAIL_BEFORE_TARGET_MARKER="$sandbox/runtime-link-failed" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted runtime asset installation failure'
	fi
	[ -f "$sandbox/runtime-link-failed" ] || fail 'runtime failure injection was not reached'
	grep -Fq 'touch autostart installation failed' "$sandbox/output" ||
		fail 'installer did not report the runtime asset installation failure'
	assert_file_absent "$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch"
	assert_file_absent "$autostart"
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	printf 'PASS: runtime asset install failure restores absent baseline\n'
}

test_second_runtime_asset_mutate_then_fail_restores_absent_baseline()
{
	sandbox=$workdir/runtime-second-asset-mutate-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	capture_migration_baseline "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	if LN_FAIL_AFTER_TARGET="$autostart" \
		LN_FAIL_AFTER_TARGET_MARKER="$sandbox/runtime-link-failed-after" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a second runtime publication that mutated before failing'
	fi
	[ -f "$sandbox/runtime-link-failed-after" ] ||
		fail 'second runtime publication mutate-then-error injection was not reached'
	cmp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$autostart" ||
		fail 'ambiguous autostart publication discarded or changed the held object'
	assert_equal "$(stat -c '%a' "$autostart")" '644' \
		'ambiguous autostart publication changed the held mode'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'ambiguous autostart publication stranded it without the mapper dependency'
	grep -Fq "ambiguous touch autostart publication retained at $autostart" "$sandbox/output" ||
		fail 'installer did not report the ambiguous autostart destination'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'ambiguous runtime publication did not retain recovery'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'ambiguous runtime publication discarded transaction recovery'
	printf 'PASS: mutate-then-error runtime publication retains exact objects and named recovery\n'
}

test_runtime_publication_collisions_preserve_exact_raced_objects()
{
	for asset in mapper autostart; do
		sandbox=$workdir/runtime-publication-collision-$asset
		make_sandbox "$sandbox"
		mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
		autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
		case $asset in
		mapper) destination=$mapper ;;
		autostart) destination=$autostart ;;
		esac
		if LN_CREATE_FILE_BEFORE_TARGET="$destination" \
			run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
			fail "installer accepted a raced $asset publication"
		fi
		grep -Fqx 'raced-runtime-asset' "$destination" ||
			fail "installer overwrote raced $asset bytes"
		assert_equal "$(stat -c '%a' "$destination")" '600' \
			"installer changed raced $asset mode"
		grep -Fq "runtime asset appeared during publication: $destination" "$sandbox/output" ||
			fail "installer did not report raced $asset publication"
		if [ "$asset" = autostart ]; then
			cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
				fail 'raced autostart publication stranded it without mapper dependency'
			grep -Fq "touch mapper retained because touch autostart remains: $mapper" \
				"$sandbox/output" || fail 'raced autostart did not report retained mapper dependency'
		fi
	done
	printf 'PASS: first and second publication collisions preserve exact raced objects\n'
}

test_runtime_publication_preserves_symlink_and_directory_collisions()
{
	for kind in symlink directory; do
		sandbox=$workdir/runtime-publication-type-$kind
		make_sandbox "$sandbox"
		mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
		case $kind in
		symlink)
			if LN_CREATE_SYMLINK_BEFORE_TARGET="$mapper" \
				LN_CREATE_SYMLINK_VALUE=/tmp/local-mapper \
				run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
				fail 'installer accepted a raced mapper symlink'
			fi
			[ -L "$mapper" ] || fail 'installer replaced raced mapper symlink type'
			assert_equal "$(readlink "$mapper")" /tmp/local-mapper \
				'installer changed raced mapper symlink target'
			;;
		directory)
			if LN_CREATE_DIRECTORY_BEFORE_TARGET="$mapper" \
				run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
				fail 'installer accepted a raced mapper directory'
			fi
			[ -d "$mapper" ] && [ ! -L "$mapper" ] ||
				fail 'installer replaced raced mapper directory type'
			;;
		esac
		grep -Fq "runtime asset appeared during publication: $mapper" "$sandbox/output" ||
			fail "installer did not report raced mapper $kind"
	done
	printf 'PASS: runtime publication preserves raced symlink and directory types\n'
}

test_publication_identity_is_propagated_from_verified_boundary()
{
	sandbox=$workdir/runtime-publication-identity-boundary
	make_sandbox "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	config=$sandbox/boot/armbianEnv.txt
	identity_file=$sandbox/replacement.identity
	if RM_REPLACE_PUBLICATION_TEMP_PREFIX="$sandbox/usr-libexec/.rockpi-rpi-touchscreen.publish." \
		RM_REPLACE_PUBLICATION_DESTINATION="$mapper" \
		RM_REPLACE_PUBLICATION_SOURCE="$repo_root/scripts/map-touchscreen.sh" \
		RM_REPLACE_PUBLICATION_MODE=0755 \
		RM_REPLACE_PUBLICATION_IDENTITY_FILE="$identity_file" \
		RM_REPLACE_PUBLICATION_MARKER="$sandbox/mapper-replaced-after-boundary" \
		MV_FAIL_AFTER_TARGET="$config" MV_FAIL_AFTER_ONCE_MARKER="$sandbox/boot-failed-after" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a late failure after the publication identity race'
	fi
	[ -f "$sandbox/mapper-replaced-after-boundary" ] && [ -s "$identity_file" ] ||
		fail 'publication identity regression did not replace the mapper after helper verification'
	[ -f "$mapper" ] && [ ! -L "$mapper" ] ||
		fail 'rollback deleted or changed the exact-byte replacement mapper type'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'rollback changed the exact-byte replacement mapper'
	assert_equal "$(stat -c '%a' "$mapper")" 755 \
		'rollback changed the exact-byte replacement mapper mode'
	assert_equal "$(stat -c '%d:%i:%f' "$mapper")" "$(cat "$identity_file")" \
		'rollback did not preserve the replacement inode from after helper verification'
	grep -Fqx "RETAIN MODIFIED: $mapper" "$sandbox/output" ||
		fail 'rollback did not classify the replacement inode as locally owned'
	grep -Fq "touch mapper retained at $mapper" "$sandbox/output" ||
		fail 'rollback did not report the exact replacement mapper recovery path'
	printf 'PASS: publication ownership propagates the helper-verified destination identity\n'
}

test_install_rollback_retains_post_publication_local_edit()
{
	sandbox=$workdir/runtime-post-publication-edit
	make_sandbox "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	config=$sandbox/boot/armbianEnv.txt
	if MV_CORRUPT_FILE_AFTER_TARGET="$mapper" MV_CORRUPT_FILE_TRIGGER="$config" \
		MV_FAIL_AFTER_TARGET="$config" MV_FAIL_AFTER_ONCE_MARKER="$sandbox/boot-failed-after" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a late failure after a local mapper edit'
	fi
	grep -Fqx 'corrupt-runtime-asset' "$mapper" ||
		fail 'install rollback deleted or changed the post-publication mapper edit'
	assert_equal "$(stat -c '%a' "$mapper")" '755' \
		'install rollback changed post-publication mapper mode'
	assert_file_absent "$autostart"
	grep -Fq "RETAIN MODIFIED: $mapper" "$sandbox/output" ||
		fail 'install rollback did not report the retained local mapper edit'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'retained local mapper edit did not keep transaction recovery'
	printf 'PASS: install rollback retains and reports a post-publication local edit\n'
}

test_install_failed_claim_move_retains_edited_recovery()
{
	sandbox=$workdir/install-failed-edited-claim
	make_sandbox "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	config=$sandbox/boot/armbianEnv.txt
	if MV_CORRUPT_FILE_AFTER_TARGET="$mapper" MV_CORRUPT_FILE_TRIGGER="$config" \
		MV_CORRUPT_FILE_AFTER_ONCE_MARKER="$sandbox/mapper-locally-edited" \
		MV_CORRUPT_FILE_CONTENT=local-byte-edit-before-failed-claim \
		MV_CORRUPT_FILE_MODE=0700 \
		MV_FAIL_AFTER_TARGET="$config" MV_FAIL_AFTER_ONCE_MARKER="$sandbox/boot-failed-after" \
		MV_FAIL_AFTER_SOURCE="$mapper" \
		MV_FAIL_AFTER_SOURCE_MARKER="$sandbox/mapper-claim-failed-after" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a failed rollback claim after a local mapper edit'
	fi
	[ -f "$sandbox/mapper-locally-edited" ] && [ -f "$sandbox/mapper-claim-failed-after" ] ||
		fail 'install claim regression did not reach both edit and rename-then-error boundaries'
	claim=$(find "$sandbox/usr-libexec" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.rollback.mapper.*' -print -quit)
	[ -n "$claim" ] || fail 'failed install claim move discarded the locally edited mapper recovery'
	[ -f "$claim" ] && [ ! -L "$claim" ] ||
		fail 'failed install claim move changed the edited mapper regular-file type'
	assert_equal "$(cat "$claim")" local-byte-edit-before-failed-claim \
		'failed install claim move changed the edited mapper bytes'
	assert_equal "$(stat -c '%a' "$claim")" 700 \
		'failed install claim move changed the edited mapper mode'
	grep -Fq "recovery retained at $claim" "$sandbox/output" ||
		fail 'install rollback did not report the exact edited mapper recovery path'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'ambiguous install claim did not retain transaction recovery'
	printf 'PASS: failed install claim move retains exact edited bytes, type, mode, and path\n'
}

test_late_failure_removes_new_runtime_assets()
{
	sandbox=$workdir/runtime-late-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	capture_migration_baseline "$sandbox"
	config=$sandbox/boot/armbianEnv.txt
	if MV_FAIL_TARGET="$config" MV_FAIL_ONCE_MARKER="$sandbox/boot-mv-failed" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted failure after runtime asset installation'
	fi
	[ -f "$sandbox/boot-mv-failed" ] || fail 'late failure injection was not reached'
	assert_file_absent "$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch"
	assert_file_absent "$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop"
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	printf 'PASS: late failure removes newly installed runtime assets\n'
}

test_runtime_asset_checksum_failure_retains_recovery()
{
	sandbox=$workdir/runtime-checksum-failure
	make_sandbox "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	if LN_CORRUPT_FILE_AFTER_TARGET="$mapper" LN_CORRUPT_FILE_TRIGGER="$autostart" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a corrupted runtime asset'
	fi
	grep -Fq 'installed touch mapper checksum verification failed' "$sandbox/output" ||
		fail 'installer did not report runtime checksum failure'
	grep -Fq "touch mapper retained at $mapper" "$sandbox/output" ||
		fail 'rollback did not report retained runtime asset'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'runtime rollback failure did not fail closed'
	[ -f "$mapper" ] || fail 'failed runtime rollback discarded the retained asset'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'runtime rollback failure discarded recovery artifacts'
	grep -Fq "recovery artifacts retained at $recovery" "$sandbox/output" ||
		fail 'runtime rollback failure did not report the recovery directory'
	printf 'PASS: runtime checksum failure retains and reports recovery\n'
}

test_autostart_rollback_failure_retains_mapper_dependency_and_recovery()
{
	sandbox=$workdir/runtime-autostart-removal-failure
	make_sandbox "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	config=$sandbox/boot/armbianEnv.txt
	if MV_FAIL_TARGET="$config" MV_FAIL_ONCE_MARKER="$sandbox/boot-mv-failed" \
		RM_FAIL_PREFIX="$sandbox/etc/xdg/autostart/.rockpi-rpi-touchscreen.rollback.autostart." \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted autostart rollback removal failure'
	fi
	[ -f "$sandbox/boot-mv-failed" ] || fail 'late rollback injection was not reached'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'autostart removal failure did not retain its mapper dependency'
	claim=$(find "$sandbox/etc/xdg/autostart" -maxdepth 1 -type f \
		-name '.rockpi-rpi-touchscreen.rollback.autostart.*' -print -quit)
	[ -n "$claim" ] || fail 'failed autostart removal did not retain a recoverable claim'
	cmp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$claim" ||
		fail 'failed autostart removal changed the held claim'
	assert_equal "$(stat -c '%a' "$mapper")" '755' \
		'autostart removal failure changed retained mapper mode'
	assert_equal "$(stat -c '%a' "$claim")" '644' \
		'autostart removal failure changed retained claim mode'
	grep -Fq "touch autostart removal failed: $autostart" "$sandbox/output" ||
		fail 'rollback did not report the retained autostart'
	grep -Fq "recovery retained at $claim" "$sandbox/output" ||
		fail 'rollback did not name the recoverable autostart claim'
	grep -Fq "touch mapper retained because touch autostart remains: $mapper" "$sandbox/output" ||
		fail 'rollback did not report the retained mapper dependency'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'autostart rollback failure did not fail closed'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'autostart rollback failure discarded recovery artifacts'
	grep -Fq "recovery artifacts retained at $recovery" "$sandbox/output" ||
		fail 'autostart rollback failure did not report recovery artifacts'
	printf 'PASS: autostart rollback failure retains mapper dependency and recovery\n'
}

test_initial_runtime_verification_blocks_boot_mutation()
{
	sandbox=$workdir/runtime-pre-boot-verification
	make_sandbox "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	config=$sandbox/boot/armbianEnv.txt
	if LN_CORRUPT_FILE_AFTER_TARGET="$mapper" LN_CORRUPT_FILE_TRIGGER="$autostart" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted mapper corruption before boot mutation'
	fi
	grep -Fq 'installed touch mapper checksum verification failed' "$sandbox/output" ||
		fail 'initial runtime verification did not report mapper corruption'
	if awk -v target="$config" '$NF == target { found = 1 } END { exit found ? 0 : 1 }' \
		"$sandbox/mv.log"; then
		fail 'initial runtime verification allowed boot configuration mutation'
	fi
	printf 'PASS: initial runtime verification blocks boot mutation\n'
}

test_final_runtime_verification_blocks_old_retirement()
{
	sandbox=$workdir/runtime-post-boot-verification
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	config=$sandbox/boot/armbianEnv.txt
	retirement_marker=$sandbox/old-retirement-attempted
	if MV_CORRUPT_FILE_TRIGGER="$config" MV_CORRUPT_FILE_AFTER_TARGET="$mapper" \
		DKMS_OLD_RETIREMENT_ATTEMPT_MARKER="$retirement_marker" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted mapper corruption after boot mutation'
	fi
	grep -Fq 'final installed touch mapper checksum verification failed' "$sandbox/output" ||
		fail 'final runtime verification did not report post-boot mapper corruption'
	awk -v target="$config" '$NF == target { found = 1 } END { exit found ? 0 : 1 }' \
		"$sandbox/mv.log" || fail 'post-boot corruption injection was not reached'
	assert_file_absent "$retirement_marker"
	printf 'PASS: final runtime verification blocks old retirement\n'
}

test_rollback_preserves_preexisting_exact_runtime_assets()
{
	sandbox=$workdir/runtime-preexisting-rollback
	make_sandbox "$sandbox"
	mapper=$sandbox/usr-libexec/rockpi-rpi-touchscreen-map-touch
	autostart=$sandbox/etc/xdg/autostart/rockpi-rpi-touchscreen-touch-map.desktop
	lightdm=$sandbox/etc/lightdm/lightdm.conf.d/90-rockpi-greeter-no-blank.conf
	cp "$repo_root/scripts/map-touchscreen.sh" "$mapper"
	cp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$autostart"
	cp "$repo_root/assets/90-rockpi-greeter-no-blank.conf" "$lightdm"
	chmod 0755 "$mapper"
	chmod 0644 "$autostart" "$lightdm"
	seed_old_release "$sandbox"
	capture_migration_baseline "$sandbox"
	if DKMS_FAIL_OLD_REMOVE_AFTER_MUTATION=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted injected old retirement failure'
	fi
	[ -f "$sandbox/dkms-old-remove-failed.marker" ] ||
		fail 'preexisting-runtime rollback did not reach the late failure'
	cmp "$repo_root/scripts/map-touchscreen.sh" "$mapper" ||
		fail 'rollback removed or changed the preexisting mapper'
	cmp "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" "$autostart" ||
		fail 'rollback removed or changed the preexisting autostart'
	cmp "$repo_root/assets/90-rockpi-greeter-no-blank.conf" "$lightdm" ||
		fail 'rollback removed or changed the preexisting LightDM policy'
	assert_equal "$(stat -c '%a' "$mapper")" '755' 'rollback changed preexisting mapper mode'
	assert_equal "$(stat -c '%a' "$autostart")" '644' 'rollback changed preexisting autostart mode'
	assert_equal "$(stat -c '%a' "$lightdm")" '644' 'rollback changed preexisting LightDM policy mode'
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	printf 'PASS: rollback preserves preexisting exact runtime assets\n'
}

test_changed_dtbo_is_transactionally_refreshed()
{
	sandbox=$workdir/dtbo-refresh
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	destination=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	printf '%s\n' stale > "$destination"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	cmp "$sandbox/build/rockpi-4b-plus-rpi-touchscreen.dtbo" "$destination" ||
		fail 'changed installed DTBO was not refreshed'
	printf 'PASS: changed DTBO is transactionally refreshed\n'
}

test_dkms_source_package_is_allowlisted()
{
	sandbox=$workdir/source-allowlist
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
	actual=$(cd "$source" && find . -type f -print | LC_ALL=C sort)
expected='./LICENSE
./LICENSES/GPL-2.0-only.txt
./LICENSES/UPSTREAM.md
./Makefile
./assets/90-rockpi-greeter-no-blank.conf
./assets/rockpi-rpi-touchscreen-touch-map.desktop
./dkms.conf
./scripts/dkms-make.sh
./scripts/map-touchscreen.sh
./src/display_compat.h
./src/display_compat_core.c
./src/display_compat_core.h
./src/display_compat_main.c
./src/ft5426_protocol.h
./src/panel_rockpi_rpi_touchscreen.c
./src/raspits_ft5426.c'
	assert_equal "$actual" "$expected" 'DKMS source package contains only allowlisted files'
	assert_equal "$(stat -c '%a' "$source")" '755' 'DKMS source root must be traversable'
	assert_equal "$(stat -c '%a' "$source/src")" '755' 'DKMS source subdirectories must be traversable'
	expected_digest_args='ARGS=Makefile dkms.conf src/ft5426_protocol.h src/raspits_ft5426.c src/panel_rockpi_rpi_touchscreen.c src/display_compat.h src/display_compat_core.h src/display_compat_core.c src/display_compat_main.c scripts/dkms-make.sh scripts/map-touchscreen.sh assets/rockpi-rpi-touchscreen-touch-map.desktop assets/90-rockpi-greeter-no-blank.conf LICENSE LICENSES/GPL-2.0-only.txt LICENSES/UPSTREAM.md'
	grep -F "$expected_digest_args" "$sandbox/sha256.log" >/dev/null ||
		fail 'DKMS source digest does not cover every packaged source and runtime asset'
	printf 'PASS: DKMS source package allowlist\n'
}

test_boot_rollback_failure_continues_cleanup_and_preserves_backup()
{
	sandbox=$workdir/rollback-replacement-failure
	make_sandbox "$sandbox"
	config=$sandbox/boot/armbianEnv.txt
	output=$sandbox/output
	if MV_FAIL_ALWAYS_TARGET="$config" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'rollback boot-config replacement failure was accepted'
	fi
	[ -f "$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak" ] ||
		fail 'rollback did not retain the exact recovery backup'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	grep -Fq 'boot configuration backup retained at' "$output" ||
		fail 'rollback replacement failure was not reported'
	printf 'PASS: rollback replacement failure preserves recovery and continues cleanup\n'
}

test_uninstall_dkms_failure_retains_source_and_fails()
{
	sandbox=$workdir/uninstall-dkms-failure
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	output=$sandbox/output
	config_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	dtbo=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	dtbo_before=$(sha256sum "$dtbo" | awk '{print $1}')
	if DKMS_REMOVE_GENUINE_FAIL=1 run_uninstall "$sandbox" > "$output" 2>&1; then
		fail 'uninstall accepted genuine DKMS removal failure'
	fi
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" ] ||
		fail 'uninstall removed source after genuine DKMS failure'
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$config_before" \
		'DKMS removal failure changed boot configuration'
	assert_equal "$(sha256sum "$dtbo" | awk '{print $1}')" "$dtbo_before" \
		'DKMS removal failure changed DTBO'
	! grep -Fq 'PASS: removed' "$output" ||
		fail 'uninstall printed success after genuine DKMS failure'
	printf 'PASS: genuine DKMS uninstall failure retains source and fails\n'
}

test_uninstall_dkms_status_failure_leaves_all_assets()
{
	sandbox=$workdir/uninstall-status-failure
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	config_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	dtbo=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	dtbo_before=$(sha256sum "$dtbo" | awk '{print $1}')
	if DKMS_STATUS_FAIL_VERSION=0.2.6 run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted DKMS status failure'
	fi
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" ] || fail 'status failure removed source'
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$config_before" \
		'DKMS status failure changed boot configuration'
	assert_equal "$(sha256sum "$dtbo" | awk '{print $1}')" "$dtbo_before" \
		'DKMS status failure changed DTBO'
	printf 'PASS: DKMS status failure leaves all uninstall assets unchanged\n'
}

assert_failed_uninstall_restored()
{
	sandbox=$1
	config_checksum=$2
	dtbo_checksum=$3
	dtbo=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	if grep -Eq 'rollback also failed|recovery artifacts retained' "$sandbox/output"; then
		fail 'ordinary uninstall failure did not complete a clean rollback'
	fi
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$config_checksum" \
		'post-removal uninstall failure did not restore boot configuration'
	assert_equal "$(sha256sum "$dtbo" | awk '{print $1}')" "$dtbo_checksum" \
		'post-removal uninstall failure did not restore DTBO'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6/dkms.conf" ] ||
		fail 'post-removal uninstall failure did not restore source'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'post-removal uninstall failure did not restore exact DKMS lifecycle'
	assert_equal "$(cat "$sandbox/dkms-active.state")" '6.18.43-current-rockchip64|0.2.6' \
		'post-removal uninstall failure did not restore active version'
	assert_module_matches_build "$sandbox" 0.2.6 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.6 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.6 raspits_ft5426
}

prepare_uninstall_failure()
{
	sandbox=$1
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	UNINSTALL_CONFIG_CHECKSUM=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	UNINSTALL_DTBO_CHECKSUM=$(sha256sum "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" | awk '{print $1}')
}

test_uninstall_post_remove_status_failure_restores_transaction()
{
	sandbox=$workdir/uninstall-post-remove-status-failure
	prepare_uninstall_failure "$sandbox"
	if DKMS_STATUS_FAIL_AFTER_REMOVE=1 run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted post-removal status failure'
	fi
	assert_failed_uninstall_restored "$sandbox" "$UNINSTALL_CONFIG_CHECKSUM" "$UNINSTALL_DTBO_CHECKSUM"
	printf 'PASS: post-removal status failure restores uninstall transaction\n'
}

test_uninstall_remove_mutate_then_fail_restores_transaction()
{
	sandbox=$workdir/uninstall-remove-mutate-failure
	prepare_uninstall_failure "$sandbox"
	if DKMS_FAIL_ON=remove run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a DKMS removal that mutated state before failing'
	fi
	assert_failed_uninstall_restored "$sandbox" "$UNINSTALL_CONFIG_CHECKSUM" "$UNINSTALL_DTBO_CHECKSUM"
	printf 'PASS: mutate-then-fail DKMS removal restores uninstall transaction\n'
}

test_uninstall_each_module_remove_failure_restores_transaction()
{
	for module in rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426; do
		sandbox=$workdir/uninstall-remove-$module-failure
		prepare_uninstall_failure "$sandbox"
		if DKMS_FAIL_REMOVE_MODULE=$module run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
			fail "uninstall accepted partial removal failure for $module"
		fi
		assert_failed_uninstall_restored "$sandbox" "$UNINSTALL_CONFIG_CHECKSUM" "$UNINSTALL_DTBO_CHECKSUM"
		if grep -Fq 'rollback also failed' "$sandbox/output"; then
			fail "uninstall $module removal failure did not roll back cleanly"
		fi
	done
	printf 'PASS: every partial module removal failure restores uninstall transaction\n'
}

test_uninstall_boot_config_failure_restores_transaction()
{
	sandbox=$workdir/uninstall-boot-config-failure
	prepare_uninstall_failure "$sandbox"
	if MV_FAIL_TARGET="$sandbox/boot/armbianEnv.txt" MV_FAIL_ONCE_MARKER="$sandbox/uninstall-config-failed" \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted boot configuration mutation failure'
	fi
	assert_failed_uninstall_restored "$sandbox" "$UNINSTALL_CONFIG_CHECKSUM" "$UNINSTALL_DTBO_CHECKSUM"
	printf 'PASS: boot configuration failure restores uninstall transaction\n'
}

test_uninstall_dtbo_failure_restores_transaction()
{
	sandbox=$workdir/uninstall-dtbo-failure
	prepare_uninstall_failure "$sandbox"
	dtbo=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	if RM_FAIL_TARGET="$dtbo" run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted DTBO mutation failure'
	fi
	assert_failed_uninstall_restored "$sandbox" "$UNINSTALL_CONFIG_CHECKSUM" "$UNINSTALL_DTBO_CHECKSUM"
	printf 'PASS: DTBO failure restores uninstall transaction\n'
}

test_uninstall_source_failure_restores_transaction()
{
	sandbox=$workdir/uninstall-source-failure
	prepare_uninstall_failure "$sandbox"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
	if MV_FAIL_SOURCE="$source" run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted source mutation failure'
	fi
	assert_failed_uninstall_restored "$sandbox" "$UNINSTALL_CONFIG_CHECKSUM" "$UNINSTALL_DTBO_CHECKSUM"
	printf 'PASS: source failure restores uninstall transaction\n'
}

test_shared_uninstall_assertion_rejects_rollback_failure_output()
{
	sandbox=$workdir/uninstall-assertion-output-probe
	prepare_uninstall_failure "$sandbox"
	printf '%s\n' 'ERROR: transaction failed; rollback also failed: injected probe' > "$sandbox/output"
	if (assert_failed_uninstall_restored "$sandbox" "$UNINSTALL_CONFIG_CHECKSUM" \
		"$UNINSTALL_DTBO_CHECKSUM" > "$sandbox/assertion-output" 2>&1); then
		fail 'shared uninstall assertion accepted rollback-failure output'
	fi
	grep -Fq 'ordinary uninstall failure did not complete a clean rollback' \
		"$sandbox/assertion-output" || fail 'shared uninstall assertion did not reject rollback-failure output'
	printf 'PASS: shared uninstall assertion rejects rollback-failure output\n'
}

test_uninstall_accepts_unregistered_dkms()
{
	sandbox=$workdir/uninstall-unregistered
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	rm -f "$sandbox/dkms-added.state" "$sandbox/dkms-built.state" \
		"$sandbox/dkms-installed.state" "$sandbox/dkms-active.state"
	run_uninstall "$sandbox"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	printf 'PASS: uninstall accepts already-unregistered DKMS package\n'
}

test_uninstall_refuses_unowned_unregistered_source()
{
	sandbox=$workdir/uninstall-unowned-source
	make_sandbox "$sandbox"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
	mkdir -p "$source"
	printf '%s\n' 'PACKAGE_NAME="some-other-package"' 'PACKAGE_VERSION="0.2.6"' > "$source/dkms.conf"
	if run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall deleted an unowned unregistered source path'
	fi
	[ -f "$source/dkms.conf" ] || fail 'uninstall removed unowned source contents'
	grep -Fq 'source path is not owned by this project' "$sandbox/output" ||
		fail 'uninstall did not explain the ownership mismatch'
	printf 'PASS: uninstall refuses unowned unregistered source\n'
}

seed_old_release()
{
	sandbox=$1
	old=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5
	mkdir -p "$old/src" "$old/scripts" "$old/assets" "$old/LICENSES"
	chmod 0755 "$old" "$old/src" "$old/scripts" "$old/assets" "$old/LICENSES"
	cat > "$old/dkms.conf" <<'EOF'
PACKAGE_NAME="rockpi-rpi-touchscreen"
PACKAGE_VERSION="0.2.5"
BUILT_MODULE_NAME[0]="rockpi_rk3399_display_compat"
BUILT_MODULE_LOCATION[0]="."
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="panel_rockpi_rpi_touchscreen"
BUILT_MODULE_LOCATION[1]="."
DEST_MODULE_LOCATION[1]="/updates/dkms"
BUILT_MODULE_NAME[2]="raspits_ft5426"
BUILT_MODULE_LOCATION[2]="."
DEST_MODULE_LOCATION[2]="/updates/dkms"
MAKE[0]="'sh' scripts/dkms-make.sh ${kernelver} make KDIR=/lib/modules/${kernelver}/build modules"
CLEAN="make KDIR=/lib/modules/${kernelver}/build clean"
BUILD_EXCLUSIVE_KERNEL="^6[.]18[.]43-current-rockchip64$"
AUTOINSTALL="yes"
EOF
	chmod 0644 "$old/dkms.conf"
	/usr/bin/install -m 0644 "$repo_root/LICENSE" "$old/"
	cat > "$old/Makefile" <<'EOF'
ifneq ($(KERNELRELEASE),)
obj-m += raspits_ft5426.o
raspits_ft5426-y := src/raspits_ft5426.o
obj-m += panel_rockpi_rpi_touchscreen.o
panel_rockpi_rpi_touchscreen-y := src/panel_rockpi_rpi_touchscreen.o
obj-m += rockpi_rk3399_display_compat.o
rockpi_rk3399_display_compat-y := src/display_compat_main.o src/display_compat_core.o
else
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

.PHONY: all modules clean test

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

test:
	cc -std=c11 -Wall -Wextra -Werror -I. tests/test_protocol.c -o /tmp/test_ft5426
	/tmp/test_ft5426
	cc -std=c11 -Wall -Wextra -Werror -I. tests/test_display_compat.c src/display_compat_core.c -o /tmp/test_display_compat
	/tmp/test_display_compat
	sh tests/test_touch_mapper.sh
	sh tests/test_driver_lifecycle.sh
	sh tests/test_panel_lifecycle.sh
	sh tests/test_display_compat_lifecycle.sh
	sh tests/test_overlay.sh
	sh tests/test_scripts.sh
	sh tests/test_dkms.sh
	sh tests/test_validate.sh
	sh tests/test_docs.sh
endif
EOF
	chmod 0644 "$old/Makefile"
	/usr/bin/install -m 0644 "$repo_root/LICENSES/GPL-2.0-only.txt" \
		"$repo_root/LICENSES/UPSTREAM.md" "$old/LICENSES/"
	/usr/bin/install -m 0644 "$repo_root/src/ft5426_protocol.h" \
		"$repo_root/src/raspits_ft5426.c" \
		"$repo_root/src/panel_rockpi_rpi_touchscreen.c" \
		"$repo_root/src/display_compat.h" "$repo_root/src/display_compat_core.h" \
		"$repo_root/src/display_compat_core.c" "$repo_root/src/display_compat_main.c" \
		"$old/src/"
	/usr/bin/install -m 0755 "$repo_root/scripts/map-touchscreen.sh" "$old/scripts/"
	/usr/bin/install -m 0644 "$repo_root/assets/rockpi-rpi-touchscreen-touch-map.desktop" \
		"$old/assets/"
	cat > "$old/scripts/dkms-make.sh" <<'EOF'
#!/bin/sh
set -eu

[ "$#" -ge 2 ] || {
	printf 'ERROR: usage: %s KERNEL_RELEASE COMMAND [ARG ...]\n' "$0" >&2
	exit 1
}

kernel_release=$1
shift
supported_kernel_release=6.18.43-current-rockchip64
[ "$kernel_release" = "$supported_kernel_release" ] || {
	printf 'ERROR: unsupported kernel release: %s (expected %s)\n' \
		"$kernel_release" "$supported_kernel_release" >&2
	exit 1
}
kernel_build=${MODULES_DIR:-/lib/modules}/$kernel_release/build
compiler_config=$kernel_build/include/generated/autoconf.h
compiler_header=$kernel_build/include/generated/compile.h
kernel_compiler_banner=

if [ -r "$compiler_config" ]; then
	kernel_compiler_banner=$(awk -F '"' '/^[[:space:]]*#define[[:space:]]+CONFIG_CC_VERSION_TEXT[[:space:]]+/ { print $2; exit }' "$compiler_config")
fi
if [ -z "$kernel_compiler_banner" ] && [ -r "$compiler_header" ]; then
	kernel_compiler_banner=$(awk -F '"' '/^[[:space:]]*#define[[:space:]]+LINUX_COMPILER[[:space:]]+/ { sub(/, GNU ld .*/, "", $2); print $2; exit }' "$compiler_header")
fi
[ -n "$kernel_compiler_banner" ] || {
	"$@"
	exit $?
}

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
command -v "$compiler_candidate" >/dev/null 2>&1 || {
	printf 'ERROR: kernel compiler is not available: %s\n' "$compiler_candidate" >&2
	exit 1
}
compiler_candidate=$(command -v "$compiler_candidate")
compiler_banner=$("$compiler_candidate" --version 2>/dev/null | sed -n '1p')
if [ "$compiler_banner" != "$kernel_compiler_banner" ] && [ -z "${MODULE_CC:-}" ] &&
	[ -n "$kernel_compiler_major" ] && command -v "$kernel_compiler_name-$kernel_compiler_major" >/dev/null 2>&1; then
	compiler_candidate=$(command -v "$kernel_compiler_name-$kernel_compiler_major")
fi

workdir=$(mktemp -d)
cleanup()
{
	rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM
compiler_directory=$workdir/module-compiler
mkdir "$compiler_directory"
ln -s "$compiler_candidate" "$compiler_directory/$kernel_compiler_name"
compiler_banner=$("$compiler_directory/$kernel_compiler_name" --version 2>/dev/null | sed -n '1p')
[ "$compiler_banner" = "$kernel_compiler_banner" ] || {
	printf 'ERROR: no compiler matches the kernel banner: %s (set MODULE_CC to a matching compiler)\n' "$kernel_compiler_banner" >&2
	exit 1
}

"$@" "CC=$compiler_directory/$kernel_compiler_name"
EOF
	chmod 0755 "$old/scripts/dkms-make.sh"
	printf '%s\n' '0.2.5' > "$sandbox/dkms-added.state"
	printf '%s\n' '0.2.5|6.18.43-current-rockchip64|aarch64' > "$sandbox/dkms-built.state"
	printf '%s\n' '0.2.5|6.18.43-current-rockchip64|aarch64' > "$sandbox/dkms-installed.state"
	printf '%s\n' '6.18.43-current-rockchip64|0.2.5' > "$sandbox/dkms-active.state"
	mkdir -p "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module" \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms"
	printf '%s\n' 'old-provider-module' > \
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/rockpi_rk3399_display_compat.ko"
	printf '%s\n' 'old-panel-module' > \
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/panel_rockpi_rpi_touchscreen.ko"
	printf '%s\n' 'old-touch-module' > \
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/raspits_ft5426.ko"
	cp "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/rockpi_rk3399_display_compat.ko" \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko"
	cp "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/panel_rockpi_rpi_touchscreen.ko" \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	cp "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/raspits_ft5426.ko" \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko"
	printf '%s\n' 'prior-dtbo' > "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	refresh_dependency_indexes "$sandbox"
}

compress_old_release_artifacts()
{
	sandbox=$1
	for module in rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426; do
		built=$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/$module.ko
		installed=$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/$module.ko
		xz -c "$built" > "$built.xz"
		gzip -c "$installed" > "$installed.gz"
		rm -f "$built" "$installed"
	done
	refresh_dependency_indexes "$sandbox"
}

source_tree_digest()
{
	(
		cd "$1"
		find . -type f -print | LC_ALL=C sort | while IFS= read -r source_file; do
			/usr/bin/sha256sum "$source_file"
		done | /usr/bin/sha256sum | awk '{print $1}'
	)
}

mutate_source_ownership_fixture()
{
	source=$1
	variant=$2
	case $variant in
	extra)
		printf '%s\n' local-extra > "$source/local-extra"
		;;
	byte)
		printf '#' >> "$source/Makefile"
		;;
	modified)
		printf '%s\n' local-modification >> "$source/src/display_compat_core.c"
		;;
	mode)
		chmod 0600 "$source/Makefile"
		;;
	symlink)
		rm -f "$source/src/display_compat.h"
		ln -s /tmp/local-display-compat.h "$source/src/display_compat.h"
		;;
	*) fail "unknown source ownership mutation: $variant" ;;
	esac
}

assert_source_ownership_mutation_survives()
{
	source=$1
	variant=$2
	case $variant in
	extra)
		grep -Fxq local-extra "$source/local-extra" ||
			fail 'source ownership check lost an extra file'
		;;
	byte)
		assert_equal "$(tail -c 1 "$source/Makefile")" '#' \
			'source ownership check changed a one-byte Makefile edit'
		;;
	modified)
		grep -Fxq local-modification "$source/src/display_compat_core.c" ||
			fail 'source ownership check lost a modified file'
		;;
	mode)
		assert_equal "$(stat -c '%a' "$source/Makefile")" 600 \
			'source ownership check changed a local mode'
		;;
	symlink)
		[ -L "$source/src/display_compat.h" ] ||
			fail 'source ownership check changed a local symlink type'
		assert_equal "$(readlink "$source/src/display_compat.h")" \
			/tmp/local-display-compat.h 'source ownership check changed a local symlink target'
		;;
	esac
}

test_install_accepts_exact_deployed_old_source_baseline()
{
	sandbox=$workdir/install-deployed-old-source-baseline
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	old=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5
	assert_equal "$(/usr/bin/sha256sum "$old/Makefile" | awk '{print $1}')" \
		109f548f08c67f11415ac9d5e4a9217c95b1138e9153c41b6400653ba1ef9d55 \
		'deployed 0.2.5 fixture Makefile bytes do not match commit 20c9247'
	if ! run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		cat "$sandbox/output" >&2
		fail 'migration preflight rejected the exact deployed 0.2.5 source baseline'
	fi
	assert_file_absent "$old"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" '' \
		'exact deployed old source remained registered after migration'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'exact deployed old source did not migrate to installed 0.2.6'
	printf 'PASS: migration accepts exact deployed 0.2.5 source baseline\n'
}

test_install_requires_exact_old_source_ownership()
{
	for variant in extra byte mode symlink; do
		sandbox=$workdir/install-old-source-ownership-$variant
		make_sandbox "$sandbox"
		seed_old_release "$sandbox"
		old=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5
		mutate_source_ownership_fixture "$old" "$variant"
		if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
			fail "installer deleted $variant old source as project-owned"
		fi
		grep -Fq "registered old DKMS source does not match exact 0.2.5 ownership: $old" \
			"$sandbox/output" ||
			fail "installer did not diagnose $variant old source ownership"
		assert_source_ownership_mutation_survives "$old" "$variant"
		assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
			'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
			"$variant old source ownership check changed old DKMS state"
		assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" '' \
			"$variant old source ownership check reached new DKMS mutation"
	done
	printf 'PASS: install requires exact old source bytes, paths, modes, and types\n'
}

test_uninstall_requires_exact_current_source_ownership()
{
	for variant in extra modified mode symlink; do
		sandbox=$workdir/uninstall-current-source-ownership-$variant
		make_sandbox "$sandbox"
		run_install "$sandbox" "$sandbox/validate-pass.sh"
		current=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
		mutate_source_ownership_fixture "$current" "$variant"
		if run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
			fail "uninstaller deleted $variant current source as project-owned"
		fi
		grep -Fq "source path does not match exact 0.2.6 ownership: $current" \
			"$sandbox/output" ||
			fail "uninstaller did not diagnose $variant current source ownership"
		assert_source_ownership_mutation_survives "$current" "$variant"
		assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
			'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
			"$variant current source ownership check reached DKMS removal"
	done
	printf 'PASS: uninstall requires exact current source bytes, paths, modes, and types\n'
}

test_install_source_retirement_claim_preserves_race()
{
	sandbox=$workdir/install-old-source-retirement-race
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	old=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5
	if MV_MUTATE_SOURCE_TREE="$old" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted old source mutation at retirement claim boundary'
	fi
	grep -Fxq raced-source-data "$old/local-race" ||
		fail 'old source retirement race lost local data'
	grep -Fq 'old DKMS source retirement could not claim exact ownership; retained' \
		"$sandbox/output" ||
		fail 'old source retirement race did not report retained recovery'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'old source retirement race did not restore old DKMS lifecycle'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" '' \
		'old source retirement race retained new DKMS lifecycle'
	printf 'PASS: install retirement claim preserves raced old source data\n'
}

test_uninstall_source_retirement_claim_preserves_race()
{
	sandbox=$workdir/uninstall-current-source-retirement-race
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	current=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
	if MV_MUTATE_SOURCE_TREE="$current" run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstaller accepted current source mutation at retirement claim boundary'
	fi
	grep -Fxq raced-source-data "$current/local-race" ||
		fail 'current source retirement race lost local data'
	grep -Fq 'source retirement could not claim exact ownership; retained' "$sandbox/output" ||
		fail 'current source retirement race did not report retained recovery'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'current source retirement race did not restore DKMS lifecycle'
	printf 'PASS: uninstall retirement claim preserves raced current source data\n'
}

test_install_rollback_retains_modified_created_source()
{
	sandbox=$workdir/install-rollback-modified-created-source
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	current=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6
	modified=$current/src/display_compat_core.c
	if RM_FAIL_SOURCE_RETIREMENT_BASENAME=Makefile \
		RM_CORRUPT_FILE_ON_FAILURE="$modified" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted late failure after created source was locally modified'
	fi
	grep -Fxq corrupt-runtime-asset "$modified" ||
		fail 'install rollback deleted a local edit in transaction-created source'
	grep -Fq "new source retained at $current" "$sandbox/output" ||
		fail 'install rollback did not report retained modified source'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'modified created-source rollback did not restore old DKMS lifecycle'
	printf 'PASS: install rollback retains modified transaction-created source\n'
}

capture_migration_baseline()
{
	sandbox=$1
	MIGRATION_OLD_SOURCE_DIGEST=$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5")
	MIGRATION_PROVIDER_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko" | awk '{print $1}')
	MIGRATION_PANEL_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko" | awk '{print $1}')
	MIGRATION_TOUCH_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko" | awk '{print $1}')
	MIGRATION_BOOT_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	MIGRATION_DTBO_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" | awk '{print $1}')
}

assert_clean_failed_migration_restored()
{
	sandbox=$1
	output=$2
	if grep -Eq 'rollback also failed|recovery artifacts retained' "$output"; then
		fail 'ordinary failure did not complete a clean 0.2.5 rollback'
	fi
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'failure did not restore exact old DKMS lifecycle'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" '' \
		'failure retained the new DKMS lifecycle'
	assert_equal "$(cat "$sandbox/dkms-active.state")" '6.18.43-current-rockchip64|0.2.5' \
		'failure did not reactivate the old target-kernel version'
	assert_equal "$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5")" \
		"$MIGRATION_OLD_SOURCE_DIGEST" 'failure changed the old source tree'
	assert_equal "$(/usr/bin/sha256sum "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko" | awk '{print $1}')" \
		"$MIGRATION_PROVIDER_CHECKSUM" 'failure changed old provider module bytes'
	assert_equal "$(/usr/bin/sha256sum "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko" | awk '{print $1}')" \
		"$MIGRATION_PANEL_CHECKSUM" 'failure changed old panel module bytes'
	assert_equal "$(/usr/bin/sha256sum "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko" | awk '{print $1}')" \
		"$MIGRATION_TOUCH_CHECKSUM" 'failure changed old touch module bytes'
	assert_module_matches_build "$sandbox" 0.2.5 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.5 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.5 raspits_ft5426
	assert_equal "$(/usr/bin/sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" \
		"$MIGRATION_BOOT_CHECKSUM" 'failure changed boot configuration'
	assert_equal "$(/usr/bin/sha256sum "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" | awk '{print $1}')" \
		"$MIGRATION_DTBO_CHECKSUM" 'failure changed the prior DTBO'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6"
	assert_file_absent "$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak"
	assert_file_absent "$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak.sha256"
	[ -z "$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		\( -name '.rockpi-rpi-touchscreen.transaction.*' -o -name '.rockpi-rpi-touchscreen.stage.*' \) \
		-print -quit)" ] || fail 'clean rollback retained private transaction state'
}

prepare_current_release_lifecycle()
{
	sandbox=$1
	phase=$2
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	rm -f "$sandbox/dkms-installed.state" "$sandbox/dkms-active.state"
	find "$sandbox/modules/6.18.43-current-rockchip64" -type f \
		\( -name 'rockpi_rk3399_display_compat.ko*' \
		-o -name 'panel_rockpi_rpi_touchscreen.ko*' \
		-o -name 'raspits_ft5426.ko*' \) -delete
	refresh_dependency_indexes "$sandbox"
	case $phase in
	added)
		rm -f "$sandbox/dkms-built.state"
		rm -rf "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6"
		;;
	built) ;;
	*) fail "unknown current-release lifecycle fixture: $phase" ;;
	esac
}

test_preexisting_current_added_and_built_lifecycles_are_restored()
{
	for phase in added built; do
		sandbox=$workdir/current-baseline-$phase
		prepare_current_release_lifecycle "$sandbox" "$phase"
		status_before=$(sandbox_dkms_status "$sandbox" 0.2.6)
		source_before=$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6")
		if [ "$phase" = built ]; then
			build_before=$(source_tree_digest "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6")
		fi
		if MODINFO_PANEL_ALIAS='of:N*T*Craspits_ft5426' \
			run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
			fail "installer accepted a late failure from a pre-existing $phase baseline"
		fi
		assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" "$status_before" \
			"failure did not restore exact pre-existing $phase lifecycle"
		assert_equal "$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6")" \
			"$source_before" "failure changed pre-existing $phase source"
		case $phase in
		added)
			assert_file_absent "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6"
			;;
		built)
			assert_equal "$(source_tree_digest "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6")" \
				"$build_before" 'failure changed pre-existing built artifacts'
			;;
		esac
		grep -Eq 'rollback also failed|recovery artifacts retained' "$sandbox/output" &&
			fail "pre-existing $phase baseline did not roll back cleanly"
	done
	printf 'PASS: pre-existing added and built 0.2.6 lifecycles restore exactly\n'
}

test_old_retirement_mutate_then_fail_restores_transaction()
{
	sandbox=$workdir/old-retirement-mutate-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	capture_migration_baseline "$sandbox"
	if DKMS_FAIL_OLD_REMOVE_AFTER_MUTATION=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted old-release retirement that mutated state before failing'
	fi
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	! grep -Fq 'PASS: installed' "$sandbox/output" ||
		fail 'failed old retirement printed install success'
	printf 'PASS: mutate-then-fail old retirement restores the full migration transaction\n'
}

test_compressed_only_old_and_new_artifacts_migrate_successfully()
{
	sandbox=$workdir/compressed-only-migration
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	compress_old_release_artifacts "$sandbox"
	DKMS_BUILD_COMPRESSION=xz DKMS_INSTALL_COMPRESSION=gz \
		run_install "$sandbox" "$sandbox/validate-pass.sh"
	assert_module_matches_build "$sandbox" 0.2.6 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.6 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.6 raspits_ft5426
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" '' \
		'compressed old release remained after migration'
	printf 'PASS: compressed-only old and new DKMS artifacts migrate with content verification\n'
}

test_corrupt_compressed_old_preflight_fails_closed()
{
	sandbox=$workdir/corrupt-compressed-old-preflight
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	compress_old_release_artifacts "$sandbox"
	printf '%s\n' corrupt-xz > \
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.5/6.18.43-current-rockchip64/aarch64/module/panel_rockpi_rpi_touchscreen.ko.xz"
	printf '%s\n' corrupt-gzip > \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko.gz"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted two failed old compressed checksum operations as equal'
	fi
	grep -Fq 'cannot verify old DKMS-built panel_rockpi_rpi_touchscreen module content' \
		"$sandbox/output" || fail 'installer did not report the corrupt compressed old build artifact'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'corrupt compressed preflight changed the old lifecycle'
	printf 'PASS: corrupt compressed old preflight fails closed before mutation\n'
}

test_corrupt_compressed_old_rollback_verification_is_reported()
{
	sandbox=$workdir/corrupt-compressed-old-rollback
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	compress_old_release_artifacts "$sandbox"
	if DKMS_FAIL_INSTALL_MODULE=raspits_ft5426 \
		DKMS_CORRUPT_COMPRESSED_OLD_ROLLBACK_MODULE=panel_rockpi_rpi_touchscreen \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a new install failure with corrupt compressed old rollback artifacts'
	fi
	grep -Fq 'old installed panel_rockpi_rpi_touchscreen checksum restoration failed' \
		"$sandbox/output" || fail 'rollback swallowed corrupt compressed old checksum operations'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'corrupt compressed old rollback did not report incomplete restoration'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'corrupt compressed rollback discarded recovery artifacts'
	grep -Fq "recovery artifacts retained at $recovery" "$sandbox/output" ||
		fail 'corrupt compressed rollback did not report its recovery directory'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5/dkms.conf" ] ||
		fail 'corrupt compressed rollback removed the faithful old source'
	printf 'PASS: corrupt compressed old rollback verification fails closed and retains recovery\n'
}

test_zstd_dispatch_and_checksum_failure_propagation()
{
	sandbox=$workdir/zstd-dispatch
	make_sandbox "$sandbox"
	for suffix in xz gz; do
		corrupt=$sandbox/corrupt.ko.$suffix
		printf '%s\n' "corrupt-$suffix" > "$corrupt"
		if module_content_checksum "$corrupt" > "$sandbox/output" 2>&1; then
			fail "test checksum helper masked a $suffix decompressor failure"
		fi
	done
	corrupt=$sandbox/corrupt.ko.zst
	printf '%s\n' corrupt-zstd > "$corrupt"
	if PATH="$sandbox/bin:$PATH" ZSTD_LOG="$sandbox/zstd.log" \
		module_content_checksum "$corrupt" > "$sandbox/output" 2>&1; then
		fail 'test checksum helper masked a zstd decompressor failure'
	fi
	grep -Fq -- "-q -dc $corrupt" "$sandbox/zstd.log" ||
		fail 'zstd suffix did not dispatch to the zstd decompressor'
	printf 'PASS: zstd dispatch is deterministic and decompressor failures propagate\n'
}

test_zstd_only_new_artifacts_are_verified()
{
	sandbox=$workdir/zstd-only-new
	make_sandbox "$sandbox"
	DKMS_BUILD_COMPRESSION=zst DKMS_INSTALL_COMPRESSION=same \
		run_install "$sandbox" "$sandbox/validate-pass.sh"
	for module in rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426; do
		[ -f "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6/6.18.43-current-rockchip64/aarch64/module/$module.ko.zst" ] ||
			fail "missing zstd-only DKMS build artifact: $module"
		[ -f "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/$module.ko.zst" ] ||
			fail "missing zstd-only installed artifact: $module"
		PATH="$sandbox/bin:$PATH" ZSTD_LOG="$sandbox/zstd.log" \
			assert_module_matches_build "$sandbox" 0.2.6 "$module"
	done
	[ "$(wc -l < "$sandbox/zstd.log")" -ge 12 ] ||
		fail 'zstd-only verification did not decompress every built and installed module'
	printf 'PASS: zstd-only new artifacts dispatch and verify all three module contents\n'
}

test_migration_removes_old_release_only_after_success_and_ordered_verification()
{
	sandbox=$workdir/migration-success
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	DKMS_REQUIRE_NEW_STATE_BEFORE_OLD_REMOVE=1 run_install "$sandbox" "$sandbox/validate-pass.sh"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'new DKMS version did not reach exact installed state'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" '' \
		'old DKMS lifecycle remained after successful migration'
	assert_equal "$(cat "$sandbox/dkms-active.state")" '6.18.43-current-rockchip64|0.2.6' \
		'new DKMS version is not the sole active target-kernel version'
	[ -f "$sandbox/dkms-new-active-verified.marker" ] ||
		fail 'migration did not prove old installed tuple was deactivated before removal'
	assert_module_matches_build "$sandbox" 0.2.6 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.6 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.6 raspits_ft5426
	assert_equal "$(cat "$sandbox/dkms-module.log")" 'build 0.2.6 rockpi_rk3399_display_compat
build 0.2.6 panel_rockpi_rpi_touchscreen
build 0.2.6 raspits_ft5426
install 0.2.6 rockpi_rk3399_display_compat
install 0.2.6 panel_rockpi_rpi_touchscreen
install 0.2.6 raspits_ft5426' 'new modules were not built and installed in dependency-safe order'
	printf 'PASS: successful 0.2.5 to 0.2.6 migration after ordered complete verification\n'
}

test_old_release_retires_only_after_runtime_assets_verify()
{
	sandbox=$workdir/runtime-before-retirement
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	output=$(DKMS_REQUIRE_NEW_STATE_BEFORE_OLD_REMOVE=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh")
	assert_runtime_assets_match_source "$sandbox"
	[ -f "$sandbox/dkms-new-active-verified.marker" ] ||
		fail 'old retirement did not verify runtime assets first'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" \
		'rockpi-rpi-touchscreen/0.2.6, 6.18.43-current-rockchip64, aarch64: installed' \
		'new DKMS lifecycle was not exact after runtime verification'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" '' \
		'old DKMS lifecycle remained after runtime verification'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5"
	if printf '%s\n' "$output" | grep -Eq 'rollback also failed|recovery artifacts retained'; then
		fail 'runtime-verified migration reported rollback failure'
	fi
	printf 'PASS: old release retires only after runtime assets verify\n'
}

test_each_new_module_build_install_and_checksum_failure_restores_old_release()
{
	for phase in BUILD INSTALL CHECKSUM; do
		for module in rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426; do
			sandbox=$workdir/migration-${phase}-${module}
			make_sandbox "$sandbox"
			seed_old_release "$sandbox"
			capture_migration_baseline "$sandbox"
			case $phase in
			BUILD)
				if DKMS_FAIL_BUILD_MODULE=$module run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
					fail "installer accepted $module build failure"
				fi
				;;
			INSTALL)
				if DKMS_FAIL_INSTALL_MODULE=$module run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
					fail "installer accepted $module install failure"
				fi
				;;
			CHECKSUM)
				if DKMS_FAIL_CHECKSUM_MODULE=$module run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
					fail "installer accepted $module checksum failure"
				fi
				;;
			esac
			assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
		done
	done
	printf 'PASS: every new-module build, install, and checksum failure restores exact 0.2.5 state\n'
}

test_install_add_mutate_then_fail_restores_absent_baseline()
{
	sandbox=$workdir/install-add-mutate-failure
	make_sandbox "$sandbox"
	config_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	if DKMS_FAIL_ON=add run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a DKMS add that mutated state before failing'
	fi
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" '' \
		'mutate-then-fail DKMS add did not restore the absent registration baseline'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko"
	assert_file_absent "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko"
	assert_file_absent "$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$config_before" \
		'mutate-then-fail DKMS add changed boot configuration'
	grep -Fqx 'remove -m rockpi-rpi-touchscreen -v 0.2.6 --all' "$sandbox/dkms.log" ||
		fail 'mutate-then-fail DKMS add did not remove the newly created registration'
	printf 'PASS: mutate-then-fail DKMS add restores absent registration baseline\n'
}

test_invalid_old_installed_checksum_blocks_migration()
{
	sandbox=$workdir/invalid-old-checksum
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	printf '%s\n' 'corrupt-old-touch-module' > \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer migrated from an invalid old installed checksum'
	fi
	grep -Fq 'old installed raspits_ft5426 module does not match its DKMS build' "$sandbox/output" ||
		fail 'installer did not explain the invalid old rollback baseline'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'invalid old checksum preflight changed old lifecycle state'
	printf 'PASS: invalid old installed checksum blocks migration before mutation\n'
}

test_invalid_old_provider_checksum_blocks_migration()
{
	sandbox=$workdir/invalid-old-provider-checksum
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	printf '%s\n' 'corrupt-old-provider-module' > \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer migrated from an invalid old provider checksum'
	fi
	grep -Fq 'old installed rockpi_rk3399_display_compat module does not match its DKMS build' \
		"$sandbox/output" || fail 'installer did not explain the invalid old provider baseline'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'invalid old provider checksum preflight changed old lifecycle state'
	printf 'PASS: invalid old provider checksum blocks migration before mutation\n'
}

test_invalid_old_panel_checksum_blocks_migration()
{
	sandbox=$workdir/invalid-old-panel-checksum
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	printf '%s\n' 'corrupt-old-panel-module' > \
		"$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer migrated from an invalid old panel checksum'
	fi
	grep -Fq 'old installed panel_rockpi_rpi_touchscreen module does not match its DKMS build' \
		"$sandbox/output" || fail 'installer did not explain the invalid old panel baseline'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'invalid old panel checksum preflight changed old lifecycle state'
	printf 'PASS: invalid old panel checksum blocks migration before mutation\n'
}

test_sparse_extra_old_module_metadata_blocks_migration()
{
	sandbox=$workdir/sparse-extra-old-module
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	cat >> "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5/dkms.conf" <<'EOF'
BUILT_MODULE_NAME[10]="unexpected_old_module"
BUILT_MODULE_LOCATION[10]="."
DEST_MODULE_LOCATION[10]="/updates/dkms"
EOF
	capture_migration_baseline "$sandbox"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted sparse extra-module metadata in the old release'
	fi
	grep -Fq 'registered old DKMS source does not match exact 0.2.5 ownership' "$sandbox/output" ||
		fail 'installer did not explain the unfaithful old source metadata'
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	printf 'PASS: sparse extra old-module metadata blocks migration before mutation\n'
}

test_missing_old_provider_metadata_blocks_migration()
{
	sandbox=$workdir/missing-old-provider-metadata
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	sed -i '/\[0\]/d' "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5/dkms.conf"
	capture_migration_baseline "$sandbox"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted old metadata that omitted the provider'
	fi
	grep -Fq 'registered old DKMS source does not match exact 0.2.5 ownership' \
		"$sandbox/output" || fail 'installer did not explain missing old provider metadata'
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	printf 'PASS: missing old provider metadata blocks migration before mutation\n'
}

test_incomplete_snapshot_leaves_old_modules_untouched()
{
	sandbox=$workdir/incomplete-snapshot
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	capture_migration_baseline "$sandbox"
	if CP_FAIL_SNAPSHOT_MODULE=raspits_ft5426 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted incomplete recovery snapshot'
	fi
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	printf 'PASS: incomplete snapshot leaves untouched old modules and lifecycle exact\n'
}

test_third_module_install_failure_restores_every_old_module_path()
{
	sandbox=$workdir/migration-third-module-extra-path
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	extra_old_module=$sandbox/modules/6.18.43-current-rockchip64/weak-updates/raspits_ft5426.ko.xz
	mkdir -p "$(dirname -- "$extra_old_module")"
	printf '%s\n' 'old-compressed-touch-module' > "$extra_old_module"
	extra_old_checksum=$(/usr/bin/sha256sum "$extra_old_module" | awk '{print $1}')
	capture_migration_baseline "$sandbox"
	if DKMS_FAIL_INSTALL_MODULE=raspits_ft5426 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted failure while installing the third module'
	fi
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	grep -Fqx 'install -m rockpi-rpi-touchscreen -v 0.2.5 -k 6.18.43-current-rockchip64' "$sandbox/dkms.log" ||
		fail 'rollback did not reinstall old target-kernel version through DKMS'
	assert_equal "$(/usr/bin/sha256sum "$extra_old_module" | awk '{print $1}')" "$extra_old_checksum" \
		'third-module failure did not restore every prior touch module path'
	printf 'PASS: third-module failure restores all 0.2.5 module paths and boot state\n'
}

test_failed_new_registration_removal_retains_recovery_source()
{
	sandbox=$workdir/new-registration-removal-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	output=$sandbox/output
	if MODINFO_PANEL_ALIAS='of:N*T*Craspits_ft5426' DKMS_REMOVE_GENUINE_FAIL=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'installer accepted a failed rollback removal'
	fi
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5/dkms.conf" ] ||
		fail 'failed rollback removal lost the old recovery source'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6/dkms.conf" ] ||
		fail 'failed rollback removal stranded new registration without its source'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'failed rollback removal lost exact old installed state'
	[ -n "$(sandbox_dkms_status "$sandbox" 0.2.6)" ] || fail 'test did not retain failed new registration'
	grep -Fq "new source retained at $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.6" "$output" ||
		fail 'rollback did not report the exact retained new source path'
	assert_module_matches_build "$sandbox" 0.2.5 raspits_ft5426
	printf 'PASS: failed new-registration removal retains exact recovery source\n'
}

test_failed_old_reinstall_reports_preserved_recovery()
{
	sandbox=$workdir/old-reinstall-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	output=$sandbox/output
	if DKMS_FAIL_INSTALL_MODULE=panel_rockpi_rpi_touchscreen DKMS_FAIL_OLD_REINSTALL=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'installer accepted failed old DKMS reactivation'
	fi
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5/dkms.conf" ] ||
		fail 'old reinstall failure removed old source'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'old reinstall failure discarded private recovery artifacts'
	grep -Fq "old DKMS reinstall failed; retained old source at $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5" "$output" ||
		fail 'old reinstall failure did not report the exact old source path'
	grep -Fq "recovery artifacts retained at $recovery" "$output" ||
		fail 'old reinstall failure did not report the exact recovery directory'
	printf 'PASS: failed old DKMS reactivation preserves and reports recovery paths\n'
}

test_failed_old_checksum_verification_preserves_recovery()
{
	sandbox=$workdir/old-checksum-verification-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	output=$sandbox/output
	if DKMS_FAIL_INSTALL_MODULE=raspits_ft5426 \
		DKMS_CORRUPT_OLD_REINSTALL_MODULE=panel_rockpi_rpi_touchscreen \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'installer accepted failed old checksum verification'
	fi
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'old checksum verification failure discarded recovery artifacts'
	grep -Fq 'old installed panel_rockpi_rpi_touchscreen checksum restoration failed' "$output" ||
		fail 'rollback did not report the failed old panel checksum verification'
	grep -Fq "recovery artifacts retained at $recovery" "$output" ||
		fail 'old checksum verification failure did not report its recovery directory'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5/dkms.conf" ] ||
		fail 'old checksum verification failure removed the old source'
	printf 'PASS: failed old checksum verification preserves and reports recovery artifacts\n'
}

test_old_status_failure_retains_source_and_does_not_claim_success()
{
	sandbox=$workdir/migration-status-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	output=$sandbox/output
	if DKMS_STATUS_FAIL_VERSION=0.2.5 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'installer accepted unverifiable old DKMS state'
	fi
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.5/dkms.conf" ] ||
		fail 'status failure removed old source'
	assert_equal "$(DKMS_STATUS_FAIL_VERSION= sandbox_dkms_status "$sandbox" 0.2.5)" \
		'rockpi-rpi-touchscreen/0.2.5, 6.18.43-current-rockchip64, aarch64: installed' \
		'status failure changed old lifecycle state'
	! grep -Fq 'PASS: installed' "$output" || fail 'status failure printed unconditional install success'
	grep -Fq 'cannot verify old DKMS state; retained' "$output" ||
		fail 'status failure did not explain retained old state'
	printf 'PASS: failed old-version status retains source and suppresses success\n'
}

test_late_failure_after_dtbo_replacement_restores_previous_dtbo()
{
	sandbox=$workdir/dtbo-signal-rollback
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	destination=$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo
	printf '%s\n' 'previous-dtbo' > "$destination"
	previous_checksum=$(sha256sum "$destination" | awk '{print $1}')
	if MV_FAIL_AFTER_TARGET="$destination" MV_FAIL_AFTER_ONCE_MARKER="$sandbox/mv-failed-after" \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer survived injected late failure after DTBO replacement'
	fi
	assert_equal "$(sha256sum "$destination" | awk '{print $1}')" "$previous_checksum" \
		'late failure after replacement must restore the prior DTBO'
	[ -z "$(find "$sandbox/boot" -maxdepth 1 -name '.rockpi-rpi-touchscreen.overlay-backup.*' -print -quit)" ] ||
		fail 'successful DTBO rollback leaked its private backup'
	printf 'PASS: late failure after DTBO replacement restores prior artifact\n'
}

test_install_rollback_refreshes_dependency_indexes_after_path_suffix_restore()
{
	sandbox=$workdir/install-depmod-path-restore
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	installed=$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/raspits_ft5426.ko
	restored=$sandbox/modules/6.18.43-current-rockchip64/weak-updates/raspits_ft5426.ko.xz
	mkdir -p "$(dirname -- "$restored")"
	xz -c "$installed" > "$restored"
	rm -f "$installed"
	refresh_dependency_indexes "$sandbox"
	if DKMS_FAIL_INSTALL_MODULE=raspits_ft5426 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted the injected third-module installation failure'
	fi
	if grep -Fq 'rollback also failed' "$sandbox/output"; then
		fail 'install rollback did not refresh dependency indexes after restoring a compressed weak-updates path'
	fi
	assert_equal "$(indexed_module_path "$sandbox" raspits_ft5426)" "$restored" \
		'install rollback dependency index does not resolve the restored compressed touch module'
	grep -Fqx 'weak-updates/raspits_ft5426.ko.xz:' "$sandbox/modules/6.18.43-current-rockchip64/modules.dep" ||
		fail 'install rollback modules.dep does not contain the exact restored suffix and path'
	grep -Fqx 'alias fake:weak-updates/raspits_ft5426.ko.xz:' \
		"$sandbox/modules/6.18.43-current-rockchip64/modules.alias" ||
		fail 'install rollback modules.alias was not regenerated for the restored touch path'
	grep -Fqx 'internal=0 args=-a 6.18.43-current-rockchip64' "$sandbox/depmod.log" ||
		fail 'install rollback did not invoke depmod -a for the target kernel'
	printf 'PASS: install rollback refreshes dependency indexes after exact raw path restore\n'
}

test_uninstall_rollback_refreshes_dependency_indexes_after_path_suffix_restore()
{
	sandbox=$workdir/uninstall-depmod-path-restore
	prepare_uninstall_failure "$sandbox"
	installed=$sandbox/modules/6.18.43-current-rockchip64/updates/dkms/rockpi_rk3399_display_compat.ko
	restored=$sandbox/modules/6.18.43-current-rockchip64/weak-updates/rockpi_rk3399_display_compat.ko.gz
	mkdir -p "$(dirname -- "$restored")"
	gzip -c "$installed" > "$restored"
	rm -f "$installed"
	refresh_dependency_indexes "$sandbox"
	if DKMS_STATUS_FAIL_AFTER_REMOVE=1 run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted the injected post-removal status failure'
	fi
	if grep -Fq 'rollback also failed' "$sandbox/output"; then
		fail 'uninstall rollback did not cleanly restore the compressed weak-updates baseline'
	fi
	assert_equal "$(indexed_module_path "$sandbox" rockpi_rk3399_display_compat)" "$restored" \
		'uninstall rollback dependency index does not resolve the restored compressed provider'
	grep -Fqx 'weak-updates/rockpi_rk3399_display_compat.ko.gz:' \
		"$sandbox/modules/6.18.43-current-rockchip64/modules.dep" ||
		fail 'uninstall rollback modules.dep does not contain the exact restored suffix and path'
	grep -Fqx 'alias fake:weak-updates/rockpi_rk3399_display_compat.ko.gz:' \
		"$sandbox/modules/6.18.43-current-rockchip64/modules.alias" ||
		fail 'uninstall rollback modules.alias was not regenerated for the restored provider path'
	grep -Fqx 'internal=0 args=-a 6.18.43-current-rockchip64' "$sandbox/depmod.log" ||
		fail 'uninstall rollback did not invoke depmod -a for the target kernel'
	printf 'PASS: uninstall rollback refreshes dependency indexes after exact raw path restore\n'
}

test_depmod_rollback_failures_retain_and_report_recovery()
{
	for operation in install uninstall; do
		sandbox=$workdir/$operation-depmod-failure
		case $operation in
		install)
			make_sandbox "$sandbox"
			seed_old_release "$sandbox"
			if DEPMOD_FAIL_EXTERNAL=1 DKMS_FAIL_INSTALL_MODULE=raspits_ft5426 \
				run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
				fail 'installer accepted the injected install and rollback depmod failures'
			fi
			recovery_pattern='.rockpi-rpi-touchscreen.transaction.*'
			;;
		uninstall)
			prepare_uninstall_failure "$sandbox"
			if DEPMOD_FAIL_EXTERNAL=1 DKMS_STATUS_FAIL_AFTER_REMOVE=1 \
				run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
				fail 'uninstall accepted the injected status and rollback depmod failures'
			fi
			recovery_pattern='.rockpi-rpi-touchscreen.uninstall.*'
			;;
		esac
		grep -Fq 'dependency index refresh failed for 6.18.43-current-rockchip64' "$sandbox/output" ||
			fail "$operation rollback did not report the failed target-kernel depmod refresh"
		grep -Fq 'rollback also failed' "$sandbox/output" ||
			fail "$operation rollback did not fail closed after depmod failed"
		recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
			-name "$recovery_pattern" -print -quit)
		[ -n "$recovery" ] || fail "$operation rollback discarded recovery after depmod failed"
		grep -Fq "$recovery" "$sandbox/output" ||
			fail "$operation rollback did not report its retained recovery directory"
	done
	printf 'PASS: install and uninstall depmod rollback failures fail closed with reported recovery\n'
}

test_existing_persistent_backup_uses_private_current_boot_baseline()
{
	sandbox=$workdir/private-current-boot-baseline
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	config=$sandbox/boot/armbianEnv.txt
	backup=$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak
	printf '%s\n' 'older persistent recovery baseline' > "$backup"
	/usr/bin/sha256sum "$backup" > "$backup.sha256"
	config_before=$(/usr/bin/sha256sum "$config" | awk '{print $1}')
	backup_before=$(/usr/bin/sha256sum "$backup" | awk '{print $1}')
	backup_checksum_before=$(/usr/bin/sha256sum "$backup.sha256" | awk '{print $1}')
	if DKMS_FAIL_OLD_REMOVE_AFTER_MUTATION=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted the injected late old-release retirement failure'
	fi
	assert_equal "$(/usr/bin/sha256sum "$config" | awk '{print $1}')" "$config_before" \
		'late install failure did not restore the private current boot baseline'
	assert_equal "$(/usr/bin/sha256sum "$backup" | awk '{print $1}')" "$backup_before" \
		'install transaction changed the pre-existing persistent boot backup'
	assert_equal "$(/usr/bin/sha256sum "$backup.sha256" | awk '{print $1}')" \
		"$backup_checksum_before" 'install transaction changed the persistent backup checksum'
	printf 'PASS: existing persistent backup remains separate from private current boot rollback\n'
}

test_private_boot_restore_failure_retains_and_reports_recovery()
{
	sandbox=$workdir/private-boot-restore-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	backup=$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak
	printf '%s\n' 'older persistent recovery baseline' > "$backup"
	/usr/bin/sha256sum "$backup" > "$backup.sha256"
	if CP_FAIL_PRIVATE_BOOT_RESTORE=1 DKMS_FAIL_OLD_REMOVE_AFTER_MUTATION=1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a failed private boot-baseline restore'
	fi
	grep -Fq 'private boot baseline retained at ' "$sandbox/output" ||
		fail 'private boot restore failure did not report its exact recovery snapshot'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'private boot restore failure did not fail closed'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'private boot restore failure discarded transaction recovery'
	[ -f "$recovery/current-armbianEnv.txt" ] ||
		fail 'private current-boot snapshot is missing from retained recovery'
	grep -Fq "$recovery/current-armbianEnv.txt" "$sandbox/output" ||
		fail 'private boot restore failure did not report the retained snapshot path'
	printf 'PASS: private boot restore failure fails closed with reported recovery\n'
}

prepare_exact_uninstall_lifecycle()
{
	sandbox=$1
	phase=$2
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	case $phase in
	installed) ;;
	built)
		rm -f "$sandbox/dkms-installed.state" "$sandbox/dkms-active.state"
		find "$sandbox/modules/6.18.43-current-rockchip64" -type f \
			\( -name 'rockpi_rk3399_display_compat.ko*' \
			-o -name 'panel_rockpi_rpi_touchscreen.ko*' \
			-o -name 'raspits_ft5426.ko*' \) -delete
		refresh_dependency_indexes "$sandbox"
		;;
	added)
		rm -f "$sandbox/dkms-built.state" "$sandbox/dkms-installed.state" \
			"$sandbox/dkms-active.state"
		rm -rf "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6"
		find "$sandbox/modules/6.18.43-current-rockchip64" -type f \
			\( -name 'rockpi_rk3399_display_compat.ko*' \
			-o -name 'panel_rockpi_rpi_touchscreen.ko*' \
			-o -name 'raspits_ft5426.ko*' \) -delete
		refresh_dependency_indexes "$sandbox"
		;;
	*) fail "unknown exact uninstall lifecycle fixture: $phase" ;;
	esac
	state=$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6
	mkdir -p "$state/transaction-metadata"
	printf 'exact-%s-baseline\000with-private-bytes\n' "$phase" > "$state/transaction-metadata/baseline"
}

test_uninstall_restores_exact_dkms_state_tree_for_every_lifecycle()
{
	for phase in added built installed; do
		sandbox=$workdir/uninstall-exact-state-$phase
		prepare_exact_uninstall_lifecycle "$sandbox" "$phase"
		state=$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.6
		state_before=$(source_tree_digest "$state")
		status_before=$(sandbox_dkms_status "$sandbox" 0.2.6)
		if DKMS_STATUS_FAIL_AFTER_REMOVE=1 run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
			fail "uninstall accepted the injected post-removal failure from $phase state"
		fi
		grep -Fq 'rollback also failed' "$sandbox/output" &&
			fail "uninstall could not cleanly restore the exact $phase state tree"
		[ -d "$state" ] || fail "uninstall did not recreate the exact $phase DKMS state tree"
		assert_equal "$(source_tree_digest "$state")" "$state_before" \
			"uninstall rollback changed bytes in the $phase DKMS state tree"
		assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.6)" "$status_before" \
			"uninstall rollback changed the exact $phase lifecycle"
	done
	printf 'PASS: uninstall restores exact DKMS state-tree bytes for added, built, and installed states\n'
}

test_uninstall_state_tree_restore_verification_failure_retains_recovery()
{
	sandbox=$workdir/uninstall-state-restore-corruption
	prepare_exact_uninstall_lifecycle "$sandbox" installed
	if DKMS_CORRUPT_UNINSTALL_STATE_RESTORE=1 DKMS_STATUS_FAIL_AFTER_REMOVE=1 \
		run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted a corrupted DKMS state-tree restore'
	fi
	grep -Fq 'DKMS state-tree restore failed' "$sandbox/output" ||
		fail 'uninstall did not report DKMS state-tree restore verification failure'
	grep -Fq 'rollback also failed' "$sandbox/output" ||
		fail 'uninstall did not fail closed after state-tree restore verification failed'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.uninstall.*' -print -quit)
	[ -n "$recovery" ] || fail 'uninstall discarded recovery after state-tree verification failed'
	[ -f "$recovery/dkms-state/transaction-metadata/baseline" ] ||
		fail 'uninstall recovery lacks the exact DKMS state-tree snapshot'
	grep -Fq "$recovery" "$sandbox/output" ||
		fail 'uninstall did not report the retained state-tree recovery directory'
	printf 'PASS: uninstall state-tree verification failure fails closed with reported recovery\n'
}

if [ -n "${TEST_FILTER:-}" ]; then
	"$TEST_FILTER"
	exit 0
fi

test_install_is_idempotent_and_preserves_unrelated_boot_text
test_installer_rejects_unsupported_kernel_before_validation_or_mutation
test_production_transactions_attest_protected_xorg_on_success
test_install_reports_committed_protected_xorg_mutation
test_uninstall_reports_committed_protected_xorg_mutation
test_protected_xorg_attestation_runs_after_install_rollback
test_protected_xorg_preflight_rejects_missing_unreadable_and_wrong_type
test_install_handoff_requires_authorized_dsi_first_acceptance
test_dkms_make_command_suppresses_automatic_kernelrelease
test_uninstall_removes_only_project_token_and_dry_run_is_scoped
test_uninstall_dry_run_lists_runtime_assets
test_uninstall_dry_run_retains_modified_autostart_dependency
test_uninstall_removes_matching_runtime_assets
test_uninstall_retains_and_reports_modified_lightdm_policy
test_uninstall_retains_and_reports_modified_mapper
test_uninstall_retains_and_reports_modified_autostart
test_uninstall_late_failure_restores_removed_runtime_assets
test_uninstall_runtime_restore_failure_retains_recovery
test_uninstall_dry_run_retains_modified_runtime_assets
test_uninstall_claim_revalidates_modified_runtime_asset
test_uninstall_pre_snapshot_byte_edit_is_retained
test_uninstall_pre_snapshot_type_replacements_are_retained
test_uninstall_rename_then_error_retains_named_claim
test_uninstall_failed_claim_move_retains_edited_recovery
test_uninstall_claim_cleanup_failure_reports_nonempty_recovery
test_uninstall_claim_preserves_mapper_for_raced_autostart
test_uninstall_autostart_claim_collision_retains_recovery
test_uninstall_mapper_claim_linearizes_autostart_dependency
test_uninstall_claim_retains_raced_symlink_mapper
test_uninstall_runtime_restore_publication_never_overwrites_race
test_uninstall_recovery_cleanup_failure_is_reported
test_install_prior_overlay_cleanup_failure_reports_commit_and_continues
test_install_reports_every_committed_cleanup_failure
test_failed_validation_does_not_mutate_boot_configuration
test_installer_requires_the_panel_specific_alias
test_installer_requires_the_provider_specific_alias
test_installer_rejects_built_only_dkms_status
test_post_backup_failure_rolls_back_owned_assets_and_boot_configuration
test_boot_configuration_uses_atomic_mv_for_update_and_rollback
test_offline_boot_rollback_changes_only_explicit_target_root
test_same_version_changed_source_is_rejected
test_install_owns_verified_runtime_assets
test_preexisting_unrelated_runtime_asset_blocks_before_mutation
test_preexisting_wrong_runtime_mode_blocks_before_mutation
test_runtime_asset_install_failure_restores_absent_baseline
test_second_runtime_asset_mutate_then_fail_restores_absent_baseline
test_runtime_publication_collisions_preserve_exact_raced_objects
test_runtime_publication_preserves_symlink_and_directory_collisions
test_publication_identity_is_propagated_from_verified_boundary
test_install_rollback_retains_post_publication_local_edit
test_install_failed_claim_move_retains_edited_recovery
test_late_failure_removes_new_runtime_assets
test_runtime_asset_checksum_failure_retains_recovery
test_autostart_rollback_failure_retains_mapper_dependency_and_recovery
test_initial_runtime_verification_blocks_boot_mutation
test_final_runtime_verification_blocks_old_retirement
test_rollback_preserves_preexisting_exact_runtime_assets
test_changed_dtbo_is_transactionally_refreshed
test_dkms_source_package_is_allowlisted
test_boot_rollback_failure_continues_cleanup_and_preserves_backup
test_uninstall_dkms_failure_retains_source_and_fails
test_uninstall_dkms_status_failure_leaves_all_assets
test_uninstall_post_remove_status_failure_restores_transaction
test_uninstall_remove_mutate_then_fail_restores_transaction
test_uninstall_each_module_remove_failure_restores_transaction
test_uninstall_boot_config_failure_restores_transaction
test_uninstall_dtbo_failure_restores_transaction
test_uninstall_source_failure_restores_transaction
test_shared_uninstall_assertion_rejects_rollback_failure_output
test_uninstall_accepts_unregistered_dkms
test_uninstall_refuses_unowned_unregistered_source
test_install_accepts_exact_deployed_old_source_baseline
test_install_requires_exact_old_source_ownership
test_uninstall_requires_exact_current_source_ownership
test_install_source_retirement_claim_preserves_race
test_uninstall_source_retirement_claim_preserves_race
test_install_rollback_retains_modified_created_source
test_preexisting_current_added_and_built_lifecycles_are_restored
test_old_retirement_mutate_then_fail_restores_transaction
test_compressed_only_old_and_new_artifacts_migrate_successfully
test_corrupt_compressed_old_preflight_fails_closed
test_corrupt_compressed_old_rollback_verification_is_reported
test_zstd_dispatch_and_checksum_failure_propagation
test_zstd_only_new_artifacts_are_verified
test_migration_removes_old_release_only_after_success_and_ordered_verification
test_old_release_retires_only_after_runtime_assets_verify
test_each_new_module_build_install_and_checksum_failure_restores_old_release
test_install_add_mutate_then_fail_restores_absent_baseline
test_invalid_old_installed_checksum_blocks_migration
test_invalid_old_provider_checksum_blocks_migration
test_invalid_old_panel_checksum_blocks_migration
test_sparse_extra_old_module_metadata_blocks_migration
test_missing_old_provider_metadata_blocks_migration
test_incomplete_snapshot_leaves_old_modules_untouched
test_third_module_install_failure_restores_every_old_module_path
test_failed_new_registration_removal_retains_recovery_source
test_failed_old_reinstall_reports_preserved_recovery
test_failed_old_checksum_verification_preserves_recovery
test_late_failure_after_dtbo_replacement_restores_previous_dtbo
test_old_status_failure_retains_source_and_does_not_claim_success
test_install_rollback_refreshes_dependency_indexes_after_path_suffix_restore
test_uninstall_rollback_refreshes_dependency_indexes_after_path_suffix_restore
test_depmod_rollback_failures_retain_and_report_recovery
test_existing_persistent_backup_uses_private_current_boot_baseline
test_private_boot_restore_failure_retains_and_reports_recovery
test_uninstall_restores_exact_dkms_state_tree_for_every_lifecycle
test_uninstall_state_tree_restore_verification_failure_retains_recovery
printf 'PASS: transactional installer lifecycle\n'
