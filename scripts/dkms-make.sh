#!/bin/sh
set -eu

[ "$#" -ge 2 ] || {
	printf 'ERROR: usage: %s KERNEL_RELEASE COMMAND [ARG ...]\n' "$0" >&2
	exit 1
}

kernel_release=$1
shift
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
