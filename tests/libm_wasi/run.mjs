// Runs tests/libm_wasi built for the host and for wasi_wasm32 (under Node, on
// the web page's WASI shim, web/wasi.js) and compares what they print: every
// f32 input of sinf, cosf and expf, then sin, pow and exp2 on the tree's
// inputs and on random ones. A development tool only: needs Node 24 or newer, no npm
// packages.
//
//   odin build tests/libm_wasi -collection:ps=. -o:speed -out:libm_host
//   odin build tests/libm_wasi -collection:ps=. -o:speed -target:wasi_wasm32 -out:libm_wasi.wasm
//   node tests/libm_wasi/run.mjs libm_host libm_wasi.wasm [--jobs <n>] [--only <s|c|e|domain>]
//
// Counts and lists the inputs whose results differ (the first 10000), and
// exits 1 if any does.
import { spawn } from "node:child_process";
import { availableParallelism } from "node:os";
import { readFileSync } from "node:fs";
import { argv, exit, stderr, stdout } from "node:process";
import { fileURLToPath } from "node:url";

const self = fileURLToPath(import.meta.url);

// Child mode: run the wasm with the given arguments, print what it prints.
if (argv[2] === "--wasm") {
	const { Wasi } = await import("../../web/wasi.js");
	const wasi = new Wasi({
		args: ["libm_wasi", ...argv.slice(4)],
		disc: new Map(),
		log: (fd, text) => (fd === 1 ? stdout : stderr).write(text),
	});
	const instance = await WebAssembly.instantiate(await WebAssembly.compile(readFileSync(argv[3])), wasi.imports);
	const code = wasi.run(instance);
	// exit() drops writes still queued on a pipe; wait for them first.
	await new Promise((resolve) => stdout.write("", resolve));
	exit(code);
}

const args = argv.slice(2);
let jobs = availableParallelism();
let only = null;
for (let i = 2; i < args.length; i += 2) {
	if (args[i] === "--jobs") jobs = Number(args[i + 1]);
	else if (args[i] === "--only") only = args[i + 1];
	else args.length = 0;
}
if (args.length < 2 || !(jobs > 0) || !(only === null || ["s", "c", "e", "domain"].includes(only))) {
	console.error("usage: node run.mjs <host build> <wasm build> [--jobs <n>] [--only <s|c|e|domain>]");
	exit(2);
}
const [host, wasm] = args;

// Runs one build with the given arguments; resolves to its output.
const runRaw = (wasmBuild, a) =>
	new Promise((resolve, reject) => {
		const p = wasmBuild ? spawn(process.execPath, [self, "--wasm", wasm, ...a]) : spawn(host, a);
		const out = [];
		p.stdout.on("data", (d) => out.push(d));
		p.stderr.on("data", (d) => stderr.write(d));
		p.on("error", reject);
		p.on("close", (code) => {
			if (code !== 0) return reject(new Error(`${wasmBuild ? "wasm" : "host"} ${a.join(" ")}: exit ${code}`));
			resolve(Buffer.concat(out));
		});
	});

// Its output lines.
const run = async (wasmBuild, a) => {
	const text = (await runRaw(wasmBuild, a)).toString("latin1");
	return text.length ? text.trimEnd().split("\n") : [];
};

const both = (a) => Promise.all([run(false, a), run(true, a)]);

// Lines of a and b that differ, as [a line, b line].
const differ = (a, b) => {
	if (a.length !== b.length) throw new Error(`line counts differ: ${a.length} and ${b.length}`);
	return a.flatMap((l, i) => (l === b[i] ? [] : [[l, b[i]]]));
};

const NAMES = { s: "sinf", c: "cosf", e: "expf" };
const SHOWN = 10000; // differences listed; all are counted
const diffs = []; // "<function> <input>: host <bits> wasm <bits>"
let count = 0;
const differs = (d) => {
	if (count++ < SHOWN) diffs.push(d);
};

// A chunk listing is 2^24 lines of "<x> <f(x)>\n", 18 bytes each, about
// 300 MB a build: list one chunk at a time, and compare the bytes.
const RECORD = 18;
let listing = Promise.resolve();
const listChunk = (f, chunk) => {
	const job = listing.then(async () => {
		const a = ["list", f, String(chunk)];
		const [h, w] = await Promise.all([runRaw(false, a), runRaw(true, a)]);
		if (h.length !== RECORD << 24 || w.length !== h.length) throw new Error(`list ${f} ${chunk}: ${h.length} and ${w.length} bytes`);
		for (let i = 0; i < h.length; i += RECORD) {
			if (h.compare(w, i, i + RECORD, i, i + RECORD) === 0) continue;
			differs(`${NAMES[f]} ${h.toString("latin1", i, i + 8)}: host ${h.toString("latin1", i + 9, i + 17)} wasm ${w.toString("latin1", i + 9, i + 17)}`);
		}
	});
	listing = job.catch(() => {});
	return job;
};
const tasks = [];
const STEP = 4; // chunks of 2^24 inputs per task
for (const f of ["s", "c", "e"]) {
	if (only !== null && only !== f) continue;
	for (let lo = 0; lo < 256; lo += STEP) {
		tasks.push(async () => {
			const [h, w] = await both(["hash", f, String(lo), String(lo + STEP)]);
			for (const [hl] of differ(h, w)) {
				await listChunk(f, parseInt(hl.split(" ")[1], 16));
			}
			return `${NAMES[f]} chunks ${lo}..${lo + STEP - 1}`;
		});
	}
}
if (only === null || only === "domain") {
	tasks.push(async () => {
		const [h, w] = await both(["domain"]);
		for (const [a, b] of differ(h, w)) {
			if (!a.startsWith("random ")) {
				differs(`${a.split(" ").slice(0, -1).join(" ")}: host ${a.split(" ").at(-1)} wasm ${b.split(" ").at(-1)}`);
				continue;
			}
			const [hb, wb] = await both(["randomblock", String(parseInt(a.split(" ")[1], 16))]);
			for (const [c, d] of differ(hb, wb)) {
				const [x, y, hr] = c.split(" ");
				differs(`pow(${x}, ${y}): host ${hr} wasm ${d.split(" ")[2]}`);
			}
		}
		return "sin, pow and exp2";
	});
}

const start = performance.now();
let next = 0;
let done = 0;
const worker = async () => {
	while (next < tasks.length) {
		const name = await tasks[next++]();
		done++;
		stderr.write(`${done}/${tasks.length} ${name}, ${Math.round((performance.now() - start) / 1000)} s, ${count} differ\n`);
	}
};
await Promise.all(Array.from({ length: Math.min(jobs, tasks.length) }, worker));
for (const d of diffs) console.log(d);
if (count > SHOWN) console.log(`(the first ${SHOWN} listed)`);
console.log(count === 0 ? "ok: host and wasm agree" : `${count} results differ`);
exit(count === 0 ? 0 : 1);
