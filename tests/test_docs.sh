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

require_file()
{
	[ -f "$repo_root/$1" ] || fail "missing documentation file: $1"
}

require_text()
{
	file=$1
	text=$2
	grep -Fq "$text" "$repo_root/$file" || fail "$file is missing required text: $text"
}

check_local_links()
{
	file=$1
	directory=$(dirname -- "$file")
	links_file=$workdir/links
	{
		grep -oE '!?\[[^]]*\]\([^)]*\)' "$file" 2>/dev/null | sed 's/^.*](//; s/)$//' || true
		sed -n 's/^[[:space:]]*\[[^]]*\]:[[:space:]]*<?\([^[:space:] >]*\)>?.*/\1/p' "$file"
	} > "$links_file"
	while IFS= read -r link; do
		case $link in
		''|'#'*|http://*|https://*|mailto:*) continue ;;
		esac
		target=${link%%#*}
		[ -e "$directory/$target" ] || fail "$file has an unresolved local link: $link"
	done < "$links_file"
}

require_file README.md
require_file docs/wiring.md
require_file docs/recovery.md
grep -Fq 'sh tests/test_docs.sh' "$repo_root/Makefile" || \
	fail 'Makefile test target does not run documentation acceptance'

for document in README.md docs/wiring.md docs/recovery.md; do
	check_local_links "$repo_root/$document"
done

mkdir "$workdir/link-fixture"
: > "$workdir/link-fixture/first.md"
: > "$workdir/link-fixture/second.md"
: > "$workdir/link-fixture/image.png"
cat > "$workdir/link-fixture/sample.md" <<'EOF'
[first](first.md) and [second](second.md) ![diagram](image.png)
[local-reference]: first.md
[external-reference]: https://example.test/reference
Use [the reference][local-reference].
EOF
check_local_links "$workdir/link-fixture/sample.md"

require_text docs/wiring.md 'Power off the Rock Pi before inserting or removing the FFC.'
require_text docs/wiring.md 'GPIO pin 2 or 4 provides 5 V; GPIO pin 6 is ground.'
require_text docs/wiring.md "Follow Radxa's published FFC orientation for the Rock Pi 4B+ MIPI DSI connector."
require_text docs/recovery.md 'sudo sh scripts/uninstall.sh --offline-boot-root TARGET_ROOT'
require_text docs/recovery.md 'remove the `rockpi-4b-plus-rpi-touchscreen` token from `user_overlays`'
require_text docs/recovery.md 'mounted system root'
require_text docs/recovery.md '/mnt/rockpi/boot/armbianEnv.txt'
require_text README.md 'Touch Display 2 is not supported.'
require_text README.md 'Hardware validation remains pending until the physical display is connected and checked.'

printf 'PASS: documentation acceptance\n'
