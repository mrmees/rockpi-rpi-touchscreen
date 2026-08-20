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
		"$sandbox/modules/test-kernel/build" "$sandbox/bin" \
		"$sandbox/etc/X11/xorg.conf.d"
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
		0.2.3)
			write_build_artifact panel_rockpi_rpi_touchscreen panel
			write_build_artifact raspits_ft5426 touch
			;;
		0.2.4)
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
		if [ "$version" = 0.2.3 ] && [ "${DKMS_FAIL_OLD_REINSTALL:-0}" -eq 1 ]; then
			exit 26
		fi
		mkdir -p "${MODULES_DIR:?}/$kernel/updates/dkms"
		case $version in
		0.2.3) install_modules='panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
		0.2.4) install_modules='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
		*) exit 18 ;;
		esac
		for module in $install_modules; do
			if [ "$version" = 0.2.4 ]; then
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
			if [ "$version" = 0.2.4 ] && [ "${DKMS_FAIL_INSTALL_MODULE:-}" = "$module" ]; then
				exit 25
			fi
		done
		if [ "$version" = 0.2.3 ]; then
			: > "${DKMS_OLD_REINSTALL_MARKER:?}"
		fi
		if [ "$version" = 0.2.3 ] && [ -n "${DKMS_CORRUPT_OLD_REINSTALL_MODULE:-}" ]; then
			printf '%s\n' corrupt-old-reinstall > \
				"${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/$arch/module/${DKMS_CORRUPT_OLD_REINSTALL_MODULE}.ko"
		fi
		if [ "$version" = 0.2.4 ] && [ -n "${DKMS_FAIL_CHECKSUM_MODULE:-}" ]; then
			printf '%s\n' corrupt-new-install > \
				"${MODULES_DIR:?}/$kernel/updates/dkms/${DKMS_FAIL_CHECKSUM_MODULE}.ko"
		fi
		if [ "${DKMS_NEW_STATUS_PHASE:-}" = built ] && [ "$version" = 0.2.4 ]; then
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
		if [ "$version" = 0.2.4 ] && [ "${DKMS_REMOVE_GENUINE_FAIL:-0}" -eq 1 ]; then
			exit 23
		fi
		if [ "${DKMS_REQUIRE_NEW_STATE_BEFORE_OLD_REMOVE:-0}" -eq 1 ] && [ "$version" = 0.2.3 ]; then
			grep -Eq '(^|[[:space:]])rockpi-4b-plus-rpi-touchscreen($|[[:space:]])' \
				"${BOOT_DIR:?}/armbianEnv.txt" || exit 31
			[ -f "${BOOT_DIR:?}/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] || exit 32
			[ -f "${DKMS_TREE:?}/rockpi-rpi-touchscreen-0.2.4/src/display_compat_main.c" ] || exit 35
			[ -f "${BACKUP_PATH:?}" ] && [ -f "${BACKUP_PATH:?}.sha256" ] || exit 36
			sha256sum -c "${BACKUP_PATH:?}.sha256" >/dev/null || exit 37
			cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.4/test-kernel/aarch64/module/rockpi_rk3399_display_compat.ko" \
				"${MODULES_DIR:?}/test-kernel/updates/dkms/rockpi_rk3399_display_compat.ko" || exit 33
			cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.4/test-kernel/aarch64/module/panel_rockpi_rpi_touchscreen.ko" \
				"${MODULES_DIR:?}/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko" || exit 34
			cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.4/test-kernel/aarch64/module/raspits_ft5426.ko" \
				"${MODULES_DIR:?}/test-kernel/updates/dkms/raspits_ft5426.ko" || exit 33
			[ "$(cat "${DKMS_ACTIVE_STATE:?}")" = 'test-kernel|0.2.4' ] || exit 38
			if [ -f "${DKMS_INSTALLED_STATE:?}" ] &&
				grep -Fxq '0.2.3|test-kernel|aarch64' "$DKMS_INSTALLED_STATE"; then
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
					0.2.3) remove_modules='panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
					0.2.4) remove_modules='rockpi_rk3399_display_compat panel_rockpi_rpi_touchscreen raspits_ft5426' ;;
					*) remove_modules= ;;
					esac
					for module in $remove_modules; do
						rm -f "${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko" \
							"${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko.xz" \
							"${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko.gz" \
							"${MODULES_DIR:?}/$active_kernel/updates/dkms/$module.ko.zst"
						if [ "$version" = 0.2.4 ] && [ "${DKMS_FAIL_REMOVE_MODULE:-}" = "$module" ]; then
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
	if [ "$version" = 0.2.3 ] && [ "${DKMS_FAIL_OLD_REMOVE_AFTER_MUTATION:-0}" -eq 1 ] &&
		[ ! -e "${DKMS_OLD_REMOVE_FAILED_MARKER:?}" ]; then
		: > "$DKMS_OLD_REMOVE_FAILED_MARKER"
		exit 46
	fi
	;;
esac
if [ "$version" = 0.2.4 ] && [ "${DKMS_FAIL_ON:-}" = "$1" ]; then
	exit 1
fi
EOF
	chmod +x "$sandbox/bin/dkms"
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
	module_path=$(find "${MODULES_DIR:?}/$kernel/updates/dkms" -type f \
		\( -name "$module.ko" -o -name "$module.ko.xz" -o -name "$module.ko.gz" \
		-o -name "$module.ko.zst" \) -print | head -n 1)
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
	vermagic) printf '%s\n' 'test-kernel SMP mod_unload aarch64' ;;
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
for argument do
	last=$argument
done
printf '%s\n' "$*" >> "${MV_LOG:?}"
if [ -n "${MV_FAIL_ALWAYS_TARGET:-}" ] && [ "$last" = "$MV_FAIL_ALWAYS_TARGET" ]; then
	exit 1
fi
if [ -n "${MV_FAIL_SOURCE:-}" ] && [ "$1" = "$MV_FAIL_SOURCE" ]; then
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
/bin/mv "$@"
if [ -n "${MV_FAIL_AFTER_TARGET:-}" ] && [ "$last" = "$MV_FAIL_AFTER_TARGET" ] &&
	[ ! -e "${MV_FAIL_AFTER_ONCE_MARKER:?}" ]; then
	: > "$MV_FAIL_AFTER_ONCE_MARKER"
	exit 1
fi
EOF
chmod +x "$sandbox/bin/mv"
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
if [ -n "${CP_FAIL_SNAPSHOT_MODULE:-}" ]; then
	case $source_file:$destination_file in
	*"/modules/test-kernel/"*"/$CP_FAIL_SNAPSHOT_MODULE.ko:"*"/.rockpi-rpi-touchscreen.transaction."*"/prior-modules/"*) exit 29 ;;
	esac
fi
/bin/cp "$@"
if [ "$old_state_restore" -eq 1 ] && [ -n "${DKMS_CORRUPT_OLD_REINSTALL_MODULE:-}" ]; then
	printf '%s\n' corrupt-old-state-restore > \
		"$destination_file/test-kernel/aarch64/module/${DKMS_CORRUPT_OLD_REINSTALL_MODULE}.ko"
fi
if [ "$old_state_restore" -eq 1 ] &&
	[ -n "${DKMS_CORRUPT_COMPRESSED_OLD_ROLLBACK_MODULE:-}" ]; then
	printf '%s\n' corrupt-compressed-old-build > \
		"$destination_file/test-kernel/aarch64/module/${DKMS_CORRUPT_COMPRESSED_OLD_ROLLBACK_MODULE}.ko.xz"
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
if [ -n "${RM_FAIL_TARGET:-}" ] && [ "$last" = "$RM_FAIL_TARGET" ]; then
	exit 30
fi
exec /bin/rm "$@"
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
	protected_before=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	status=0
	BOOT_DIR="$sandbox/boot" DKMS_TREE="$sandbox/usr-src" \
	MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=test-kernel \
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
		ZSTD_LOG="$sandbox/zstd.log" \
		DKMS_STATE_DIR="$sandbox/var-lib-dkms" \
		ARCH=aarch64 MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
		sh "$repo_root/scripts/install.sh" "$@" || status=$?
	protected_after=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	assert_equal "$protected_after" "$protected_before" \
		'installer changed protected HDMI Xorg configuration'
	return "$status"
}

assert_module_matches_build()
{
	sandbox=$1
	version=$2
	module=$3
	built=$(find "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/$version/test-kernel/aarch64/module" \
		-type f \( -name "$module.ko" -o -name "$module.ko.xz" -o -name "$module.ko.gz" \
		-o -name "$module.ko.zst" \) -print | head -n 1)
	installed=$(find "$sandbox/modules/test-kernel/updates/dkms" \
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

run_uninstall()
{
	sandbox=$1
	shift
	protected=$sandbox/etc/X11/xorg.conf.d/20-dfrobot-display.conf
	protected_before=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	status=0
	BOOT_DIR="$sandbox/boot" DKMS_TREE="$sandbox/usr-src" \
	MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=test-kernel \
	DKMS_LOG="$sandbox/dkms.log" \
	DKMS_ADDED_STATE="$sandbox/dkms-added.state" DKMS_BUILT_STATE="$sandbox/dkms-built.state" \
	DKMS_INSTALLED_STATE="$sandbox/dkms-installed.state" DKMS_ACTIVE_STATE="$sandbox/dkms-active.state" \
		DKMS_REMOVE_MARKER="$sandbox/dkms-remove.marker" DKMS_STATUS_FAILED_MARKER="$sandbox/dkms-status-failed.marker" \
		DKMS_OLD_REMOVE_FAILED_MARKER="$sandbox/dkms-old-remove-failed.marker" \
		DKMS_NEW_ACTIVE_VERIFIED_MARKER="$sandbox/dkms-new-active-verified.marker" \
		DKMS_MODULE_LOG="$sandbox/dkms-module.log" SHA256_LOG="$sandbox/sha256.log" \
		DKMS_STATE_DIR="$sandbox/var-lib-dkms" \
		ARCH=aarch64 MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
		sh "$repo_root/scripts/uninstall.sh" "$@" || status=$?
	protected_after=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	assert_equal "$protected_after" "$protected_before" \
		'uninstaller changed protected HDMI Xorg configuration'
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
		DKMS_LOG="$sandbox/dkms.log" ARCH=aarch64 MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
		sh "$repo_root/scripts/uninstall.sh" --offline-boot-root "$target_root" || status=$?
	protected_after=$(/usr/bin/sha256sum "$protected" | awk '{print $1}')
	assert_equal "$protected_after" "$protected_before" \
		'offline rollback changed protected HDMI Xorg configuration'
	return "$status"
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
	mkdir -p "$target_root/boot" "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.4"
	printf '%s\n' 'user_overlays=spi-test rockpi-4b-plus-rpi-touchscreen' > "$target_root/boot/armbianEnv.txt"
	: > "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.4/sentinel"
	: > "$sandbox/dkms.log"

	run_offline_boot_rollback "$sandbox" "$target_root"
	assert_equal "$(cat "$target_root/boot/armbianEnv.txt")" 'user_overlays=spi-test' \
		'offline rollback removes only the project token from the explicit target root'
	[ -f "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.4/sentinel" ] ||
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4/dkms.conf" ] || \
		fail 'installer must copy owned DKMS source tree'
	assert_module_matches_build "$sandbox" 0.2.4 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.4 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.4 raspits_ft5426
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
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4" ||
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	printf 'PASS: scoped uninstall and dry run\n'
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/rockpi_rk3399_display_compat.ko"
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/raspits_ft5426.ko"
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: post-backup failure rolls back owned assets\n'
}

test_same_version_changed_source_is_rejected()
{
	sandbox=$workdir/immutable-source
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source_file=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4/src/display_compat.h
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
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4
	actual=$(cd "$source" && find . -type f -print | LC_ALL=C sort)
	expected='./LICENSE
./LICENSES/GPL-2.0-only.txt
./LICENSES/UPSTREAM.md
./Makefile
./dkms.conf
./scripts/dkms-make.sh
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
	expected_digest_args='ARGS=Makefile dkms.conf src/ft5426_protocol.h src/raspits_ft5426.c src/panel_rockpi_rpi_touchscreen.c src/display_compat.h src/display_compat_core.h src/display_compat_core.c src/display_compat_main.c scripts/dkms-make.sh LICENSE LICENSES/GPL-2.0-only.txt LICENSES/UPSTREAM.md'
	grep -F "$expected_digest_args" "$sandbox/sha256.log" >/dev/null ||
		fail 'DKMS source digest does not cover every provider source and header'
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
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
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4" ] ||
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
	if DKMS_STATUS_FAIL_VERSION=0.2.4 run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'uninstall accepted DKMS status failure'
	fi
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4" ] || fail 'status failure removed source'
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4/dkms.conf" ] ||
		fail 'post-removal uninstall failure did not restore source'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.4)" \
		'rockpi-rpi-touchscreen/0.2.4, test-kernel, aarch64: installed' \
		'post-removal uninstall failure did not restore exact DKMS lifecycle'
	assert_equal "$(cat "$sandbox/dkms-active.state")" 'test-kernel|0.2.4' \
		'post-removal uninstall failure did not restore active version'
	assert_module_matches_build "$sandbox" 0.2.4 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.4 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.4 raspits_ft5426
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
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4
	if RM_FAIL_TARGET="$source" run_uninstall "$sandbox" > "$sandbox/output" 2>&1; then
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	printf 'PASS: uninstall accepts already-unregistered DKMS package\n'
}

test_uninstall_refuses_unowned_unregistered_source()
{
	sandbox=$workdir/uninstall-unowned-source
	make_sandbox "$sandbox"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4
	mkdir -p "$source"
	printf '%s\n' 'PACKAGE_NAME="some-other-package"' 'PACKAGE_VERSION="0.2.4"' > "$source/dkms.conf"
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
	old=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3
	mkdir -p "$old/src" "$old/scripts" "$old/LICENSES"
	cat > "$old/dkms.conf" <<'EOF'
PACKAGE_NAME="rockpi-rpi-touchscreen"
PACKAGE_VERSION="0.2.3"
BUILT_MODULE_NAME[0]="raspits_ft5426"
BUILT_MODULE_LOCATION[0]="."
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="panel_rockpi_rpi_touchscreen"
BUILT_MODULE_LOCATION[1]="."
DEST_MODULE_LOCATION[1]="/updates/dkms"
MAKE[0]="'sh' scripts/dkms-make.sh ${kernelver} make KDIR=/lib/modules/${kernelver}/build modules"
CLEAN="make KDIR=/lib/modules/${kernelver}/build clean"
AUTOINSTALL="yes"
EOF
	printf '%s\n' 'old Makefile' > "$old/Makefile"
	printf '%s\n' 'old license' > "$old/LICENSE"
	printf '%s\n' 'old GPL license' > "$old/LICENSES/GPL-2.0-only.txt"
	printf '%s\n' 'old upstream record' > "$old/LICENSES/UPSTREAM.md"
	printf '%s\n' 'old DKMS make helper' > "$old/scripts/dkms-make.sh"
	printf '%s\n' 'old touch protocol' > "$old/src/ft5426_protocol.h"
	printf '%s\n' 'old touch source' > "$old/src/raspits_ft5426.c"
	printf '%s\n' 'old panel source' > "$old/src/panel_rockpi_rpi_touchscreen.c"
	printf '%s\n' '0.2.3' > "$sandbox/dkms-added.state"
	printf '%s\n' '0.2.3|test-kernel|aarch64' > "$sandbox/dkms-built.state"
	printf '%s\n' '0.2.3|test-kernel|aarch64' > "$sandbox/dkms-installed.state"
	printf '%s\n' 'test-kernel|0.2.3' > "$sandbox/dkms-active.state"
	mkdir -p "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.3/test-kernel/aarch64/module" \
		"$sandbox/modules/test-kernel/updates/dkms"
	printf '%s\n' 'old-panel-module' > \
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.3/test-kernel/aarch64/module/panel_rockpi_rpi_touchscreen.ko"
	printf '%s\n' 'old-touch-module' > \
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.3/test-kernel/aarch64/module/raspits_ft5426.ko"
	cp "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.3/test-kernel/aarch64/module/panel_rockpi_rpi_touchscreen.ko" \
		"$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	cp "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.3/test-kernel/aarch64/module/raspits_ft5426.ko" \
		"$sandbox/modules/test-kernel/updates/dkms/raspits_ft5426.ko"
	printf '%s\n' 'prior-dtbo' > "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
}

compress_old_release_artifacts()
{
	sandbox=$1
	for module in panel_rockpi_rpi_touchscreen raspits_ft5426; do
		built=$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.3/test-kernel/aarch64/module/$module.ko
		installed=$sandbox/modules/test-kernel/updates/dkms/$module.ko
		xz -c "$built" > "$built.xz"
		gzip -c "$installed" > "$installed.gz"
		rm -f "$built" "$installed"
	done
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

capture_migration_baseline()
{
	sandbox=$1
	MIGRATION_OLD_SOURCE_DIGEST=$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3")
	MIGRATION_PANEL_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko" | awk '{print $1}')
	MIGRATION_TOUCH_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/modules/test-kernel/updates/dkms/raspits_ft5426.ko" | awk '{print $1}')
	MIGRATION_BOOT_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	MIGRATION_DTBO_CHECKSUM=$(/usr/bin/sha256sum "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" | awk '{print $1}')
}

assert_clean_failed_migration_restored()
{
	sandbox=$1
	output=$2
	if grep -Eq 'rollback also failed|recovery artifacts retained' "$output"; then
		fail 'ordinary failure did not complete a clean 0.2.3 rollback'
	fi
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.3)" \
		'rockpi-rpi-touchscreen/0.2.3, test-kernel, aarch64: installed' \
		'failure did not restore exact old DKMS lifecycle'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.4)" '' \
		'failure retained the new DKMS lifecycle'
	assert_equal "$(cat "$sandbox/dkms-active.state")" 'test-kernel|0.2.3' \
		'failure did not reactivate the old target-kernel version'
	assert_equal "$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3")" \
		"$MIGRATION_OLD_SOURCE_DIGEST" 'failure changed the old source tree'
	assert_equal "$(/usr/bin/sha256sum "$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko" | awk '{print $1}')" \
		"$MIGRATION_PANEL_CHECKSUM" 'failure changed old panel module bytes'
	assert_equal "$(/usr/bin/sha256sum "$sandbox/modules/test-kernel/updates/dkms/raspits_ft5426.ko" | awk '{print $1}')" \
		"$MIGRATION_TOUCH_CHECKSUM" 'failure changed old touch module bytes'
	assert_module_matches_build "$sandbox" 0.2.3 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.3 raspits_ft5426
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/rockpi_rk3399_display_compat.ko"
	assert_equal "$(/usr/bin/sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" \
		"$MIGRATION_BOOT_CHECKSUM" 'failure changed boot configuration'
	assert_equal "$(/usr/bin/sha256sum "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" | awk '{print $1}')" \
		"$MIGRATION_DTBO_CHECKSUM" 'failure changed the prior DTBO'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	assert_file_absent "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.4"
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
	find "$sandbox/modules/test-kernel" -type f \
		\( -name 'rockpi_rk3399_display_compat.ko*' \
		-o -name 'panel_rockpi_rpi_touchscreen.ko*' \
		-o -name 'raspits_ft5426.ko*' \) -delete
	case $phase in
	added)
		rm -f "$sandbox/dkms-built.state"
		rm -rf "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.4"
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
		status_before=$(sandbox_dkms_status "$sandbox" 0.2.4)
		source_before=$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4")
		if [ "$phase" = built ]; then
			build_before=$(source_tree_digest "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.4")
		fi
		if MODINFO_PANEL_ALIAS='of:N*T*Craspits_ft5426' \
			run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
			fail "installer accepted a late failure from a pre-existing $phase baseline"
		fi
		assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.4)" "$status_before" \
			"failure did not restore exact pre-existing $phase lifecycle"
		assert_equal "$(source_tree_digest "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4")" \
			"$source_before" "failure changed pre-existing $phase source"
		case $phase in
		added)
			assert_file_absent "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.4"
			;;
		built)
			assert_equal "$(source_tree_digest "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.4")" \
				"$build_before" 'failure changed pre-existing built artifacts'
			;;
		esac
		grep -Eq 'rollback also failed|recovery artifacts retained' "$sandbox/output" &&
			fail "pre-existing $phase baseline did not roll back cleanly"
	done
	printf 'PASS: pre-existing added and built 0.2.4 lifecycles restore exactly\n'
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
	assert_module_matches_build "$sandbox" 0.2.4 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.4 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.4 raspits_ft5426
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.3)" '' \
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
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.3/test-kernel/aarch64/module/panel_rockpi_rpi_touchscreen.ko.xz"
	printf '%s\n' corrupt-gzip > \
		"$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko.gz"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted two failed old compressed checksum operations as equal'
	fi
	grep -Fq 'cannot verify old DKMS-built panel_rockpi_rpi_touchscreen module content' \
		"$sandbox/output" || fail 'installer did not report the corrupt compressed old build artifact'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.3)" \
		'rockpi-rpi-touchscreen/0.2.3, test-kernel, aarch64: installed' \
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3/dkms.conf" ] ||
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
		[ -f "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.2.4/test-kernel/aarch64/module/$module.ko.zst" ] ||
			fail "missing zstd-only DKMS build artifact: $module"
		[ -f "$sandbox/modules/test-kernel/updates/dkms/$module.ko.zst" ] ||
			fail "missing zstd-only installed artifact: $module"
		PATH="$sandbox/bin:$PATH" ZSTD_LOG="$sandbox/zstd.log" \
			assert_module_matches_build "$sandbox" 0.2.4 "$module"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.4)" \
		'rockpi-rpi-touchscreen/0.2.4, test-kernel, aarch64: installed' \
		'new DKMS version did not reach exact installed state'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.3)" '' \
		'old DKMS lifecycle remained after successful migration'
	assert_equal "$(cat "$sandbox/dkms-active.state")" 'test-kernel|0.2.4' \
		'new DKMS version is not the sole active target-kernel version'
	[ -f "$sandbox/dkms-new-active-verified.marker" ] ||
		fail 'migration did not prove old installed tuple was deactivated before removal'
	assert_module_matches_build "$sandbox" 0.2.4 rockpi_rk3399_display_compat
	assert_module_matches_build "$sandbox" 0.2.4 panel_rockpi_rpi_touchscreen
	assert_module_matches_build "$sandbox" 0.2.4 raspits_ft5426
	assert_equal "$(cat "$sandbox/dkms-module.log")" 'build 0.2.4 rockpi_rk3399_display_compat
build 0.2.4 panel_rockpi_rpi_touchscreen
build 0.2.4 raspits_ft5426
install 0.2.4 rockpi_rk3399_display_compat
install 0.2.4 panel_rockpi_rpi_touchscreen
install 0.2.4 raspits_ft5426' 'new modules were not built and installed in dependency-safe order'
	printf 'PASS: successful 0.2.3 to 0.2.4 migration after ordered complete verification\n'
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
	printf 'PASS: every new-module build, install, and checksum failure restores exact 0.2.3 state\n'
}

test_install_add_mutate_then_fail_restores_absent_baseline()
{
	sandbox=$workdir/install-add-mutate-failure
	make_sandbox "$sandbox"
	config_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	if DKMS_FAIL_ON=add run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted a DKMS add that mutated state before failing'
	fi
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.4)" '' \
		'mutate-then-fail DKMS add did not restore the absent registration baseline'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/rockpi_rk3399_display_compat.ko"
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/raspits_ft5426.ko"
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$config_before" \
		'mutate-then-fail DKMS add changed boot configuration'
	grep -Fqx 'remove -m rockpi-rpi-touchscreen -v 0.2.4 --all' "$sandbox/dkms.log" ||
		fail 'mutate-then-fail DKMS add did not remove the newly created registration'
	printf 'PASS: mutate-then-fail DKMS add restores absent registration baseline\n'
}

test_invalid_old_installed_checksum_blocks_migration()
{
	sandbox=$workdir/invalid-old-checksum
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	printf '%s\n' 'corrupt-old-touch-module' > \
		"$sandbox/modules/test-kernel/updates/dkms/raspits_ft5426.ko"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer migrated from an invalid old installed checksum'
	fi
	grep -Fq 'old installed raspits_ft5426 module does not match its DKMS build' "$sandbox/output" ||
		fail 'installer did not explain the invalid old rollback baseline'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.3)" \
		'rockpi-rpi-touchscreen/0.2.3, test-kernel, aarch64: installed' \
		'invalid old checksum preflight changed old lifecycle state'
	printf 'PASS: invalid old installed checksum blocks migration before mutation\n'
}

test_invalid_old_panel_checksum_blocks_migration()
{
	sandbox=$workdir/invalid-old-panel-checksum
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	printf '%s\n' 'corrupt-old-panel-module' > \
		"$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer migrated from an invalid old panel checksum'
	fi
	grep -Fq 'old installed panel_rockpi_rpi_touchscreen module does not match its DKMS build' \
		"$sandbox/output" || fail 'installer did not explain the invalid old panel baseline'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4"
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.3)" \
		'rockpi-rpi-touchscreen/0.2.3, test-kernel, aarch64: installed' \
		'invalid old panel checksum preflight changed old lifecycle state'
	printf 'PASS: invalid old panel checksum blocks migration before mutation\n'
}

test_sparse_extra_old_module_metadata_blocks_migration()
{
	sandbox=$workdir/sparse-extra-old-module
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	cat >> "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3/dkms.conf" <<'EOF'
BUILT_MODULE_NAME[10]="unexpected_old_module"
BUILT_MODULE_LOCATION[10]="."
DEST_MODULE_LOCATION[10]="/updates/dkms"
EOF
	capture_migration_baseline "$sandbox"
	if run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted sparse extra-module metadata in the old release'
	fi
	grep -Fq 'registered old DKMS source is not the faithful two-module 0.2.3 release' "$sandbox/output" ||
		fail 'installer did not explain the unfaithful old source metadata'
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	printf 'PASS: sparse extra old-module metadata blocks migration before mutation\n'
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
	extra_old_module=$sandbox/modules/test-kernel/weak-updates/raspits_ft5426.ko.xz
	mkdir -p "$(dirname -- "$extra_old_module")"
	printf '%s\n' 'old-compressed-touch-module' > "$extra_old_module"
	extra_old_checksum=$(/usr/bin/sha256sum "$extra_old_module" | awk '{print $1}')
	capture_migration_baseline "$sandbox"
	if DKMS_FAIL_INSTALL_MODULE=raspits_ft5426 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted failure while installing the third module'
	fi
	assert_clean_failed_migration_restored "$sandbox" "$sandbox/output"
	grep -Fqx 'install -m rockpi-rpi-touchscreen -v 0.2.3 -k test-kernel' "$sandbox/dkms.log" ||
		fail 'rollback did not reinstall old target-kernel version through DKMS'
	assert_equal "$(/usr/bin/sha256sum "$extra_old_module" | awk '{print $1}')" "$extra_old_checksum" \
		'third-module failure did not restore every prior touch module path'
	printf 'PASS: third-module failure restores all 0.2.3 module paths and boot state\n'
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3/dkms.conf" ] ||
		fail 'failed rollback removal lost the old recovery source'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4/dkms.conf" ] ||
		fail 'failed rollback removal stranded new registration without its source'
	assert_equal "$(sandbox_dkms_status "$sandbox" 0.2.3)" \
		'rockpi-rpi-touchscreen/0.2.3, test-kernel, aarch64: installed' \
		'failed rollback removal lost exact old installed state'
	[ -n "$(sandbox_dkms_status "$sandbox" 0.2.4)" ] || fail 'test did not retain failed new registration'
	grep -Fq "new source retained at $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.4" "$output" ||
		fail 'rollback did not report the exact retained new source path'
	assert_module_matches_build "$sandbox" 0.2.3 raspits_ft5426
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3/dkms.conf" ] ||
		fail 'old reinstall failure removed old source'
	recovery=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.transaction.*' -print -quit)
	[ -n "$recovery" ] || fail 'old reinstall failure discarded private recovery artifacts'
	grep -Fq "old DKMS reinstall failed; retained old source at $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3" "$output" ||
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3/dkms.conf" ] ||
		fail 'old checksum verification failure removed the old source'
	printf 'PASS: failed old checksum verification preserves and reports recovery artifacts\n'
}

test_old_status_failure_retains_source_and_does_not_claim_success()
{
	sandbox=$workdir/migration-status-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	output=$sandbox/output
	if DKMS_STATUS_FAIL_VERSION=0.2.3 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'installer accepted unverifiable old DKMS state'
	fi
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.3/dkms.conf" ] ||
		fail 'status failure removed old source'
	assert_equal "$(DKMS_STATUS_FAIL_VERSION= sandbox_dkms_status "$sandbox" 0.2.3)" \
		'rockpi-rpi-touchscreen/0.2.3, test-kernel, aarch64: installed' \
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

if [ -n "${TEST_FILTER:-}" ]; then
	"$TEST_FILTER"
	exit 0
fi

test_install_is_idempotent_and_preserves_unrelated_boot_text
test_install_handoff_requires_authorized_dsi_first_acceptance
test_dkms_make_command_suppresses_automatic_kernelrelease
test_uninstall_removes_only_project_token_and_dry_run_is_scoped
test_failed_validation_does_not_mutate_boot_configuration
test_installer_requires_the_panel_specific_alias
test_installer_requires_the_provider_specific_alias
test_installer_rejects_built_only_dkms_status
test_post_backup_failure_rolls_back_owned_assets_and_boot_configuration
test_boot_configuration_uses_atomic_mv_for_update_and_rollback
test_offline_boot_rollback_changes_only_explicit_target_root
test_same_version_changed_source_is_rejected
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
test_preexisting_current_added_and_built_lifecycles_are_restored
test_old_retirement_mutate_then_fail_restores_transaction
test_compressed_only_old_and_new_artifacts_migrate_successfully
test_corrupt_compressed_old_preflight_fails_closed
test_corrupt_compressed_old_rollback_verification_is_reported
test_zstd_dispatch_and_checksum_failure_propagation
test_zstd_only_new_artifacts_are_verified
test_migration_removes_old_release_only_after_success_and_ordered_verification
test_each_new_module_build_install_and_checksum_failure_restores_old_release
test_install_add_mutate_then_fail_restores_absent_baseline
test_invalid_old_installed_checksum_blocks_migration
test_invalid_old_panel_checksum_blocks_migration
test_sparse_extra_old_module_metadata_blocks_migration
test_incomplete_snapshot_leaves_old_modules_untouched
test_third_module_install_failure_restores_every_old_module_path
test_failed_new_registration_removal_retains_recovery_source
test_failed_old_reinstall_reports_preserved_recovery
test_failed_old_checksum_verification_preserves_recovery
test_late_failure_after_dtbo_replacement_restores_previous_dtbo
test_old_status_failure_retains_source_and_does_not_claim_success
printf 'PASS: transactional installer lifecycle\n'
