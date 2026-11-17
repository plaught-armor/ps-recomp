// A mid-run learned compile (play/midload_learned.odin): the play module's
// "system:ps_learn" imports, and the relay that runs the compile in a
// worker of its own (`play --learned psx`, another instance of the same
// module) and hands its blob back through the LEARN SharedArrayBuffer.
//
// The play Worker never yields, so the compile cannot be started from it:
// start hands the records and interp list to startCb (the Worker posts them
// to the page; Node's play.mjs starts a worker_thread), and poll waits on
// the buffer's state word. The deliverer moves the word EMPTY -> WRITING ->
// READY, and only from EMPTY, so it never writes while poll reads: poll
// copies only a READY blob, then marks it TAKEN; a failed, empty or
// oversized one it puts back to EMPTY. Each start names its compile with
// the next generation (GEN_WORD), and puts the word back to EMPTY once no
// deliverer writes: a deliverer whose generation is not the current one
// (a compile from before, late) writes nothing, and poll drops a blob of
// another generation.
import { LEARN } from "./layout.js";

// The state word's values.
const EMPTY = 0;
const WRITING = 1;
const READY = 2;
const TAKEN = 3;

// LEN_WORD for a compile with no blob, and for one over DATA_MAX.
const FAILED = -1;
const OVERSIZED = -2;

// poll's answers (play/midload_learned.odin).
const POLL_RUNNING = -1;
const POLL_FAILED = -2;
const POLL_OVERSIZED = -3;

// How long start waits at a time for a deliverer still writing.
const WRITING_WAIT_MS = 1000;

// The compile's command line and files, under the compile instance's /data.
export const LEARN_ARGS = ["play", "--learned", "psx", "/data/records", "/data/out", "/data/interp"];
export const learnSeed = (records, interp) =>
	new Map([
		["records", records],
		["interp", interp],
	]);
// The blob a compile instance wrote: wasi.files(wasi.data).get(LEARN_OUT).
export const LEARN_OUT = "out";

// SDL for a compile instance, which never opens a window: every function
// answers 0.
export const NO_SDL = new Proxy({}, { get: () => () => 0 });

// The imports for a host that compiles nothing mid-run.
export const NO_LEARN = {
	start: () => -1,
	poll: () => POLL_FAILED,
};

export class LearnImports {
	// startCb(records, interp, buffer, gen), with copies of the bytes, the
	// LEARN SharedArrayBuffer (made at the first start) and the compile's
	// generation, for learnDeliver: true when a compile was started.
	constructor(startCb) {
		this.buffer = null;
		this.words = null;
		this.bytes = null;
		this.startCb = startCb;
		this.memory = null;
		this.imports = {
			// The compile's generation (> 0), or -1.
			start: (rec, recLen, interp, interpLen) => {
				if (this.buffer === null) {
					this.buffer = new SharedArrayBuffer(LEARN.SIZE);
					this.words = new Int32Array(this.buffer, 0, LEARN.DATA / 4);
					this.bytes = new Uint8Array(this.buffer, LEARN.DATA, LEARN.DATA_MAX);
				}
				const gen = Atomics.add(this.words, LEARN.GEN_WORD, 1) + 1;
				this.reset();
				const m = new Uint8Array(this.memory.buffer);
				const records = m.slice(rec, rec + recLen);
				const list = m.slice(interp, interp + interpLen);
				return this.startCb(records, list, this.buffer, gen) ? gen : -1;
			},
			poll: (buf, cap, timeoutMs, gen) => {
				if (this.words === null) return POLL_FAILED;
				const end = performance.now() + timeoutMs;
				for (;;) {
					const state = Atomics.load(this.words, LEARN.STATE_WORD);
					if (state === READY) {
						if (Atomics.load(this.words, LEARN.BLOB_GEN_WORD) === gen) break;
						Atomics.compareExchange(this.words, LEARN.STATE_WORD, READY, EMPTY);
						continue;
					}
					if (state === TAKEN) return POLL_FAILED;
					const left = end - performance.now();
					if (left <= 0) return POLL_RUNNING;
					Atomics.wait(this.words, LEARN.STATE_WORD, state, left);
				}
				const n = Atomics.load(this.words, LEARN.LEN_WORD);
				if (n <= 0) {
					Atomics.store(this.words, LEARN.STATE_WORD, EMPTY);
					return n === OVERSIZED ? POLL_OVERSIZED : POLL_FAILED;
				}
				if (cap >= n) {
					new Uint8Array(this.memory.buffer, buf, n).set(this.bytes.subarray(0, n));
					Atomics.store(this.words, LEARN.STATE_WORD, TAKEN);
				}
				return n;
			},
		};
	}

	attach(instance) {
		this.memory = instance.exports.memory;
	}

	// The state word back to EMPTY, once no deliverer is writing: one that
	// is finishes, and its blob (of a generation before) is dropped.
	reset() {
		for (;;) {
			const state = Atomics.load(this.words, LEARN.STATE_WORD);
			if (state === EMPTY) return;
			if (state === WRITING) {
				Atomics.wait(this.words, LEARN.STATE_WORD, WRITING, WRITING_WAIT_MS);
				continue;
			}
			if (Atomics.compareExchange(this.words, LEARN.STATE_WORD, state, EMPTY) === state) return;
		}
	}
}

// Hand the blob of compile gen (null: it failed) to poll; nothing when gen
// is not the compile in flight. An empty blob is a failure. log(text) says
// so, and says once per buffer that a blob over LEARN.DATA_MAX was dropped.
export function learnDeliver(buffer, blob, log, gen) {
	const words = new Int32Array(buffer, 0, LEARN.DATA / 4);
	if (Atomics.compareExchange(words, LEARN.STATE_WORD, EMPTY, WRITING) !== EMPTY) return;
	if (Atomics.load(words, LEARN.GEN_WORD) !== gen) {
		Atomics.store(words, LEARN.STATE_WORD, EMPTY);
		Atomics.notify(words, LEARN.STATE_WORD);
		return;
	}
	let n = FAILED;
	if (blob !== null && blob.byteLength === 0) {
		log("play: a mid-run learned compile made an empty blob; failed\n");
	} else if (blob !== null && blob.byteLength > LEARN.DATA_MAX) {
		n = OVERSIZED;
		if (Atomics.exchange(words, LEARN.WARNED_WORD, 1) === 0) {
			log(`play: a mid-run learned blob of ${blob.byteLength} bytes is over the ${LEARN.DATA_MAX} the page passes; dropped (the next run compiles it)\n`);
		}
	} else if (blob !== null) {
		new Uint8Array(buffer, LEARN.DATA, blob.byteLength).set(blob);
		n = blob.byteLength;
	}
	Atomics.store(words, LEARN.LEN_WORD, n);
	Atomics.store(words, LEARN.BLOB_GEN_WORD, gen);
	Atomics.store(words, LEARN.STATE_WORD, READY);
	Atomics.notify(words, LEARN.STATE_WORD);
}
