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
case $1 in
add)
	if [ -e "${DKMS_STATE:?}" ]; then
		exit 1
	fi
	: > "${DKMS_STATE:?}"
	;;
status)
	[ -e "${DKMS_STATE:?}" ] && printf '%s\n' 'rockpi-rpi-touchscreen/0.1.0, test-kernel, aarch64: installed'
	;;
remove)
	rm -f "${DKMS_STATE:?}"
	;;
esac
if [ "${DKMS_FAIL_ON:-}" = "$1" ]; then
	exit 1
fi
EOF
	chmod +x "$sandbox/bin/dkms"
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
if [ -n "${MV_FAIL_SOURCE:-}" ] && [ "$1" = "$MV_FAIL_SOURCE" ]; then
	exit 1
fi
if [ -n "${MV_FAIL_TARGET:-}" ] && [ "$last" = "$MV_FAIL_TARGET" ] &&
	[ ! -e "${MV_FAIL_ONCE_MARKER:?}" ]; then
	: > "$MV_FAIL_ONCE_MARKER"
	exit 1
fi
exec /bin/mv "$@"
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
	MV_LOG="$sandbox/mv.log" PATH="$sandbox/bin:$PATH" \
	sh "$repo_root/scripts/install.sh" "$@"
}

run_uninstall()
{
	sandbox=$1
	shift
	BOOT_DIR="$sandbox/boot" DKMS_TREE="$sandbox/usr-src" \
	MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=test-kernel \
	DKMS_LOG="$sandbox/dkms.log" DKMS_STATE="$sandbox/dkms.state" \
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
	mkdir -p "$target_root/boot" "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.1.0"
	printf '%s\n' 'user_overlays=spi-test rockpi-4b-plus-rpi-touchscreen' > "$target_root/boot/armbianEnv.txt"
	: > "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.1.0/sentinel"
	: > "$sandbox/dkms.log"

	run_offline_boot_rollback "$sandbox" "$target_root"
	assert_equal "$(cat "$target_root/boot/armbianEnv.txt")" 'user_overlays=spi-test' \
		'offline rollback removes only the project token from the explicit target root'
	[ -f "$sandbox/host-usr-src/rockpi-rpi-touchscreen-0.1.0/sentinel" ] ||
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
	grep -Fqx "$original_checksum  $sandbox/boot/armbianEnv.txt" \
		"$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak.sha256" || \
		fail 'backup checksum must describe original boot configuration'
	[ "$(cat "$sandbox/boot/armbianEnv.txt.rockpi-rpi-touchscreen.bak")" = "$original" ] || \
		fail 'backup must equal original boot configuration'
	[ -f "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.0/dkms.conf" ] || \
		fail 'installer must copy owned DKMS source tree'
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
	source_file=$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.0/scripts/dkms-make.sh
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
		find . -type f -exec sha256sum {} \; | sort
	)
}

assert_refresh_failure_preserves_source_and_boot()
{
	sandbox=$1
	failure=$2
	make_sandbox "$sandbox"
	run_install "$sandbox" "$sandbox/validate-pass.sh"
	source=$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.0
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
		source=$1/usr-src/rockpi-rpi-touchscreen-0.1.0
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
	printf '%s\n' "$dry_run" | grep -Fqx "REMOVE: $sandbox/usr-src/rockpi-rpi-touchscreen-0.1.0" ||
		fail 'dry run must print owned source path'
	printf '%s\n' "$dry_run" | grep -Fqx 'user_overlays=spi-test' ||
		fail 'dry run must print resulting overlay line'
	[ -f "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo" ] ||
		fail 'dry run must not remove overlay'

	run_uninstall "$sandbox"
	assert_equal "$(cat "$sandbox/boot/armbianEnv.txt")" \
		'verbosity=1
user_overlays=spi-test
extraargs=console=ttyS2' \
		'uninstall removes only the project overlay token'
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.0"
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.0"
	printf 'PASS: failed validation leaves boot configuration unchanged\n'
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
	assert_file_absent "$sandbox/usr-src/rockpi-rpi-touchscreen-0.1.0"
	assert_file_absent "$sandbox/boot/overlay-user/rockpi-4b-plus-rpi-touchscreen.dtbo"
	printf 'PASS: post-backup failure rolls back owned assets\n'
}

test_install_is_idempotent_and_preserves_unrelated_boot_text
test_reinstall_refreshes_the_owned_dkms_source_tree
test_refresh_copy_failure_preserves_registered_source
test_refresh_swap_failure_preserves_registered_source
test_refresh_post_swap_dkms_failure_restores_registered_source
test_dkms_make_command_suppresses_automatic_kernelrelease
test_uninstall_removes_only_project_token_and_dry_run_is_scoped
test_failed_validation_does_not_mutate_boot_configuration
test_post_backup_failure_rolls_back_owned_assets_and_boot_configuration
test_boot_configuration_uses_atomic_mv_for_update_and_rollback
test_offline_boot_rollback_changes_only_explicit_target_root
printf 'PASS: transactional installer lifecycle\n'
