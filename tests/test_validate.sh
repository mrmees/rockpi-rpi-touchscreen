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
case " $* " in
*' modules '*) [ -z "${MAKE_DIAGNOSTIC:-}" ] || printf '%s\n' "$MAKE_DIAGNOSTIC" >&2 ;;
esac
EOF
	chmod +x "$sandbox/bin/make"
	cat > "$sandbox/bin/modinfo" <<'EOF'
#!/bin/sh
case "$2" in
license) printf '%s\n' 'GPL v2' ;;
alias) printf '%s\n' 'of:N*T*Craspits_ft5426' ;;
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
	if [ "${MERGED_VARIANT:-valid}" = 'dsi0-disabled' ]; then
		dsi0_status=disabled
	else
		dsi0_status=okay
	fi
	cat > "$output" <<EOF_DTS
dsi@ff960000 {
	status = "$dsi0_status";
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
		compatible = "raspberrypi,7inch-touchscreen-panel";
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
	MAKE_LOG="$sandbox/make.log" PATH="$sandbox/bin:$PATH" \
	sh "$repo_root/scripts/validate.sh" --offline "$@"
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
	if MERGED_VARIANT=dsi0-disabled run_validate "$sandbox"; then
		fail 'disabled DSI0 was accepted by merged-tree validation'
	fi
	grep -Fqx -- "-C $repo_root KDIR=$sandbox/modules/test-kernel/build clean" "$sandbox/make.log" ||
		fail 'make clean did not receive the selected kernel build path'
	printf 'PASS: scoped merged-tree checks and KDIR clean\n'
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
	grep -Fqx -- "-C $repo_root KDIR=$sandbox/modules/test-kernel/build CC=$sandbox/bin/test-kernel-gcc W=1 modules" \
		"$sandbox/make.log" || fail 'module build did not use the kernel-recorded compiler'
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
	grep -Eq -- "-C $repo_root KDIR=$sandbox/modules/test-kernel/build CC=.*/module-compiler/aarch64-linux-gnu-gcc W=1 modules" \
		"$sandbox/make.log" || fail 'versioned compiler was not shimmed to the kernel-recorded name'
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
test_overlay_warning_fails_validation
test_unexpected_base_dtb_warning_fails_validation
test_documented_base_dtb_diagnostics_are_filtered
test_validate_uses_kernel_build_for_clean_and_scoped_merged_tree_checks
test_validate_uses_the_kernel_recorded_compiler
test_versioned_compiler_is_shimmed_to_the_kernel_recorded_name
test_unmatched_kernel_compiler_is_rejected_before_module_build
printf 'PASS: validation diagnostics policy\n'
