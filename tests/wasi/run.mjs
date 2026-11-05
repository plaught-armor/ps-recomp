// Dev harness: runs recomp built for wasi_wasm32 under Node's WASI
// (preview1), to check that it converts a disc as the host build does. A
// development tool only: needs Node 24 or newer, no npm packages.
//
//   odin build recomp -target:wasi_wasm32 -collection:ps=. -o:speed -out:recomp.wasm
//   node tests/wasi/run.mjs recomp.wasm <out dir> [--arch <arch>] <disc image>
//
// The disc image's directory is preopened as /disc (a .cue's track files
// sit beside it) and the out dir as the working directory, so the blob
// <serial>.<arch>.bin lands there. Exits with recomp's exit code.
import { readFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { argv, exit } from "node:process";
import { WASI } from "node:wasi";

const args = argv.slice(2);
if (args.length !== 3 && !(args.length === 5 && args[2] === "--arch")) {
	console.error("usage: node run.mjs <recomp.wasm> <out dir> [--arch <arch>] <disc image>");
	exit(2);
}
const [wasm, out] = args;
const image = resolve(args[args.length - 1]);
const wasi = new WASI({
	version: "preview1",
	args: ["recomp", ...args.slice(2, -1), "/disc/" + basename(image)],
	preopens: { "/disc": dirname(image), ".": resolve(out) },
	returnOnExit: true,
});
const module = await WebAssembly.compile(await readFile(wasm));
// Odin's core:os opens a file for reading with the fd_read right but not
// fd_seek, which WASI's fd_pread also needs (Node enforces it): add fd_seek
// (bit 2) to every path_open, as a shim that ignores rights would.
const imports = wasi.getImportObject();
const p1 = imports.wasi_snapshot_preview1;
const path_open = p1.path_open;
p1.path_open = (fd, dirflags, path, len, oflags, base, inheriting, fdflags, out) =>
	path_open(fd, dirflags, path, len, oflags, base | 4n, inheriting | 4n, fdflags, out);
const instance = await WebAssembly.instantiate(module, imports);
exit(wasi.start(instance));
