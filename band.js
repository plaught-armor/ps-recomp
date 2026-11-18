// The software GS's band workers on the web (ps2/gs/band_wasm.odin): a
// pool of Workers, each running its own instance of play.wasm on the play
// instance's shared memory. The play thread never yields while the module
// runs, so the pool is made and instantiated before the run, and a spawn
// (the system:ps_band import) reaches an idle Worker through a word it
// waits on, not a message.
//
// Each Worker has CTL_WORDS words of ctl: its state, then the spawn's
// arguments. A spawn takes an IDLE Worker (CLAIMED), writes the arguments
// and sets GO; the Worker runs band_entry on the stack and TLS the module
// gave, sets IDLE, then stores 1 at done (in the module's memory) and
// notifies it, which is what the module waits on to free the stack.

import { monotonicNs } from "./wasi.js";

const CTL_WORDS = 8;
const IDLE = 0;
const CLAIMED = 1;
const GO = 2;
// Argument words after the state.
const W = 1;
const TOP = 2;
const TLS = 3;
const TLS_SIZE = 4;
const DONE = 5;

// For a module run without a pool: no spawn starts a Worker, so the
// software GS draws on the play thread.
export const NO_BAND = { spawn: () => 0 };

// The pool's half on the play thread. start(i, data) makes Worker i with
// data ({module, memory, ctl, id}) and resolves once it has instantiated
// the module (its first message), or rejects.
export class Bands {
	static async make(module, memory, n, start) {
		const ctl = new Int32Array(new SharedArrayBuffer(n * CTL_WORDS * 4));
		await Promise.all(Array.from({ length: n }, (_, id) => start(id, { module, memory, ctl, id })));
		return new Bands(ctl, n);
	}

	constructor(ctl, n) {
		this.ctl = ctl;
		this.n = n;
		this.imports = {
			spawn: (w, top, tls, tlsSize, done) => this.spawn(w, top, tls, tlsSize, done),
		};
	}

	spawn(w, top, tls, tlsSize, done) {
		for (let i = 0; i < this.n; i++) {
			const at = i * CTL_WORDS;
			if (Atomics.compareExchange(this.ctl, at, IDLE, CLAIMED) !== IDLE) continue;
			this.ctl[at + W] = w;
			this.ctl[at + TOP] = top;
			this.ctl[at + TLS] = tls;
			this.ctl[at + TLS_SIZE] = tlsSize;
			this.ctl[at + DONE] = done;
			Atomics.store(this.ctl, at, GO);
			Atomics.notify(this.ctl, at);
			return 1;
		}
		return 0;
	}
}

// A pool Worker: instantiates the module on the shared memory, calls
// ready(), then runs every spawn given to it, forever. Its imports other
// than the memory are never called by band_entry, except fd_write for an
// assertion's message, which goes to log, and clock_time_get, which reads
// the monotonic clock the main thread reads; the rest throw.
export async function bandWorker({ module, memory, ctl, id }, ready, log) {
	const imports = { env: { memory } };
	for (const { module: m, name, kind } of WebAssembly.Module.imports(module)) {
		if (kind !== "function") continue;
		imports[m] ??= {};
		imports[m][name] = () => {
			throw new Error(`band worker ${id}: ${m}.${name} called`);
		};
	}
	const wasi = imports.wasi_snapshot_preview1;
	if (wasi?.fd_write) {
		wasi.fd_write = (_fd, iovs, n, nWritten) => {
			const dv = new DataView(memory.buffer);
			let total = 0;
			for (let k = 0; k < n; k++) {
				const ptr = dv.getUint32(iovs + 8 * k, true);
				const len = dv.getUint32(iovs + 8 * k + 4, true);
				log(new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len).slice()));
				total += len;
			}
			dv.setUint32(nWritten, total, true);
			return 0;
		};
	}
	if (wasi?.clock_time_get) {
		wasi.clock_time_get = (_id, _precision, out) => {
			new DataView(memory.buffer).setBigUint64(out, monotonicNs(), true);
			return 0;
		};
	}
	const { exports: ex } = await WebAssembly.instantiate(module, imports);
	ready();
	const at = id * CTL_WORDS;
	for (;;) {
		Atomics.wait(ctl, at, CLAIMED);
		Atomics.wait(ctl, at, IDLE);
		if (Atomics.load(ctl, at) !== GO) continue;
		const done = ctl[at + DONE];
		try {
			if (ex.__wasm_init_tls) {
				if (ex.__tls_size.value > ctl[at + TLS_SIZE]) throw new Error(`TLS of ${ex.__tls_size.value} bytes, ${ctl[at + TLS_SIZE]} given`);
				ex.__wasm_init_tls(ctl[at + TLS]);
			}
			ex.__stack_pointer.value = ctl[at + TOP];
			ex.band_entry(ctl[at + W]);
		} catch (e) {
			// The module waits on the worker's jobs forever: the run hangs
			// here, as a native one would stop on a thread's trap.
			log(`band worker ${id}: ${e?.stack ?? e}\n`);
			return;
		}
		Atomics.store(ctl, at, IDLE);
		// A view made now: the memory may have grown since the last job.
		const words = new Int32Array(memory.buffer);
		Atomics.store(words, done >>> 2, 1);
		Atomics.notify(words, done >>> 2);
	}
}
