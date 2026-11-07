// The LEARN buffer's handoff (web/learn.js), through its public faces:
// LearnImports' start and poll on one side, learnDeliver on the other. A
// late delivery, for a compile before the one in flight, must be dropped,
// in the same run and in the next; an empty, failed or oversized blob must
// fail and put the buffer back to EMPTY; a taken blob is taken once.
// node tests/wasi/learn.mjs; exit 1 on a failure.
import { exit } from "node:process";
import { LEARN } from "../../web/layout.js";
import { LearnImports, learnDeliver } from "../../web/learn.js";

const RUNNING = -1;
const FAILED = -2;
const OVERSIZED = -3;
const EMPTY = 0;
const BUF = 1024; // where poll copies a blob in the fake memory

let failed = 0;
function check(ok, what) {
	if (!ok) {
		failed++;
		console.error(`learn: FAIL ${what}`);
	}
}

// A run: its imports, on a fake module memory, and the buffer and
// generation of each compile it started.
function run() {
	const memory = new WebAssembly.Memory({ initial: 2 });
	const r = { buffer: null, gens: [], memory };
	r.learn = new LearnImports((_records, _interp, buffer, gen) => {
		r.buffer = buffer;
		r.gens.push(gen);
		return true;
	});
	r.learn.attach({ exports: { memory } });
	r.start = () => r.learn.imports.start(0, 8, 8, 0);
	r.poll = (cap) => r.learn.imports.poll(BUF, cap, 0, r.gens.at(-1));
	r.state = () => Atomics.load(new Int32Array(r.buffer), LEARN.STATE_WORD);
	return r;
}

const blob = (n, at) => Uint8Array.from({ length: n }, (_, i) => (at + i) & 0xff);
const logs = [];
const log = (text) => logs.push(text);

const a = run();
check(a.learn.imports.poll(BUF, 0, 0, 1) === FAILED, "a poll before any start fails");
check(a.buffer === null, "no buffer before the first start");
const g1 = a.start();
const g2 = a.start();
check(g1 > 0 && g2 > g1 && a.gens.length === 2, `start gives rising generations (${g1}, ${g2})`);

// Compile g1's blob, late: g2 is in flight.
learnDeliver(a.buffer, blob(40, 1), log, g1);
check(a.state() === EMPTY, "a late delivery writes nothing");
check(a.poll(0) === RUNNING, "a late delivery is not polled");

// g2's own.
learnDeliver(a.buffer, blob(40, 2), log, g2);
check(a.poll(0) === 40, "a blob gives its size");
check(a.poll(40) === 40, "a blob the cap holds is taken");
const got = new Uint8Array(a.memory.buffer, BUF, 40);
check(got.every((b, i) => b === ((2 + i) & 0xff)), "the taken blob's bytes");
check(a.poll(40) === FAILED, "a taken blob is taken once");

// A READY blob of another generation (one written before the last start
// bumped it) is dropped by poll.
a.start();
const words = new Int32Array(a.buffer);
Atomics.store(words, LEARN.LEN_WORD, 8);
Atomics.store(words, LEARN.BLOB_GEN_WORD, g2);
Atomics.store(words, 0, 2); // READY
check(a.poll(0) === RUNNING && a.state() === EMPTY, "a blob of another generation is dropped");

// Failures put the buffer back to EMPTY.
a.start();
learnDeliver(a.buffer, new Uint8Array(0), log, a.gens.at(-1));
check(a.poll(0) === FAILED && a.state() === EMPTY, "an empty blob fails, back to EMPTY");
check(logs.length === 1, "an empty blob is said");
a.start();
learnDeliver(a.buffer, null, log, a.gens.at(-1));
check(a.poll(0) === FAILED && a.state() === EMPTY, "a failed compile fails, back to EMPTY");
for (let i = 0; i < 2; i++) {
	a.start();
	learnDeliver(a.buffer, new Uint8Array(LEARN.DATA_MAX + 1), log, a.gens.at(-1));
	check(a.poll(0) === OVERSIZED && a.state() === EMPTY, `an oversized blob is dropped, back to EMPTY (${i})`);
}
check(logs.length === 2, "an oversized blob is said once");

// The next run has a buffer of its own: run a's late delivery never
// reaches it, also with the same generation.
const b = run();
b.start();
check(b.buffer !== a.buffer, "each run has its own buffer");
learnDeliver(a.buffer, blob(40, 3), log, a.gens.at(-1));
check(b.poll(0) === RUNNING, "the run before's late delivery is not the next run's");
learnDeliver(b.buffer, blob(16, 4), log, b.gens.at(-1));
check(b.poll(16) === 16, "the next run's own blob is taken");

if (failed) {
	console.error(`learn: ${failed} failed`);
	exit(1);
}
console.log("learn: ok");
