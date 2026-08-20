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

test_two_module_package_metadata()
{
	metadata=$(bash -c '. "$1"; printf "%s\n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "${BUILT_MODULE_NAME[0]-}" "${BUILT_MODULE_NAME[1]-}" "${BUILT_MODULE_LOCATION[0]-}" "${BUILT_MODULE_LOCATION[1]-}" "${DEST_MODULE_LOCATION[0]-}" "${DEST_MODULE_LOCATION[1]-}"' sh "$repo_root/dkms.conf")
	expected='rockpi-rpi-touchscreen
0.2.1
raspits_ft5426
panel_rockpi_rpi_touchscreen
.
.
/updates/dkms
/updates/dkms'
	[ "$metadata" = "$expected" ] || fail 'DKMS metadata does not describe the two-module 0.2.1 package'
	printf 'PASS: DKMS metadata owns both modules at version 0.2.1\n'
}

make_sandbox()
{
	sandbox=$1
	mkdir -p "$sandbox/bin" "$sandbox/modules/target-kernel/build/include/generated"
	cat > "$sandbox/bin/make" <<'EOF'
#!/bin/sh
set -eu
printf 'CC=%s ARGS=%s\n' "${CC:-}" "$*" >> "${DKMS_MAKE_LOG:?}"
EOF
	chmod +x "$sandbox/bin/make"
}

run_dkms_make()
{
	sandbox=$1
	shift
	command=$(kernelver=target-kernel bash -c '. "$1"; printf "%s" "${MAKE[0]}"' sh "$repo_root/dkms.conf")
	case $command in
	*KERNELRELEASE*) fail 'DKMS make command must not embed KERNELRELEASE' ;;
	esac
	(
		cd "$repo_root"
		MODULES_DIR="$sandbox/modules" DKMS_MAKE_LOG="$sandbox/make.log" \
		PATH="$sandbox/bin:/usr/bin:/bin" sh -c "$command" "$@"
	)
}

test_autonomous_dkms_make_uses_target_kernel_compiler()
{
	sandbox=$workdir/matching
	make_sandbox "$sandbox"
	printf '%s\n' '#define LINUX_COMPILER "test-kernel-gcc (Debian 14.2.0-19) 14.2.0"' > \
		"$sandbox/modules/target-kernel/build/include/generated/compile.h"
	cat > "$sandbox/bin/test-kernel-gcc" <<'EOF'
#!/bin/sh
printf '%s\n' 'test-kernel-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0'
EOF
	cat > "$sandbox/bin/test-kernel-gcc-14" <<'EOF'
#!/bin/sh
case ${0##*/} in
test-kernel-gcc) printf '%s\n' 'test-kernel-gcc (Debian 14.2.0-19) 14.2.0' ;;
*) printf '%s\n' 'test-kernel-gcc-14 (Debian 14.2.0-19) 14.2.0' ;;
esac
EOF
	chmod +x "$sandbox/bin/test-kernel-gcc" "$sandbox/bin/test-kernel-gcc-14"

	run_dkms_make "$sandbox"
	grep -Eq '^CC= ARGS=KDIR=/lib/modules/target-kernel/build modules CC=.*/module-compiler/test-kernel-gcc$' \
		"$sandbox/make.log" || fail 'autonomous DKMS make did not select the exact target-kernel compiler'
	printf 'PASS: autonomous DKMS make selects the target-kernel compiler\n'
}

test_autonomous_dkms_make_rejects_unmatched_compiler()
{
	sandbox=$workdir/unmatched
	make_sandbox "$sandbox"
	printf '%s\n' '#define LINUX_COMPILER "test-kernel-gcc (Debian 14.2.0-19) 14.2.0"' > \
		"$sandbox/modules/target-kernel/build/include/generated/compile.h"
	cat > "$sandbox/bin/test-kernel-gcc" <<'EOF'
#!/bin/sh
printf '%s\n' 'test-kernel-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0'
EOF
	chmod +x "$sandbox/bin/test-kernel-gcc"
	if run_dkms_make "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'autonomous DKMS make accepted an unmatched compiler'
	fi
	grep -Fq 'no compiler matches the kernel banner' "$sandbox/output" ||
		fail 'autonomous DKMS make did not report the strict compiler mismatch'
	[ ! -e "$sandbox/make.log" ] || fail 'unmatched compiler reached make'
	printf 'PASS: autonomous DKMS make rejects an unmatched compiler\n'
}

test_two_module_package_metadata
test_autonomous_dkms_make_uses_target_kernel_compiler
test_autonomous_dkms_make_rejects_unmatched_compiler
printf 'PASS: DKMS autonomous compiler selection\n'
