#!/bin/sh
# Builds the converter page (index.html) and the play page (play.html) into
# <out dir>: recomp.wasm and play.wasm (wasi_wasm32), the page files and
# commit.txt (the ps-recomp commit, shown on the pages). Serve the out dir
# from any static host; .wasm must be served as application/wasm. The play
# page needs cross-origin isolation: a host that cannot send the headers
# gets them through sw.js. With binaryen's wasm-opt on PATH, each .wasm is
# also run through wasm-opt -O3 (about 14% smaller, same output); without
# it the step is skipped.
# -source-code-locations:filename keeps only the file name in panic and
# assert locations (`emit.odin(4:2) runtime assertion: ...`), so the build
# does not depend on the checkout path: two checkouts give the same bytes.
# play exports its function table, growable, for web/native.js to put a
# wasm32 native blob's functions in.
# play is built with -target-features:simd128, so its #simd code (the
# software GS's sampling, blending and attribute math) runs as wasm SIMD
# instead of being split into scalar lanes: sp and gh with a native blob
# run 15% and 27% faster per frame, the frame hashes are unchanged, and
# play.wasm is 2% smaller. It needs Chrome 91+, Firefox 89+ or Safari
# 16.4+. recomp is left scalar: its speed with simd128 is unmeasured.
# Both are built with -define:COMMIT=<commit hash>, the commit play keys
# its stored blobs with (core.blob_cached), as a native build is
# (README.md); a tree with changes gets "dev", whose blobs are never taken
# as cached, and commit.txt says -dirty.
set -eu
out=${1:?usage: web/build.sh <out dir>}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
commit=$(git -C "$root" rev-parse HEAD)
define=$commit
if ! git -C "$root" diff --quiet HEAD; then
	commit="$commit-dirty"
	define=dev
fi
for p in recomp play; do
	# play exports its function table for native blobs (web/native.js)
	# and is built with SIMD; odin refuses an empty -extra-linker-flags,
	# so recomp passes none.
	set --
	[ "$p" = play ] && set -- -extra-linker-flags:"--export-table --growable-table" -target-features:simd128
	odin build "$root/$p" -target:wasi_wasm32 -collection:ps="$root" -o:speed \
		-source-code-locations:filename -define:COMMIT="$define" "$@" -out:"$out/$p.wasm"
	if command -v wasm-opt >/dev/null; then
		wasm-opt -O3 --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext \
			--enable-mutable-globals --enable-simd "$out/$p.wasm" -o "$out/$p.wasm"
	else
		echo "build.sh: no wasm-opt, $p.wasm left unoptimized" >&2
	fi
done
for f in index.html page.css page.js worker.js readers.js wasi.js \
	play.html play.js play-worker.js native.js sdl.js net.js keys.js layout.js present.js audio.js sw.js; do
	cp "$root/web/$f" "$out/$f"
done
printf '%s\n' "$commit" > "$out/commit.txt"
