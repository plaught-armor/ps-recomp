// Runs the modules tests/wasm_asm wrote and compares the state each ends
// with to what cases.txt says. A development tool only: Node 24 or newer,
// no npm packages.
//
//   odin run tests/wasm_asm -collection:ps=. -- <dir> [cases]
//   node tests/wasm_asm/run.mjs <dir>
//
// Each module gets a fresh memory and table: the state at STATE, the host
// procedure "t.host" at table slot 1 (through a small module, as a table
// holds only wasm functions), the generated functions from slot BASE. The
// first is called with pc 0 and context CTX, which the host checks it is
// passed.
import { readFileSync } from "node:fs";
import { argv, exit } from "node:process";

if (argv.length < 3) {
	console.error("usage: node run.mjs <dir>");
	exit(2);
}
const dir = argv[2];
const STATE = 1024;
const BASE = 8;
const CTX = 0x5eed;
const CELLS = 8;

// A module importing env.f of type (i32, i32, i32) -> i32 and exporting it.
const section = (id, body) => [id, body.length, ...body];
const name = (s) => [s.length, ...Buffer.from(s)];
const wrapper = new Uint8Array([
	0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
	...section(1, [1, 0x60, 3, 0x7f, 0x7f, 0x7f, 1, 0x7f]),
	...section(2, [1, ...name("env"), ...name("f"), 0x00, 0x00]),
	...section(7, [1, ...name("f"), 0x00, 0x00]),
]);
const wrapperModule = new WebAssembly.Module(wrapper);

let badCtx = 0;
const host = (x, y, ctx) => {
	if (ctx !== CTX) badCtx++;
	return (Math.imul(x, 31) + y) | 0;
};

let failed = 0;
let ran = 0;
for (const line of readFileSync(`${dir}/cases.txt`, "utf8").trimEnd().split("\n")) {
	const f = line.split(" ");
	const [file, imps] = f;
	const start = f.slice(2, 3 + CELLS).map(Number);
	const want = f.slice(3 + CELLS).map(Number);
	const bytes = readFileSync(`${dir}/${file}`);
	if (!WebAssembly.validate(bytes)) {
		try {
			new WebAssembly.Module(bytes);
		} catch (e) {
			console.log(`${file}: invalid: ${e.message}`);
		}
		failed++;
		continue;
	}
	const memory = new WebAssembly.Memory({ initial: 1 });
	const table = new WebAssembly.Table({ initial: 64, element: "anyfunc" });
	table.set(1, new WebAssembly.Instance(wrapperModule, { env: { f: host } }).exports.f);
	const env = { memory, table, base: new WebAssembly.Global({ value: "i32" }, BASE) };
	imps.split(",").forEach((n, k) => {
		const v = { "t.state": STATE, "t.host": 1 }[n];
		if (v === undefined) throw new Error(`${file}: unknown import ${n}`);
		env[`s${k}`] = new WebAssembly.Global({ value: "i32" }, v);
	});
	new WebAssembly.Instance(new WebAssembly.Module(bytes), { env });
	const s = new Uint32Array(memory.buffer, STATE, CELLS + 1);
	s.set(start);
	table.get(BASE)(0, CTX);
	const got = Array.from(s);
	ran++;
	if (got.some((v, i) => v !== want[i])) {
		failed++;
		if (failed <= 20) console.log(`${file}: got ${got.join(" ")}, want ${want.join(" ")}`);
	}
}
if (badCtx) {
	console.log(`the host was passed another context ${badCtx} times`);
	failed++;
}
console.log(failed === 0 ? `ok: ${ran} modules agree` : `${failed} failed of ${ran + failed}`);
exit(failed === 0 ? 0 : 1);
