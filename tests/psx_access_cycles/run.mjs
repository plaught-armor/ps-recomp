// Runs tests/psx_access_cycles built for wasi_wasm32 (a FLAT build, which
// checks the interpreted log only: there is no PS1 wasm32 blob yet) under
// Node, on the play page's WASI shim, SDL and native imports (web/wasi.js,
// web/sdl.js, web/native.js).
// Exits with the test's exit code. A development tool only: Node 24 or
// newer, no npm packages.
//
//   odin build tests/psx_access_cycles -collection:ps=. -target:wasi_wasm32 \
//       -extra-linker-flags:"--export-table --growable-table" -out:psx_access_cycles.wasm
//   node tests/psx_access_cycles/run.mjs psx_access_cycles.wasm
import { readFileSync } from "node:fs";
import { argv, exit, stderr, stdout } from "node:process";
import { AUDIO, CONTROL, PRESENT } from "../../web/layout.js";
import { Native } from "../../web/native.js";
import { Sdl } from "../../web/sdl.js";
import { Wasi } from "../../web/wasi.js";

if (argv.length !== 3) {
	console.error("usage: node tests/psx_access_cycles/run.mjs <psx_access_cycles.wasm>");
	exit(2);
}
const log = (fd, text) => (fd === 1 ? stdout : stderr).write(text);
const wasi = new Wasi({ args: ["psx_access_cycles"], env: {}, disc: new Map(), log });
const sdl = new Sdl({
	control: new SharedArrayBuffer(CONTROL.SIZE),
	audio: new SharedArrayBuffer(AUDIO.SIZE),
	present: new SharedArrayBuffer(PRESENT.SIZE),
	post: (m) => m.log !== undefined && stderr.write(m.log),
});
const native = new Native({ log: (text) => stderr.write(text) });
const module = await WebAssembly.compile(readFileSync(argv[2]));
const instance = await WebAssembly.instantiate(module, {
	...wasi.imports,
	"system:SDL2": sdl.imports,
	"system:ps_native": native.imports,
});
sdl.attach(instance);
native.attach(instance);
exit(wasi.run(instance));
