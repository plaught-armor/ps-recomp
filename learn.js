// A mid-run learned compile (play/midload_learned.odin): the play module's
// "system:ps_learn" imports, and the relay that runs the compile in a
// worker of its own (`play --learned <psx | ee>`, another instance of the same
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

// The compile's command line for cpu (start's: 0 the PS1, 1 a PS2 game's
// EE) and its files, under the compile instance's /data.
export const learnArgs = (cpu) => ["play", "--learned", cpu === 1 ? "ee" : "psx", "/data/records", "/data/out", "/data/interp"];
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
	// startCb(records, interp, buffer, gen, cpu), with copies of the bytes,
	// the LEARN SharedArrayBuffer (made at the first start), the compile's
	// generation, for learnDeliver, and its cpu (learnArgs): true when a
	// compile was started.
	constructor(startCb) {
		this.buffer = null;
		this.words = null;
		this.bytes = null;
		this.startCb = startCb;
		this.memory = null;
		this.imports = {
			// The compile's generation (> 0), or -1.
			start: (rec, recLen, interp, interpLen, cpu) => {
				const gen = this.begin();
				const records = this.copy(rec, recLen);
				const list = this.copy(interp, interpLen);
				return this.startCb(records, list, this.buffer, gen, cpu) ? gen : -1;
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

	// The next compile's generation, with the buffer made at the first and
	// its state word back to EMPTY.
	begin() {
		if (this.buffer === null) {
			this.buffer = new SharedArrayBuffer(LEARN.SIZE);
			this.words = new Int32Array(this.buffer, 0, LEARN.DATA / 4);
			this.bytes = new Uint8Array(this.buffer, LEARN.DATA, LEARN.DATA_MAX);
		}
		const gen = Atomics.add(this.words, LEARN.GEN_WORD, 1) + 1;
		this.reset();
		return gen;
	}

	// A copy of len bytes of the module's memory at ptr.
	copy(ptr, len) {
		return new Uint8Array(this.memory.buffer).slice(ptr, ptr + len);
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
// so, and says that a blob over LEARN.DATA_MAX was dropped, with what it
// holds from the native blob header (recomp/native/blob.odin): word 4, its
// functions, or for a VU blob word 7, its microprograms (spans); what names
// the compile in those lines. The run does not ask for a dropped blob's code again.
export function learnDeliver(buffer, blob, log, gen, what = "learned") {
	const words = new Int32Array(buffer, 0, LEARN.DATA / 4);
	if (Atomics.compareExchange(words, LEARN.STATE_WORD, EMPTY, WRITING) !== EMPTY) return;
	if (Atomics.load(words, LEARN.GEN_WORD) !== gen) {
		Atomics.store(words, LEARN.STATE_WORD, EMPTY);
		Atomics.notify(words, LEARN.STATE_WORD);
		return;
	}
	let n = FAILED;
	if (blob !== null && blob.byteLength === 0) {
		log(`play: a mid-run ${what} compile made an empty blob; failed\n`);
	} else if (blob !== null && blob.byteLength > LEARN.DATA_MAX) {
		n = OVERSIZED;
		const [word, unit] = what === "VU" ? [7, "microprograms"] : [4, "functions"];
		const count = blob.byteLength >= 4 * (word + 1) ? new DataView(blob.buffer, blob.byteOffset).getUint32(4 * word, true) : 0;
		log(`play: a mid-run ${what} blob of ${count} ${unit}, ${blob.byteLength} bytes, is over the ${LEARN.DATA_MAX} the page passes; dropped: they stay interpreted this run (the next run compiles them)\n`);
	} else if (blob !== null) {
		new Uint8Array(buffer, LEARN.DATA, blob.byteLength).set(blob);
		n = blob.byteLength;
	}
	Atomics.store(words, LEARN.LEN_WORD, n);
	Atomics.store(words, LEARN.BLOB_GEN_WORD, gen);
	Atomics.store(words, LEARN.STATE_WORD, READY);
	Atomics.notify(words, LEARN.STATE_WORD);
}

// A mid-run VU conversion (play/midload_vu_wasi.odin): the play module's
// "system:ps_vu" imports, the same protocol as LearnImports' on a buffer of
// its own. start hands startCb(exe, vu0, vu1, buffer, gen) copies of the
// game's executable and its VU0 and VU1 captures (empty: none), for
// `play --convert-vu` (vuArgs) in a worker of its own; poll is
// LearnImports'.
export class VuImports extends LearnImports {
	constructor(startCb) {
		super(startCb);
		this.imports.start = (exe, exeLen, vu0, vu0Len, vu1, vu1Len) => {
			const gen = this.begin();
			return this.startCb(this.copy(exe, exeLen), this.copy(vu0, vu0Len), this.copy(vu1, vu1Len), this.buffer, gen) ? gen : -1;
		};
	}
}

// The conversion's command line, its files under the instance's /data
// (vuSeed), and the blob it writes there (VU_OUT); a capture of length 0
// is not passed. The last argument is the pid play checks for (none here).
export const VU_OUT = "out";
export const vuArgs = (vu0, vu1) => ["play", "--convert-vu", "/data/exe", "/data/" + VU_OUT, vu0.byteLength > 0 ? "/data/vu0" : "", vu1.byteLength > 0 ? "/data/vu1" : "", "0"];
export const vuSeed = (exe, vu0, vu1) =>
	new Map([
		["exe", exe],
		...(vu0.byteLength > 0 ? [["vu0", vu0]] : []),
		...(vu1.byteLength > 0 ? [["vu1", vu1]] : []),
	]);

// The imports for a host that converts nothing mid-run.
export const NO_VU = NO_LEARN;
