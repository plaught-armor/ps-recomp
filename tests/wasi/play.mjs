// Dev harness: runs play built for wasi_wasm32 (a FLAT build) headless under
// Node, on the play page's WASI shim and SDL imports (web/wasi.js,
// web/sdl.js), to check that it plays a disc as the native FLAT build does.
// A development tool only: needs Node 24 or newer, no npm packages.
//
//   odin build play -target:wasi_wasm32 -out:play.wasm ...
//   node tests/wasi/play.mjs <play.wasm> <out dir> <disc image> [frames]
//
// The run is headless (PS_HEADLESS=1), on the software GS that a wasm
// build takes with no PS_SW=1 (so every run checks that default), and
// ends at vblank `frames` (default 600). It dumps a hash line every 60
// frames into <out dir>/hashes.tsv (PS_DUMP_HASH=1, core/dump.odin);
// a native run with -define:PS_FLAT=true, PS_NATIVE=0 and the same PS_*
// settings writes the same file. Other PS_* variables set here are passed
// on and win over these. Every file in the disc image's directory is
// visible as /disc/<name>. The data directory is the shim's /data, empty
// at the start, or with PLAY_DATA=<dir> holding that directory's files (a
// disc directory with a wasm32 native blob and its key, for one), as the
// play page's /data holds what earlier runs stored (web/readers.js).
// Prints the frame of the first present, the presents, the time and the
// shim's call counts to stderr, and exits with play's exit code.
import { mkdirSync, openSync, readFileSync, readSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { argv, env, exit, stderr, stdout } from "node:process";
import { AUDIO, CONTROL, PRESENT } from "../../web/layout.js";
import { Native } from "../../web/native.js";
import { Sdl } from "../../web/sdl.js";
import { Wasi } from "../../web/wasi.js";

const args = argv.slice(2);
if (args.length !== 3 && args.length !== 4) {
	console.error("usage: node play.mjs <play.wasm> <out dir> <disc image> [frames]");
	exit(2);
}
const [wasm, out] = args;
const image = resolve(args[2]);
const frames = args[3] ?? "600";
if (!/^[1-9][0-9]*$/.test(frames)) {
	console.error("play.mjs: frames is not a vblank count:", frames);
	exit(2);
}

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

const settings = {
	PS_HEADLESS: "1",
	PS_FRAMES: frames,
	// The shim's root, which is the out dir: core/dump.odin makes no
	// directory, and the shim's only writable directories are the root and
	// /data.
	PS_DUMP: ".",
	PS_DUMP_HASH: "1",
	PS_DUMP_EVERY: "60",
};
for (const [k, v] of Object.entries(env)) if (k.startsWith("PS_")) settings[k] = v;

const log = (fd, text) => (fd === 1 ? stdout : stderr).write(text);
const wasi = new Wasi({ args: ["play", "/disc/" + basename(image)], env: settings, disc, log });
// The page's buffers, which nothing reads here: present never waits for
// a free slot, and a headless run opens no audio device.
const sdl = new Sdl({
	control: new SharedArrayBuffer(CONTROL.SIZE),
	audio: new SharedArrayBuffer(AUDIO.SIZE),
	present: new SharedArrayBuffer(PRESENT.SIZE),
	post: (m) => m.log !== undefined && stderr.write(m.log),
});
if (env.PLAY_DATA) {
	const files = new Map();
	const walk = (path, prefix) => {
		for (const e of readdirSync(path, { withFileTypes: true })) {
			if (e.isDirectory()) walk(join(path, e.name), prefix + e.name + "/");
			else if (e.isFile()) files.set(prefix + e.name, readFileSync(join(path, e.name)));
		}
	};
	walk(env.PLAY_DATA, "");
	wasi.seed(files);
}
const native = new Native({ log: (text) => stderr.write(text) });
const start = performance.now();
let first = null;
const present = sdl.present.bind(sdl);
sdl.present = () => {
	present();
	first ??= { frame: sdl.frame, ms: Math.round(performance.now() - start) };
};

const module = await WebAssembly.compile(readFileSync(wasm));
const instance = await WebAssembly.instantiate(module, {
	...wasi.imports,
	"system:SDL2": sdl.imports,
	"system:ps_native": native.imports,
});
sdl.attach(instance);
native.attach(instance);
const code = wasi.run(instance);
const ms = Math.round(performance.now() - start);
for (const [path, bytes] of wasi.files()) {
	const to = join(resolve(out), path);
	mkdirSync(dirname(to), { recursive: true });
	writeFileSync(to, bytes);
}
stderr.write(`play.mjs: exit ${code}, first present ${first ? `#${first.frame} at ${first.ms} ms` : "none"}, ${sdl.frame} presents, ${ms} ms\n`);
stderr.write(`wasi: ${JSON.stringify(wasi.stats)}\n`);
exit(code);
