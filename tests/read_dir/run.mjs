// Runs tests/read_dir built for wasi_wasm32 under Node, on the play page's
// WASI shim (web/wasi.js), in its in-memory preopen. Exits with the test's
// exit code. A development tool only: Node 24 or newer, no npm packages.
//
//   odin build tests/read_dir -collection:ps=. -target:wasi_wasm32 -out:read_dir.wasm
//   node tests/read_dir/run.mjs read_dir.wasm
import { readFileSync } from "node:fs";
import { argv, exit, stderr, stdout } from "node:process";
import { Wasi } from "../../web/wasi.js";

if (argv.length !== 3) {
	console.error("usage: node tests/read_dir/run.mjs <read_dir.wasm>");
	exit(2);
}
const wasi = new Wasi({
	args: ["read_dir"],
	disc: new Map(),
	log: (fd, text) => (fd === 1 ? stdout : stderr).write(text),
});
const instance = await WebAssembly.instantiate(await WebAssembly.compile(readFileSync(argv[2])), wasi.imports);
const code = wasi.run(instance);
// exit() drops writes still queued on a pipe; wait for them first.
await new Promise((resolve) => stdout.write("", resolve));
exit(code);
