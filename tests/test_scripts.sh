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
		"$sandbox/modules/test-kernel/build" "$sandbox/bin"
	cat > "$sandbox/boot/armbianEnv.txt" <<'EOF'
verbosity=1
user_overlays=spi-test
extraargs=console=ttyS2
EOF
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
case $1 in
add)
	if [ -f "${DKMS_STATE:?}" ] && grep -Fxq "$version" "$DKMS_STATE"; then
		exit 1
	fi
	printf '%s\n' "$version" >> "${DKMS_STATE:?}"
	;;
build)
	mkdir -p "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/aarch64/module"
	printf '%s\n' "module-$version-$kernel" > "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/aarch64/module/raspits_ft5426.ko"
	printf '%s\n' "panel-module-$version-$kernel" > "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/aarch64/module/panel_rockpi_rpi_touchscreen.ko"
	;;
install)
	mkdir -p "${MODULES_DIR:?}/$kernel/updates/dkms"
	cp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/aarch64/module/raspits_ft5426.ko" \
		"${MODULES_DIR:?}/$kernel/updates/dkms/raspits_ft5426.ko"
	if [ "${DKMS_FAIL_INSTALL_MODULE:-}" = panel_rockpi_rpi_touchscreen ] &&
		[ "$version" = 0.2.0 ]; then
		exit 25
	fi
	cp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/$version/$kernel/aarch64/module/panel_rockpi_rpi_touchscreen.ko" \
		"${MODULES_DIR:?}/$kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	;;
status)
	[ "${DKMS_STATUS_FAIL_VERSION:-}" != "$version" ] || exit 24
	if [ -f "${DKMS_STATE:?}" ]; then
		while IFS= read -r registered; do
			[ -z "$version" ] || [ "$registered" = "$version" ] || continue
			printf '%s\n' "rockpi-rpi-touchscreen/$registered, test-kernel, aarch64: installed"
		done < "$DKMS_STATE"
	fi
	;;
remove)
	[ "${DKMS_REMOVE_GENUINE_FAIL:-0}" -ne 1 ] || exit 23
	if [ "${DKMS_REQUIRE_NEW_STATE_BEFORE_OLD_REMOVE:-0}" -eq 1 ] && [ "$version" = 0.1.1 ]; then
		grep -Eq '(^|[[:space:]])rockpi-4b-plus-rpi-touchscreen($|[[:space:]])' \
			"${BOOT_DIR:?}/armbianEnv.txt" || exit 31
		[ -f "${BOOT_DIR:?}/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] || exit 32
		[ -f "${DKMS_TREE:?}/rockpi-rpi-touchscreen-0.2.0/src/panel_rockpi_rpi_touchscreen.c" ] || exit 35
		[ -f "${BACKUP_PATH:?}" ] && [ -f "${BACKUP_PATH:?}.sha256" ] || exit 36
		sha256sum -c "${BACKUP_PATH:?}.sha256" >/dev/null || exit 37
		cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.0/test-kernel/aarch64/module/raspits_ft5426.ko" \
			"${MODULES_DIR:?}/test-kernel/updates/dkms/raspits_ft5426.ko" || exit 33
		cmp "${DKMS_STATE_DIR:?}/rockpi-rpi-touchscreen/0.2.0/test-kernel/aarch64/module/panel_rockpi_rpi_touchscreen.ko" \
			"${MODULES_DIR:?}/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko" || exit 34
	fi
	if [ -f "${DKMS_STATE:?}" ]; then
		grep -Fxv "$version" "$DKMS_STATE" > "$DKMS_STATE.tmp" || true
		mv "$DKMS_STATE.tmp" "$DKMS_STATE"
	fi
	if [ "$version" = 0.2.0 ]; then
		rm -f "${MODULES_DIR:?}/test-kernel/updates/dkms/raspits_ft5426.ko" \
			"${MODULES_DIR:?}/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	fi
	;;
esac
if [ "${DKMS_FAIL_ON:-}" = "$1" ]; then
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
	printf '%s\n' "${MODULES_DIR:?}/$kernel/updates/dkms/${module}.ko"
	exit 0
fi
case $field in
license) printf '%s\n' 'GPL v2' ;;
vermagic) printf '%s\n' 'test-kernel SMP mod_unload aarch64' ;;
alias)
	case ${module##*/} in
	raspits_ft5426.ko) printf '%s\n' 'of:N*T*Craspits_ft5426' ;;
	panel_rockpi_rpi_touchscreen.ko) printf '%s\n' "${MODINFO_PANEL_ALIAS:-of:N*T*Crockpi,rpi-7inch-touchscreen-panel}" ;;
	*) exit 1 ;;
	esac
	;;
*) exit 1 ;;
esac
EOF
	chmod +x "$sandbox/bin/modinfo"
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
for argument do
	if [ "${CP_FAIL_ARCHIVE:-}" = 1 ] && [ "$argument" = '-a' ]; then
		exit 1
	fi
done
exec /bin/cp "$@"
EOF
	chmod +x "$sandbox/bin/cp"
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
	BOOT_DIR="$sandbox/boot" DKMS_TREE="$sandbox/usr-src" \
	MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=test-kernel \
	BUILD_DIR="$sandbox/build" BACKUP_PATH="$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak" \
	VALIDATE_SCRIPT="$validator" VALIDATE_LOG="$sandbox/validate.log" \
	DKMS_LOG="$sandbox/dkms.log" DKMS_PATH_LOG="$sandbox/dkms.path" DKMS_STATE="$sandbox/dkms.state" \
	DKMS_STATE_DIR="$sandbox/var-lib-dkms" \
	MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
	sh "$repo_root/scripts/install.sh" "$@"
}

assert_module_matches_build()
{
	sandbox=$1
	version=$2
	module=$3
	built=$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/$version/test-kernel/aarch64/module/$module.ko
	installed=$sandbox/modules/test-kernel/updates/dkms/$module.ko
	[ -f "$built" ] || fail "missing built module: $module"
	[ -f "$installed" ] || fail "missing installed module: $module"
	cmp "$built" "$installed" || fail "installed module differs from DKMS build: $module"
}

run_uninstall()
{
	sandbox=$1
	shift
	BOOT_DIR="$sandbox/boot" DKMS_TREE="$sandbox/usr-src" \
	MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=test-kernel \
	DKMS_LOG="$sandbox/dkms.log" DKMS_STATE="$sandbox/dkms.state" \
	DKMS_STATE_DIR="$sandbox/var-lib-dkms" \
	MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
	sh "$repo_root/scripts/uninstall.sh" "$@"
}

run_offline_boot_rollback()
{
	sandbox=$1
	target_root=$2
	BOOT_DIR="$sandbox/host-boot" DKMS_TREE="$sandbox/host-usr-src" \
	DKMS_LOG="$sandbox/dkms.log" MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
	sh "$repo_root/scripts/uninstall.sh" --offline-boot-root "$target_root"
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
	mkdir -p "$target_root/boot" "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.0"
	printf '%s\n' 'user_overlays=spi-test rockpi-4b-plus-rpi-touchscreen' > "$target_root/boot/armbianEnv.txt"
	: > "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.0/sentinel"
	: > "$sandbox/dkms.log"

	run_offline_boot_rollback "$sandbox" "$target_root"
	assert_equal "$(cat "$target_root/boot/armbianEnv.txt")" 'user_overlays=spi-test' \
		'offline rollback removes only the project token from the explicit target root'
	[ -f "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.2.0/sentinel" ] ||
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0/dkms.conf" ] || \
		fail 'installer must copy owned DKMS source tree'
	assert_module_matches_build "$sandbox" 0.2.0 raspits_ft5426
	assert_module_matches_build "$sandbox" 0.2.0 panel_rockpi_rpi_touchscreen
	[ -f "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] || \
		fail 'installer must install user overlay'
	assert_equal "$(stat -c '%a' "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo")" \
		'644' 'installed overlay mode'

	run_install "$sandbox" "$sandbox/validate-pass.sh"
	assert_equal "$(cat "$sandbox/boot/armbianEnv.txt")" "$after_first" \
		'second install is byte-identical'
	printf 'PASS: idempotent install preserves boot configuration and backup\n'
}

test_reinstall_refreshes_the_owned_dkms_source_tree()
{
	sandbox=$workdir/source-refresh
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source_file=$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1/scripts/dkms-make.sh
	rm -f "$source_file"
	[ ! -e "$source_file" ] || fail 'test setup did not remove the stale source helper'

	run_install "$sandbox" "$sandbox/validate-pass.sh"
	[ -x "$source_file" ] || fail 'reinstall did not refresh the owned DKMS source helper'
	printf 'PASS: reinstall refreshes the owned DKMS source tree\n'
}

source_snapshot()
{
	(
		cd "$1"
		find . -printf '%y %m %p %l\n' | sort
		find . -type f -exec sha256sum {} \; | sort
	)
}

assert_refresh_failure_preserves_source_and_boot()
{
	sandbox=$1
	failure=$2
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1
	printf '%s\n' 'old registered source' > "$source/old-source-sentinel"
	source_before=$(source_snapshot "$source")
	boot_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')

	if "$failure" "$sandbox"; then
		fail 'refresh failure was accepted'
	fi
	assert_equal "$(source_snapshot "$source")" "$source_before" \
		'failed refresh restores the registered source byte-for-byte'
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$boot_before" \
		'failed refresh leaves boot configuration unchanged'
}

test_refresh_copy_failure_preserves_registered_source()
{
	refresh_with_copy_failure()
	{
		CP_FAIL_ARCHIVE=1 run_install "$1" "$1/validate-pass.sh"
	}
	assert_refresh_failure_preserves_source_and_boot "$workdir/refresh-copy-failure" refresh_with_copy_failure
	printf 'PASS: refresh copy failure preserves registered source and boot configuration\n'
}

test_refresh_swap_failure_preserves_registered_source()
{
	refresh_with_swap_failure()
	{
		source=$1/usr-src/rockpi-rpi-touchscreen-0.1.1
		MV_FAIL_SOURCE=$source run_install "$1" "$1/validate-pass.sh"
	}
	assert_refresh_failure_preserves_source_and_boot "$workdir/refresh-swap-failure" refresh_with_swap_failure
	printf 'PASS: refresh swap failure preserves registered source and boot configuration\n'
}

test_refresh_post_swap_dkms_failure_restores_registered_source()
{
	refresh_with_dkms_failure()
	{
		DKMS_FAIL_ON=build run_install "$1" "$1/validate-pass.sh"
	}
	assert_refresh_failure_preserves_source_and_boot "$workdir/refresh-dkms-failure" refresh_with_dkms_failure
	printf 'PASS: refresh post-swap DKMS failure restores registered source and boot configuration\n'
}

test_refresh_late_boot_failure_restores_registered_source()
{
	sandbox=$workdir/refresh-late-boot-failure
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1
	printf '%s\n' 'old registered source' > "$source/old-source-sentinel"
	source_before=$(source_snapshot "$source")
	boot_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	if MV_FAIL_TARGET="$sandbox/boot/armbianEnv.txt" \
		MV_FAIL_ONCE_MARKER="$sandbox/late-boot-mv-failed" \
		run_install "$sandbox" "$sandbox/validate-pass.sh"; then
		fail 'refresh accepted a late boot configuration write failure'
	fi
	assert_equal "$(source_snapshot "$source")" "$source_before" \
		'late boot failure restores the registered source identity'
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$boot_before" \
		'late boot failure restores the boot configuration hash'
	printf 'PASS: refresh late boot failure restores registered source and boot configuration\n'
}

test_refresh_rollback_move_failure_preserves_manual_recovery_backup()
{
	sandbox=$workdir/refresh-rollback-move-failure
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1
	printf '%s\n' 'old registered source' > "$source/old-source-sentinel"
	source_before=$(source_snapshot "$source")
	boot_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	output=$sandbox/output
	if DKMS_FAIL_ON=build \
		MV_FAIL_ROLLBACK_PREFIX="$sandbox/usr-src/.rockpi-rpi-touchscreen.previous." \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'refresh accepted a rollback source move failure'
	fi
	previous=$(find "$sandbox/usr-src" -mindepth 1 -maxdepth 1 -type d \
		-name '.rockpi-rpi-touchscreen.previous.*' -print -quit)
	[ -n "$previous" ] || fail 'rollback did not preserve the prior source backup'
	assert_equal "$(source_snapshot "$previous")" "$source_before" \
		'manual recovery backup preserves the registered source identity'
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$boot_before" \
		'rollback move failure leaves boot configuration unchanged'
	grep -Fq 'ERROR: transaction failed with status' "$output" ||
		fail 'rollback move failure did not distinguish the transaction failure'
	grep -Fq "ERROR: manual recovery source backup: $previous" "$output" ||
		fail 'rollback move failure did not print the exact manual recovery backup path'
	printf 'PASS: rollback move failure preserves named manual recovery backup\n'
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
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0" ||
		fail 'dry run must print owned source path'
	printf '%s\n' "$dry_run" | grep -Fqx 'user_overlays=spi-test' ||
		fail 'dry run must print resulting overlay line'
	printf '%s\n' "$dry_run" | grep -Fqx 'MODULE: raspits_ft5426' ||
		fail 'dry run must name the touch module'
	printf '%s\n' "$dry_run" | grep -Fqx 'MODULE: panel_rockpi_rpi_touchscreen' ||
		fail 'dry run must name the panel module'
	[ -f "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] ||
		fail 'dry run must not remove overlay'

	run_uninstall "$sandbox"
	assert_equal "$(cat "$sandbox/boot/armbianEnv.txt")" \
		'verbosity=1
user_overlays=spi-test
extraargs=console=ttyS2' \
		'uninstall removes only the project overlay token'
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: installer requires distinct touch and panel aliases\n'
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: post-backup failure rolls back owned assets\n'
}

test_same_version_changed_source_is_rejected()
{
	sandbox=$workdir/immutable-source
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source_file=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0/scripts/dkms-make.sh
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
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0
	actual=$(cd "$source" && find . -type f -print | LC_ALL=C sort)
	expected='./LICENSE
./LICENSES/GPL-2.0-only.txt
./LICENSES/UPSTREAM.md
./Makefile
./dkms.conf
./scripts/dkms-make.sh
./src/ft5426_protocol.h
./src/panel_rockpi_rpi_touchscreen.c
./src/raspits_ft5426.c'
	assert_equal "$actual" "$expected" 'DKMS source package contains only allowlisted files'
	assert_equal "$(stat -c '%a' "$source")" '755' 'DKMS source root must be traversable'
	assert_equal "$(stat -c '%a' "$source/src")" '755' 'DKMS source subdirectories must be traversable'
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
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
	if DKMS_REMOVE_GENUINE_FAIL=1 run_uninstall "$sandbox" > "$output" 2>&1; then
		fail 'uninstall accepted genuine DKMS removal failure'
	fi
	[ -d "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0" ] ||
		fail 'uninstall removed source after genuine DKMS failure'
	! grep -Fq 'PASS: removed' "$output" ||
		fail 'uninstall printed success after genuine DKMS failure'
	printf 'PASS: genuine DKMS uninstall failure retains source and fails\n'
}

test_uninstall_accepts_unregistered_dkms()
{
	sandbox=$workdir/uninstall-unregistered
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	rm -f "$sandbox/dkms.state"
	run_uninstall "$sandbox"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
	printf 'PASS: uninstall accepts already-unregistered DKMS package\n'
}

seed_old_release()
{
	sandbox=$1
	old=$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1
	mkdir -p "$old"
	printf '%s\n' 'PACKAGE_NAME="rockpi-rpi-touchscreen"' 'PACKAGE_VERSION="0.1.1"' > "$old/dkms.conf"
	printf '%s\n' '0.1.1' > "$sandbox/dkms.state"
	mkdir -p "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.1.1/test-kernel/aarch64/module" \
		"$sandbox/modules/test-kernel/updates/dkms"
	printf '%s\n' 'old-touch-module' > \
		"$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.1.1/test-kernel/aarch64/module/raspits_ft5426.ko"
	cp "$sandbox/var-lib-dkms/rockpi-rpi-touchscreen/0.1.1/test-kernel/aarch64/module/raspits_ft5426.ko" \
		"$sandbox/modules/test-kernel/updates/dkms/raspits_ft5426.ko"
}

test_migration_removes_old_release_only_after_success()
{
	sandbox=$workdir/migration-success
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	DKMS_REQUIRE_NEW_STATE_BEFORE_OLD_REMOVE=1 run_install "$sandbox" "$sandbox/validate-pass.sh"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1"
	grep -Fxq '0.2.0' "$sandbox/dkms.state" || fail 'new DKMS version was not registered'
	! grep -Fxq '0.1.1' "$sandbox/dkms.state" || fail 'old DKMS version remained after successful migration'
	assert_module_matches_build "$sandbox" 0.2.0 raspits_ft5426
	assert_module_matches_build "$sandbox" 0.2.0 panel_rockpi_rpi_touchscreen
	printf 'PASS: successful 0.1.1 to 0.2.0 migration after complete verification\n'
}

test_failed_migration_retains_old_release()
{
	sandbox=$workdir/migration-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	if DKMS_FAIL_ON=build run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'failed migration was accepted'
	fi
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1/dkms.conf" ] ||
		fail 'failed migration removed old source'
	grep -Fxq '0.1.1' "$sandbox/dkms.state" || fail 'failed migration removed old DKMS registration'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
	printf 'PASS: failed migration retains 0.1.1 release\n'
}

test_second_module_install_failure_restores_old_release_and_boot()
{
	sandbox=$workdir/migration-second-module-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	printf '%s\n' 'prior-dtbo' > "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	boot_before=$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')
	dtbo_before=$(sha256sum "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" | awk '{print $1}')
	if DKMS_FAIL_INSTALL_MODULE=panel_rockpi_rpi_touchscreen \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$sandbox/output" 2>&1; then
		fail 'installer accepted failure while installing the second module'
	fi
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1/dkms.conf" ] ||
		fail 'second-module failure removed old source'
	grep -Fxq '0.1.1' "$sandbox/dkms.state" ||
		fail 'second-module failure removed old registration'
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0"
	assert_equal "$(sha256sum "$sandbox/boot/armbianEnv.txt" | awk '{print $1}')" "$boot_before" \
		'second-module failure changed boot configuration'
	assert_equal "$(sha256sum "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" | awk '{print $1}')" "$dtbo_before" \
		'second-module failure changed the prior DTBO'
	assert_module_matches_build "$sandbox" 0.1.1 raspits_ft5426
	assert_file_absent "$sandbox/modules/test-kernel/updates/dkms/panel_rockpi_rpi_touchscreen.ko"
	printf 'PASS: second-module failure restores 0.1.1 modules and preserves boot state\n'
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
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1/dkms.conf" ] ||
		fail 'failed rollback removal lost the old recovery source'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0/dkms.conf" ] ||
		fail 'failed rollback removal stranded new registration without its source'
	grep -Fxq '0.1.1' "$sandbox/dkms.state" || fail 'failed rollback removal lost old registration'
	grep -Fxq '0.2.0' "$sandbox/dkms.state" || fail 'test did not retain failed new registration'
	grep -Fq "new source retained at $sandbox/usr-src/rockpi-rpi-touchscreen-0.2.0" "$output" ||
		fail 'rollback did not report the exact retained new source path'
	assert_module_matches_build "$sandbox" 0.1.1 raspits_ft5426
	printf 'PASS: failed new-registration removal retains exact recovery source\n'
}

test_old_status_failure_retains_source_and_does_not_claim_success()
{
	sandbox=$workdir/migration-status-failure
	make_sandbox "$sandbox"
	seed_old_release "$sandbox"
	output=$sandbox/output
	if DKMS_STATUS_FAIL_VERSION=0.1.1 \
		run_install "$sandbox" "$sandbox/validate-pass.sh" > "$output" 2>&1; then
		fail 'installer accepted unverifiable old DKMS state'
	fi
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.1/dkms.conf" ] ||
		fail 'status failure removed old source'
	grep -Fxq '0.1.1' "$sandbox/dkms.state" || fail 'status failure removed old registration'
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

test_install_is_idempotent_and_preserves_unrelated_boot_text
test_dkms_make_command_suppresses_automatic_kernelrelease
test_uninstall_removes_only_project_token_and_dry_run_is_scoped
test_failed_validation_does_not_mutate_boot_configuration
test_installer_requires_the_panel_specific_alias
test_post_backup_failure_rolls_back_owned_assets_and_boot_configuration
test_boot_configuration_uses_atomic_mv_for_update_and_rollback
test_offline_boot_rollback_changes_only_explicit_target_root
test_same_version_changed_source_is_rejected
test_changed_dtbo_is_transactionally_refreshed
test_dkms_source_package_is_allowlisted
test_boot_rollback_failure_continues_cleanup_and_preserves_backup
test_uninstall_dkms_failure_retains_source_and_fails
test_uninstall_accepts_unregistered_dkms
test_migration_removes_old_release_only_after_success
test_failed_migration_retains_old_release
test_second_module_install_failure_restores_old_release_and_boot
test_failed_new_registration_removal_retains_recovery_source
test_late_failure_after_dtbo_replacement_restores_previous_dtbo
test_old_status_failure_retains_source_and_does_not_claim_success
printf 'PASS: transactional installer lifecycle\n'
