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
set -eu
out=${1:?usage: web/build.sh <out dir>}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
for p in recomp play; do
	odin build "$root/$p" -target:wasi_wasm32 -collection:ps="$root" -o:speed \
		-source-code-locations:filename -out:"$out/$p.wasm"
	if command -v wasm-opt >/dev/null; then
		wasm-opt -O3 --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext \
			--enable-mutable-globals --enable-simd "$out/$p.wasm" -o "$out/$p.wasm"
	else
		echo "build.sh: no wasm-opt, $p.wasm left unoptimized" >&2
	fi
done
for f in index.html page.css page.js worker.js readers.js wasi.js \
	play.html play.js play-worker.js sdl.js keys.js layout.js present.js audio.js sw.js; do
	cp "$root/web/$f" "$out/$f"
done
commit=$(git -C "$root" rev-parse HEAD)
git -C "$root" diff --quiet HEAD || commit="$commit-dirty"
printf '%s\n' "$commit" > "$out/commit.txt"
