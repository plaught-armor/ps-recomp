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
//
// Then the memory cases of mem.txt (mem.odin): each module gets a fresh
// memory laid out as mem.odin's M_ constants, started from mem_init's
// formula, and the host procedures t.load, t.store, t.wide and t.unal log
// their calls in it; it must end as <k>.mem has it.
import { existsSync, readFileSync } from "node:fs";
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

// A module importing env.f of type (i32 x params) -> i32 (or nothing) and
// exporting it.
const section = (id, body) => [id, body.length, ...body];
const name = (s) => [s.length, ...Buffer.from(s)];
const wrapper = (params, result) => new WebAssembly.Module(new Uint8Array([
	0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
	...section(1, [1, 0x60, params, ...Array(params).fill(0x7f), ...(result ? [1, 0x7f] : [0])]),
	...section(2, [1, ...name("env"), ...name("f"), 0x00, 0x00]),
	...section(7, [1, ...name("f"), 0x00, 0x00]),
]));
const wrapperModule = wrapper(3, true);
const wasmFunc = (module, f) => new WebAssembly.Instance(module, { env: { f } }).exports.f;

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
// The memory cases: mem.odin's layout.
const M = { lo: 1024, state: 1024, log: 1280, vu: 2048, guard: 2560, pages: 2576, win: 4096, ram: 8192, hi: 8192 + (16 << 10) };
const LOG_MAX = 60;
const PAGES = (16 << 10) >> 10;
const memCases = existsSync(`${dir}/mem.txt`) ? readFileSync(`${dir}/mem.txt`, "utf8").trimEnd().split("\n") : [];
const load1 = wrapper(2, true);
const call2 = wrapper(3, false);
for (const line of memCases) {
	const [file, imps, guard, pages] = line.split(" ");
	const bytes = readFileSync(`${dir}/${file}`);
	const want = readFileSync(`${dir}/${file.replace(".wasm", ".mem")}`);
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
	const m = new Uint8Array(memory.buffer);
	for (let i = 0; i < M.hi - M.lo; i++) m[M.lo + i] = ((i * 131 + 7) >> 1) & 0xff;
	m.fill(0, M.log, M.log + 4 + 12 * LOG_MAX);
	m[M.guard] = Number(guard);
	for (let k = 0; k < PAGES; k++) m[M.pages + k] = (Number(pages) >> k) & 1;
	const dv = new DataView(memory.buffer);
	const log = (kind, a, b, ctx) => {
		if (ctx !== CTX) badCtx++;
		const n = dv.getUint32(M.log, true);
		if (n >= LOG_MAX) throw new Error(`${file}: the log is full`);
		dv.setUint32(M.log, n + 1, true);
		dv.setUint32(M.log + 4 + 12 * n, kind, true);
		dv.setUint32(M.log + 8 + 12 * n, a >>> 0, true);
		dv.setUint32(M.log + 12 + 12 * n, b >>> 0, true);
	};
	const table = new WebAssembly.Table({ initial: 64, element: "anyfunc" });
	const slots = {
		"t.load": [1, wasmFunc(load1, (a, ctx) => (log(1, a, 0, ctx), (Math.imul(a, 0x9e3779b1) + 0x1234) | 0))],
		"t.store": [2, wasmFunc(call2, (a, b, ctx) => log(2, a, b, ctx))],
		"t.wide": [3, wasmFunc(call2, (a, b, ctx) => log(3, a, b, ctx))],
		"t.unal": [4, wasmFunc(call2, (a, b, ctx) => log(4, a, b, ctx))],
	};
	const env = { memory, table, base: new WebAssembly.Global({ value: "i32" }, BASE) };
	imps.split(",").forEach((n, k) => {
		let v = { "t.state": M.state, "t.ram": M.ram, "t.pages": M.pages, "t.guard": M.guard, "t.win": M.win, "t.vu": M.vu }[n];
		if (v === undefined && slots[n]) {
			table.set(slots[n][0], slots[n][1]);
			v = slots[n][0];
		}
		if (v === undefined) throw new Error(`${file}: unknown import ${n}`);
		env[`s${k}`] = new WebAssembly.Global({ value: "i32" }, v);
	});
	new WebAssembly.Instance(new WebAssembly.Module(bytes), { env });
	table.get(BASE)(0, CTX);
	const got = m.subarray(M.lo, M.hi);
	ran++;
	const at = got.findIndex((v, i) => v !== want[i]);
	if (at >= 0) {
		failed++;
		if (failed <= 20) console.log(`${file}: memory differs first at ${M.lo + at}: got ${got[at]}, want ${want[at]}`);
	}
}
if (badCtx) {
	console.log(`the host was passed another context ${badCtx} times`);
	failed++;
}
console.log(failed === 0 ? `ok: ${ran} modules agree` : `${failed} failed of ${ran + failed}`);
exit(failed === 0 ? 0 : 1);
