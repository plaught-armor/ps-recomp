// Dev harness: runs recomp built for wasi_wasm32 on the web page's WASI shim
// (web/wasi.js) under Node, to check that it converts a disc as the host
// build does. A development tool only: needs Node 24 or newer, no npm
// packages.
//
//   web/build.sh <page dir>     (or odin build recomp -target:wasi_wasm32 ...)
//   node tests/wasi/run.mjs <page dir>/recomp.wasm <out dir> [--arch <arch>] <disc image>
//
// Every file in the disc image's directory is visible as /disc/<name> (a
// .cue's track files sit beside it). What recomp writes, the blob
// <serial>.<arch>.bin, lands in the out dir. Prints the shim's call counts
// and block cache numbers to stderr, and exits with recomp's exit code.
import { mkdirSync, openSync, readFileSync, readSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { argv, exit, stderr, stdout } from "node:process";
import { Wasi } from "../../web/wasi.js";

const args = argv.slice(2);
if (args.length !== 3 && !(args.length === 5 && args[2] === "--arch")) {
	console.error("usage: node run.mjs <recomp.wasm> <out dir> [--arch <arch>] <disc image>");
	exit(2);
}
const [wasm, out] = args;
const image = resolve(args[args.length - 1]);

// A reader per file in the image's directory, opened on first read.
const disc = new Map();
for (const e of readdirSync(dirname(image), { withFileTypes: true })) {
	if (!e.isFile()) continue;
	const path = join(dirname(image), e.name);
	let fd;
	disc.set(e.name, {
		size: statSync(path).size,
		read(offset, length) {
			fd ??= openSync(path, "r");
			const b = new Uint8Array(length);
			for (let o = 0; o < length;) {
				const n = readSync(fd, b, o, length - o, offset + o);
				if (n === 0) return b.subarray(0, o);
				o += n;
			}
			return b;
		},
	});
}

const wasi = new Wasi({
	args: ["recomp", ...args.slice(2, -1), "/disc/" + basename(image)],
	disc,
	log: (fd, text) => (fd === 1 ? stdout : stderr).write(text),
});
const start = performance.now();
const module = await WebAssembly.compile(readFileSync(wasm));
const instance = await WebAssembly.instantiate(module, wasi.imports);
const code = wasi.run(instance);
const ms = Math.round(performance.now() - start);
for (const [path, bytes] of wasi.files()) {
	const to = join(resolve(out), path);
	mkdirSync(dirname(to), { recursive: true });
	writeFileSync(to, bytes);
}
stderr.write(`wasi: ${ms} ms, ${JSON.stringify(wasi.stats)}\n`);
exit(code);
