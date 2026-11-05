#!/bin/sh
# Builds the converter page into <out dir>: recomp.wasm (wasi_wasm32), the
# page files and commit.txt (the ps-recomp commit, shown on the page). Serve
# the out dir from any static host; .wasm must be served as application/wasm.
# With binaryen's wasm-opt on PATH, recomp.wasm is also run through
# wasm-opt -O3 (about 14% smaller, same output); without it the step is skipped.
# -source-code-locations:filename keeps only the file name in panic and
# assert locations (`emit.odin(4:2) runtime assertion: ...`), so the build
# does not depend on the checkout path: two checkouts give the same bytes.
set -eu
out=${1:?usage: web/build.sh <out dir>}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
odin build "$root/recomp" -target:wasi_wasm32 -collection:ps="$root" -o:speed \
	-source-code-locations:filename -out:"$out/recomp.wasm"
if command -v wasm-opt >/dev/null; then
	wasm-opt -O3 --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext \
		--enable-mutable-globals "$out/recomp.wasm" -o "$out/recomp.wasm"
else
	echo "build.sh: no wasm-opt, recomp.wasm left unoptimized" >&2
fi
for f in index.html page.css page.js worker.js wasi.js; do
	cp "$root/web/$f" "$out/$f"
done
commit=$(git -C "$root" rev-parse HEAD)
git -C "$root" diff --quiet HEAD || commit="$commit-dirty"
printf '%s\n' "$commit" > "$out/commit.txt"
