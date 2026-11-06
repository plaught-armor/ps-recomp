// Checks web/native.js, which puts a wasm32 native blob's module into
// play.wasm's function table: each load's functions run from the base it
// returns, a release leaves its slots empty (a stale index traps), and a
// load takes the smallest free range that fits before the table grows, so
// loading and releasing the same code again and again leaves the table its
// size. A development tool only: Node 24 or newer, no npm packages.
//
//   node tests/wasm_native/run.mjs
//
// The modules are made here in the layout recomp/native/wasm.odin writes:
// imports env.memory, env.table, env.base and env.s0, functions (pc i32)
// -> (), and one active element segment at global.get base. Function k
// stores k + 1 + s0 at address pc.
import { exit } from "node:process";
import { Native } from "../../web/native.js";

const uleb = (v) => {
	const out = [];
	do {
		let c = v & 0x7f;
		v >>>= 7;
		if (v !== 0) c |= 0x80;
		out.push(c);
	} while (v !== 0);
	return out;
};
const sleb = (v) => {
	const out = [];
	for (;;) {
		const c = v & 0x7f;
		v >>= 7;
		if ((v === 0 && (c & 0x40) === 0) || (v === -1 && (c & 0x40) !== 0)) {
			out.push(c);
			return out;
		}
		out.push(c | 0x80);
	}
};
const vec = (items) => [...uleb(items.length), ...items.flat()];
const section = (id, body) => [id, ...uleb(body.length), ...body];
const name = (s) => vec([...Buffer.from(s)].map((c) => [c]));

// A blob's module with n functions.
function blob(n) {
	const imports = [
		[...name("env"), ...name("memory"), 0x02, 0x00, 0x01],
		[...name("env"), ...name("table"), 0x01, 0x70, 0x00, 0x00],
		[...name("env"), ...name("base"), 0x03, 0x7f, 0x00],
		[...name("env"), ...name("s0"), 0x03, 0x7f, 0x00],
	];
	const funcs = [...Array(n).keys()];
	const body = (k) => {
		const code = [0x00, 0x20, 0x00, 0x41, ...sleb(k + 1), 0x23, 0x01, 0x6a, 0x36, 0x02, 0x00, 0x0b];
		return [...uleb(code.length), ...code];
	};
	return new Uint8Array([
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
		...section(1, vec([[0x60, 0x01, 0x7f, 0x00]])),
		...section(2, vec(imports)),
		...section(3, vec(funcs.map(() => [0x00]))),
		...section(9, vec([[0x00, 0x23, 0x00, 0x0b, ...vec(funcs.map((k) => uleb(k)))]])),
		...section(10, vec(funcs.map(body))),
	]);
}

const memory = new WebAssembly.Memory({ initial: 4 });
const table = new WebAssembly.Table({ element: "anyfunc", initial: 1 });
const logs = [];
const native = new Native({ log: (text) => logs.push(text) });
native.attach({ exports: { memory, __indirect_function_table: table } });
const view = new DataView(memory.buffer);
const CODE = 4096, SLOTS = 64, N_FUNCS = 128, OUT = 256;
const S0 = 1000;

let fails = 0;
const fail = (what) => {
	console.error("FAIL native:", what);
	fails++;
};

// Load a module with n functions: its base, after checking each function
// runs and nFuncs says n.
function load(n, what) {
	const b = blob(n);
	new Uint8Array(memory.buffer).set(b, CODE);
	view.setUint32(SLOTS, S0, true);
	view.setUint32(N_FUNCS, 0, true);
	const base = native.imports.instantiate(CODE, b.length, SLOTS, 1, N_FUNCS);
	if (base === 0) {
		fail(`${what}: instantiate failed: ${logs.join("")}`);
		return 0;
	}
	if (view.getUint32(N_FUNCS, true) !== n) fail(`${what}: nFuncs ${view.getUint32(N_FUNCS, true)}, want ${n}`);
	for (let k = 0; k < n; k++) {
		table.get(base + k)(OUT);
		if (view.getUint32(OUT, true) !== k + 1 + S0) fail(`${what}: function ${k} at ${base + k} stored ${view.getUint32(OUT, true)}`);
	}
	return base;
}

// A released range holds no function.
function released(base, n, what) {
	for (let k = 0; k < n; k++) {
		if (table.get(base + k) !== null) fail(`${what}: slot ${base + k} still holds a function`);
	}
}

// The same blob loaded and released 200 times: one range, reused.
const first = load(3, "cycle 0");
native.imports.release(first);
released(first, 3, "cycle 0");
const size = table.length;
for (let i = 1; i < 200; i++) {
	const base = load(3, `cycle ${i}`);
	if (base !== first) fail(`cycle ${i}: base ${base}, want ${first}`);
	native.imports.release(base);
}
if (table.length !== size) fail(`200 cycles: table length ${table.length}, want ${size}`);

// The free 3-slot range split by two loads that fit in it; the third does
// not fit and grows the table.
const a = load(1, "split a");
const b = load(2, "split b");
if (a !== first || b !== first + 1) fail(`split: bases ${a} ${b}, want ${first} ${first + 1}`);
if (table.length !== size) fail(`split: table length ${table.length}, want ${size}`);
const c = load(1, "grow");
if (c !== size || table.length !== size + 1) fail(`grow: base ${c}, length ${table.length}, want ${size}, ${size + 1}`);
native.imports.release(b);
released(b, 2, "split b");
if (table.get(a) === null) fail("split: releasing b emptied a");
// The smallest range that fits: free b's two slots, then c's one; a
// one-function load takes c's, not the first free.
native.imports.release(c);
const e = load(1, "smallest");
if (e !== c) fail(`smallest: base ${e}, want ${c}`);
const d = load(2, "fits");
if (d !== b) fail(`fits: base ${d}, want ${b}`);
if (table.length !== size + 1) fail(`fits: table length ${table.length}, want ${size + 1}`);

// A stale index traps.
native.imports.release(d);
try {
	table.get(d);
	if (table.get(d) !== null) throw new Error("not null");
} catch (e) {
	fail(`stale: ${e.message}`);
}
let trapped = false;
try {
	table.get(d)(OUT);
} catch {
	trapped = true;
}
if (!trapped) fail("stale: calling a released slot did not trap");

// A module whose import slots are not the runtime's (it imports env.s0,
// the runtime gives none) is refused, said once, and its range freed: the
// next load of as many functions takes it back.
{
	const b = blob(2);
	new Uint8Array(memory.buffer).set(b, CODE);
	const length = table.length;
	if (native.imports.instantiate(CODE, b.length, SLOTS, 0, N_FUNCS) !== 0) fail("a module with a slot the runtime lacks loaded");
	if (logs.length !== 1 || !logs[0].includes("s0")) fail(`slot mismatch: messages ${JSON.stringify(logs)}`);
	if (native.used.size !== 2) fail(`slot mismatch: ${native.used.size} ranges in use, want 2`);
	const again = load(2, "after a slot mismatch");
	if (table.length !== length + 2 && table.length !== length) fail(`slot mismatch: table length ${table.length} from ${length}`);
	native.imports.release(again);
	if (load(2, "reload") !== again) fail("slot mismatch: the freed range was not taken back");
}

// A release no instantiate returned throws; a bad module returns 0, said
// once in all (the slot mismatch said it).
let threw = false;
try {
	native.imports.release(9999);
} catch {
	threw = true;
}
if (!threw) fail("release of an unknown base did not throw");
new Uint8Array(memory.buffer).set([0, 1, 2, 3], CODE);
if (native.imports.instantiate(CODE, 4, SLOTS, 1, N_FUNCS) !== 0) fail("a bad module loaded");
native.imports.instantiate(CODE, 4, SLOTS, 1, N_FUNCS);
if (logs.length !== 1) fail(`a bad module twice: ${logs.length} messages, want 1`);

if (fails > 0) exit(1);
console.log("ok native: 200 cycles, table length", size);
