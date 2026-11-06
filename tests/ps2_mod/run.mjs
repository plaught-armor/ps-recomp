// Runs tests/ps2_mod built for wasi_wasm32 (a FLAT build, which runs the
// program's unhooked functions as a wasm32 blob: wasm.odin) under Node, on
// the play page's WASI shim, SDL and native imports (web/wasi.js,
// web/sdl.js, web/native.js). Exits with the test's exit code. A
// development tool only: Node 24 or newer, no npm packages.
//
//   odin build tests/ps2_mod -collection:ps=. -target:wasi_wasm32 \
//       -extra-linker-flags:"--export-table --growable-table" -out:ps2_mod.wasm
//   node tests/ps2_mod/run.mjs ps2_mod.wasm
import { readFileSync } from "node:fs";
import { argv, exit, stderr, stdout } from "node:process";
import { AUDIO, CONTROL, PRESENT } from "../../web/layout.js";
import { Native } from "../../web/native.js";
import { Sdl } from "../../web/sdl.js";
import { Wasi } from "../../web/wasi.js";

if (argv.length !== 3) {
	console.error("usage: node tests/ps2_mod/run.mjs <ps2_mod.wasm>");
	exit(2);
}
const log = (fd, text) => (fd === 1 ? stdout : stderr).write(text);
const wasi = new Wasi({ args: ["ps2_mod"], env: {}, disc: new Map(), log });
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
