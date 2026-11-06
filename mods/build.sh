#!/bin/sh
# Build a PS1 mod's C into <mod dir>/mod.elf, against a game's mod API (the
# directory `recomp --mod-api` wrote: mod_api.h and mod.ld).
#
#   mods/build.sh <api dir> <mod dir> [--origin <hex>]
#
# Every *.c in the mod dir is compiled, with mods/rt.c (memcpy, memset,
# memmove, memcmp, which clang may call for struct copies: they must be the
# mod's own, not the game's). Needs clang, ld.lld and llvm-nm.
#
# The mod is linked at the mod region's base, or at --origin (hex, 16-byte
# aligned, in the region; mod.ld checks it): two mods loaded together must
# not overlap, so give the second its own origin.
#
# A mod must not define a name mod_api.h gives a game function or the
# runtime (mod_call_original): mod.ld's assignment would win over the mod's own definition without a word from
# ld.lld, so build.sh fails instead. Every loaded section must be one mod.ld
# places (--orphan-handling=error), so its end check covers the whole image.
#
# No -mlong-calls: mod_api.h makes each game function long_call itself, as
# a jal from the mod region cannot reach the game's code and ld.lld links a
# wrong target without an error. The mod's own calls stay plain jal.
set -eu

usage() {
	echo "usage: mods/build.sh <api dir> <mod dir> [--origin <hex>]" >&2
	exit 2
}
[ $# -eq 2 ] || [ $# -eq 4 ] || usage
api=$1
dir=$2
origin=
if [ $# -eq 4 ]; then
	[ "$3" = --origin ] || usage
	origin=$4
	expr "$origin" : '0[xX][0-9a-fA-F]\{1,8\}$' >/dev/null || {
		echo "mods/build.sh: --origin $origin is not a hex address (0x...)" >&2
		exit 2
	}
fi
for tool in clang ld.lld llvm-nm; do
	command -v $tool >/dev/null 2>&1 || {
		echo "mods/build.sh: $tool not found; install clang and lld" >&2
		exit 1
	}
done
[ -f "$api/mod_api.h" ] && [ -f "$api/mod.ld" ] || {
	echo "mods/build.sh: $api has no mod_api.h and mod.ld (recomp --mod-api writes them)" >&2
	exit 1
}
here=$(cd "$(dirname "$0")" && pwd)
obj=$(mktemp -d)
trap 'rm -rf "$obj"' EXIT

n=0
for c in "$dir"/*.c "$here/rt.c"; do
	[ -f "$c" ] || continue
	n=$((n + 1))
	clang --target=mipsel-elf -march=mips1 -mabi=32 -mno-abicalls -fno-pic -G0 \
		-O2 -std=c17 -ffreestanding -fno-builtin -nostdlib \
		-I"$api" -c "$c" -o "$obj/$n.o"
done
[ $n -gt 1 ] || {
	echo "mods/build.sh: no .c files in $dir" >&2
	exit 1
}
# The mod's own global names, against every name mod.ld gives an address.
LC_ALL=C
export LC_ALL
sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\) = 0x[0-9a-fA-F]*;$/\1/p' "$api/mod.ld" | sort -u >"$obj/game"
llvm-nm --defined-only -g -j "$obj"/*.o | grep -v -e '^$' -e ':$' | sort -u >"$obj/own"
clash=$(comm -12 "$obj/game" "$obj/own")
[ -z "$clash" ] || {
	for s in $clash; do
		echo "mods/build.sh: the mod defines $s, a name mod_api.h gives a game function or the runtime: rename it" >&2
	done
	exit 1
}
set -- -T "$api/mod.ld" --orphan-handling=error -o "$dir/mod.elf"
[ -z "$origin" ] || set -- "$@" --defsym=MOD_ORIGIN="$origin"
ld.lld "$@" "$obj"/*.o
