// Runs tests/ee_jump_miss built for wasi_wasm32 (a FLAT build, whose
// disc blob of functions is a wasm32 one) under Node, on the play page's WASI
// shim, SDL and native imports (web/wasi.js,
// web/sdl.js, web/native.js). Exits with the test's exit code. A
// development tool only: Node 24 or newer, no npm packages.
//
//   odin build tests/ee_jump_miss -collection:ps=. -target:wasi_wasm32 \
//       -target-features:atomics,bulk-memory -extra-linker-flags:"--export-table \
//       --growable-table --shared-memory --import-memory --export-memory \
//       --max-memory=4294967296" -define:PS_FLAT=true -out:ee_jump_miss.wasm
//   node tests/ee_jump_miss/run.mjs ee_jump_miss.wasm
import { readFileSync } from "node:fs";
import { argv, exit, stderr, stdout } from "node:process";
import { AUDIO, CONTROL, PRESENT } from "../../web/layout.js";
import { NO_BAND } from "../../web/band.js";
import { Native } from "../../web/native.js";
import { Sdl } from "../../web/sdl.js";
import { memoryImport, Wasi } from "../../web/wasi.js";

if (argv.length !== 3) {
	console.error("usage: node tests/ee_jump_miss/run.mjs <ee_jump_miss.wasm>");
	exit(2);
}
const log = (fd, text) => (fd === 1 ? stdout : stderr).write(text);
const wasi = new Wasi({ args: ["ee_jump_miss"], env: {}, disc: new Map(), log });
const sdl = new Sdl({
	control: new SharedArrayBuffer(CONTROL.SIZE),
	audio: new SharedArrayBuffer(AUDIO.SIZE),
	present: new SharedArrayBuffer(PRESENT.SIZE),
	post: (m) => m.log !== undefined && stderr.write(m.log),
});
const native = new Native({ log: (text) => stderr.write(text) });
const bytes = readFileSync(argv[2]);
const module = await WebAssembly.compile(bytes);
// Its memory imported and shared, as play.wasm's (web/build.sh): a native
// blob imports a shared one (recomp/native/wasm.odin).
const limits = memoryImport(bytes);
const instance = await WebAssembly.instantiate(module, {
	...wasi.imports,
	...(limits && { env: { memory: new WebAssembly.Memory(limits) } }),
	"system:SDL2": sdl.imports,
	"system:ps_native": native.imports,
	"system:ps_band": NO_BAND,
});
sdl.attach(instance);
native.attach(instance);
exit(wasi.run(instance));
