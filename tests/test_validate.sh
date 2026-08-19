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

make_validate_sandbox()
{
	sandbox=$1
	mkdir -p "$sandbox/bin" "$sandbox/boot/dtb" "$sandbox/modules/test-kernel/build" "$sandbox/build"
	printf '%s\n' 'fdtfile=test.dtb' > "$sandbox/boot/armbianEnv.txt"
	: > "$sandbox/boot/dtb/test.dtb"
	printf 'radxa,rockpi4b-plus\000' > "$sandbox/compatible"
cat > "$sandbox/bin/make" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "${MAKE_LOG:?}"
[ -z "${MAKE_CC_LOG:-}" ] || printf '%s\n' "${CC:-}" >> "$MAKE_CC_LOG"
case " $* " in
*' modules '*)
	[ -z "${MAKE_DIAGNOSTIC:-}" ] || printf '%s\n' "$MAKE_DIAGNOSTIC" >&2
	rm -f "${REPO_ROOT:?}/raspits_ft5426.ko" "${REPO_ROOT:?}/panel_rockpi_rpi_touchscreen.ko"
	: > "${REPO_ROOT:?}/raspits_ft5426.ko"
	: > "${REPO_ROOT:?}/panel_rockpi_rpi_touchscreen.ko"
	;;
esac
EOF
	chmod +x "$sandbox/bin/make"
	cat > "$sandbox/bin/modinfo" <<'EOF'
#!/bin/sh
set -eu
field=$2
module=${3##*/}
case "$field:$module" in
license:raspits_ft5426.ko|license:panel_rockpi_rpi_touchscreen.ko) printf '%s\n' 'GPL v2' ;;
vermagic:raspits_ft5426.ko|vermagic:panel_rockpi_rpi_touchscreen.ko) printf '%s\n' 'test-kernel SMP mod_unload aarch64' ;;
alias:raspits_ft5426.ko) printf '%s\n' 'of:N*T*Craspits_ft5426' ;;
alias:panel_rockpi_rpi_touchscreen.ko) printf '%s\n' 'of:N*T*Crockpi,rpi-7inch-touchscreen-panel' ;;
*) exit 1 ;;
esac
EOF
	chmod +x "$sandbox/bin/modinfo"
	cat > "$sandbox/bin/fdtoverlay" <<'EOF'
#!/bin/sh
set -eu
last=
for argument do
	last=$argument
done
: > "$last"
EOF
	chmod +x "$sandbox/bin/fdtoverlay"
	cat > "$sandbox/bin/dtc" <<'EOF'
#!/bin/sh
set -eu
output=
input=
while [ "$#" -gt 0 ]; do
	case $1 in
	-o) output=$2; shift 2 ;;
	*) input=$1; shift ;;
	esac
done
case $input in
*.dts)
	: > "$output"
	[ -z "${DTC_COMPILE_DIAGNOSTIC:-}" ] || printf '%s\n' "$DTC_COMPILE_DIAGNOSTIC" >&2
	;;
*merged.dtb)
	if [ "${MERGED_VARIANT:-valid}" = 'dsi0-enabled' ]; then
		dsi0_status='status = "okay";'
	elif [ "${MERGED_VARIANT:-valid}" = 'dsi0-nested-status' ]; then
		dsi0_status=
	else
		dsi0_status='status = "disabled";'
	fi
	cat > "$output" <<EOF_DTS
dsi@ff960000 {
	$dsi0_status
	child {
		status = "okay";
	};
};
dsi@ff968000 {
	status = "okay";
	port@1 {
		endpoint {
			phandle = <0x30>;
			remote-endpoint = <0x11>;
		};
	};
	endpoint@0 {
		status = "disabled";
	};
	endpoint@1 {
		status = "okay";
		remote-endpoint = <0x10>;
		phandle = <0x20>;
	};
};
i2c@ff110000 {
	panel@45 {
		compatible = "${PANEL_COMPATIBLE:-rockpi,rpi-7inch-touchscreen-panel}";
		reg = <0x45>;
		port {
			endpoint {
				phandle = <0x11>;
				remote-endpoint = <0x30>;
			};
		};
	};
	touchscreen@38 {
		compatible = "raspits_ft5426";
		reg = <0x38>;
		touchscreen-size-x = <0x320>;
		touchscreen-size-y = <0x1e0>;
	};
};
vop@ff8f0000 {
	endpoint@3 {
		phandle = <0x10>;
		remote-endpoint = <0x20>;
	};
};
hdmi@ff940000 {
	status = "okay";
};
EOF_DTS
	[ -z "${DTC_MERGED_DIAGNOSTIC:-}" ] || printf '%s\n' "$DTC_MERGED_DIAGNOSTIC" >&2
	;;
*)
	cat > "$output" <<'EOF_DTS'
__symbols__ {
	mipi_dsi = "/dsi@ff960000";
	mipi_dsi1 = "/dsi@ff968000";
	mipi1_in_vopl = "/dsi@ff968000/endpoint@1";
	mipi1_in_vopb = "/dsi@ff968000/endpoint@0";
	vopl_out_mipi1 = "/vop@ff8f0000/endpoint@3";
	i2c1 = "/i2c@ff110000";
};
EOF_DTS
	[ -z "${DTC_BASE_DIAGNOSTIC:-}" ] || printf '%s\n' "$DTC_BASE_DIAGNOSTIC" >&2
	;;
esac
EOF
	chmod +x "$sandbox/bin/dtc"
}

run_validate()
{
	sandbox=$1
	shift
	BOOT_DIR="$sandbox/boot" MODULES_DIR="$sandbox/modules" KERNEL_RELEASE=test-kernel \
	COMPATIBLE_FILE="$sandbox/compatible" BUILD_DIR="$sandbox/build" \
	MAKE_LOG="$sandbox/make.log" MAKE_CC_LOG="$sandbox/make-cc.log" PATH="$sandbox/bin:$PATH" \
	REPO_ROOT="$repo_root" \
	sh "$repo_root/scripts/validate.sh" --offline "$@"
}

test_old_upstream_panel_compatible_fails_validation()
{
	sandbox=$workdir/upstream-panel-compatible
	make_validate_sandbox "$sandbox"
	if PANEL_COMPATIBLE='raspberrypi,7inch-touchscreen-panel' run_validate "$sandbox"; then
		fail 'validator accepted the upstream panel compatible on the RK3399 route'
	fi
	printf 'PASS: upstream panel compatible fails validation\n'
}

test_validator_checks_distinct_module_aliases()
{
	sandbox=$workdir/module-aliases
	make_validate_sandbox "$sandbox"
	cat > "$sandbox/bin/modinfo" <<'EOF'
#!/bin/sh
set -eu
case "$2" in
license) printf '%s\n' 'GPL v2' ;;
vermagic) printf '%s\n' 'test-kernel SMP mod_unload aarch64' ;;
alias) printf '%s\n' 'of:N*T*Craspits_ft5426' ;;
*) exit 1 ;;
esac
EOF
	chmod +x "$sandbox/bin/modinfo"
	if run_validate "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'validator accepted the touch alias for the panel module'
	fi
	grep -Fq 'panel module metadata is missing project device-tree alias' "$sandbox/output" ||
		fail 'validator did not identify the panel alias failure'
	printf 'PASS: validator requires distinct aliases for both modules\n'
}

test_module_warning_fails_validation()
{
	sandbox=$workdir/module-warning
	make_validate_sandbox "$sandbox"
	if MAKE_DIAGNOSTIC='warning: unsafe module build' run_validate "$sandbox"; then
		fail 'module build warning was accepted'
	fi
	printf 'PASS: module warnings fail validation\n'
}

test_overlay_warning_fails_validation()
{
	sandbox=$workdir/overlay-warning
	make_validate_sandbox "$sandbox"
	if DTC_COMPILE_DIAGNOSTIC='Warning (unit_address_vs_reg): unexpected overlay node' run_validate "$sandbox"; then
		fail 'overlay compiler warning was accepted'
	fi
	printf 'PASS: overlay warnings fail validation\n'
}

test_unexpected_base_dtb_warning_fails_validation()
{
	sandbox=$workdir/base-warning
	make_validate_sandbox "$sandbox"
	if DTC_BASE_DIAGNOSTIC='Warning (unit_address_vs_reg): unexpected base node' run_validate "$sandbox"; then
		fail 'unexpected base DTB warning was accepted'
	fi
	printf 'PASS: unexpected base DTB warnings fail validation\n'
}

test_documented_base_dtb_diagnostics_are_filtered()
{
	sandbox=$workdir/documented-base-diagnostics
	make_validate_sandbox "$sandbox"
	diagnostic='Warning (unit_address_vs_reg): /usb@fe800000: node has a unit name, but no reg or ranges property'
	DTC_BASE_DIAGNOSTIC="$diagnostic" DTC_MERGED_DIAGNOSTIC="$diagnostic" run_validate "$sandbox"
	printf 'PASS: documented base DTB diagnostics are filtered\n'
}

test_validate_uses_kernel_build_for_clean_and_scoped_merged_tree_checks()
{
	sandbox=$workdir/scoped-tree
	make_validate_sandbox "$sandbox"
	if MERGED_VARIANT=dsi0-enabled run_validate "$sandbox"; then
		fail 'enabled unused DSI0 was accepted by merged-tree validation'
	fi
	grep -Fqx -- "-C $repo_root KDIR=$sandbox/modules/test-kernel/build clean" "$sandbox/make.log" ||
		fail 'make clean did not receive the selected kernel build path'
	printf 'PASS: scoped merged-tree checks and KDIR clean\n'
}

test_nested_status_cannot_satisfy_direct_parent_check()
{
	sandbox=$workdir/direct-parent-status
	make_validate_sandbox "$sandbox"
	if MERGED_VARIANT=dsi0-nested-status run_validate "$sandbox"; then
		fail 'nested child status was accepted as DSI0 parent status'
	fi
	printf 'PASS: status checks require the direct parent\n'
}

test_validator_atomically_replaces_read_only_dtbo()
{
	sandbox=$workdir/read-only-dtbo
	make_validate_sandbox "$sandbox"
	: > "$sandbox/build/rockpi-4b-plus-rpi-touchscreen.dtbo"
	chmod 0444 "$sandbox/build/rockpi-4b-plus-rpi-touchscreen.dtbo"
	run_validate "$sandbox"
	[ -w "$sandbox/build/rockpi-4b-plus-rpi-touchscreen.dtbo" ] ||
		fail 'validator did not replace the read-only DTBO with a writable artifact'
	printf 'PASS: validator atomically replaces a read-only DTBO\n'
}

test_validate_uses_the_kernel_recorded_compiler()
{
	sandbox=$workdir/kernel-compiler
	make_validate_sandbox "$sandbox"
	mkdir -p "$sandbox/modules/test-kernel/build/include/generated"
	printf '%s\n' '#define LINUX_COMPILER "test-kernel-gcc 1.0"' > \
		"$sandbox/modules/test-kernel/build/include/generated/compile.h"
	cat > "$sandbox/bin/test-kernel-gcc" <<'EOF'
#!/bin/sh
printf '%s\n' 'test-kernel-gcc 1.0'
EOF
	chmod +x "$sandbox/bin/test-kernel-gcc"
	run_validate "$sandbox"
	grep -Eq -- "-C $repo_root KDIR=$sandbox/modules/test-kernel/build W=1 modules CC=.*/module-compiler/test-kernel-gcc$" "$sandbox/make.log" ||
		fail 'module build did not use the kernel-recorded compiler'
	printf 'PASS: kernel-recorded compiler is used\n'
}

test_versioned_compiler_is_shimmed_to_the_kernel_recorded_name()
{
	sandbox=$workdir/versioned-compiler
	make_validate_sandbox "$sandbox"
	mkdir -p "$sandbox/modules/test-kernel/build/include/generated"
	printf '%s\n' '#define LINUX_COMPILER "aarch64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0"' > \
		"$sandbox/modules/test-kernel/build/include/generated/compile.h"
	cat > "$sandbox/bin/aarch64-linux-gnu-gcc" <<'EOF'
#!/bin/sh
printf '%s\n' 'aarch64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0'
EOF
	cat > "$sandbox/bin/aarch64-linux-gnu-gcc-14" <<'EOF'
#!/bin/sh
case ${0##*/} in
aarch64-linux-gnu-gcc) printf '%s\n' 'aarch64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0' ;;
*) printf '%s\n' 'aarch64-linux-gnu-gcc-14 (Debian 14.2.0-19) 14.2.0' ;;
esac
EOF
	chmod +x "$sandbox/bin/aarch64-linux-gnu-gcc" "$sandbox/bin/aarch64-linux-gnu-gcc-14"
	run_validate "$sandbox"
	grep -Eq -- "-C $repo_root KDIR=$sandbox/modules/test-kernel/build W=1 modules CC=.*/module-compiler/aarch64-linux-gnu-gcc$" "$sandbox/make.log" ||
		fail 'versioned compiler was not shimmed to the kernel-recorded name'
	printf 'PASS: versioned compiler matches the kernel compiler banner\n'
}

test_unmatched_kernel_compiler_is_rejected_before_module_build()
{
	sandbox=$workdir/unmatched-compiler
	make_validate_sandbox "$sandbox"
	mkdir -p "$sandbox/modules/test-kernel/build/include/generated"
	printf '%s\n' '#define LINUX_COMPILER "test-kernel-gcc (Debian 14.2.0-19) 14.2.0"' > \
		"$sandbox/modules/test-kernel/build/include/generated/compile.h"
	cat > "$sandbox/bin/test-kernel-gcc" <<'EOF'
#!/bin/sh
printf '%s\n' 'test-kernel-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0'
EOF
	chmod +x "$sandbox/bin/test-kernel-gcc"
	if run_validate "$sandbox" > "$sandbox/output" 2>&1; then
		fail 'validator accepted an unmatched compiler banner'
	fi
	grep -Fq 'no compiler matches the kernel banner' "$sandbox/output" ||
		fail 'validator did not explain the unmatched compiler banner'
	printf 'PASS: unmatched compiler banner fails validation\n'
}

test_module_warning_fails_validation
test_old_upstream_panel_compatible_fails_validation
test_validator_checks_distinct_module_aliases
test_overlay_warning_fails_validation
test_unexpected_base_dtb_warning_fails_validation
test_documented_base_dtb_diagnostics_are_filtered
test_validate_uses_kernel_build_for_clean_and_scoped_merged_tree_checks
test_nested_status_cannot_satisfy_direct_parent_check
test_validator_atomically_replaces_read_only_dtbo
test_validate_uses_the_kernel_recorded_compiler
test_versioned_compiler_is_shimmed_to_the_kernel_recorded_name
test_unmatched_kernel_compiler_is_rejected_before_module_build
printf 'PASS: validation diagnostics policy\n'
