// Native code for play.wasm: the "system:ps_native" imports core/code_wasi.odin
// makes. A wasm32 native blob's code is a module (recomp/native/wasm.odin)
// that imports the runtime's memory and function table, one i32 global
// env.s<k> per import slot and env.base, and puts its functions in the table
// from base. instantiate compiles it synchronously (play runs in a Worker or
// Node, where that is allowed) and gives it a range of the table: the
// smallest free range that fits, else the table grows by its functions.
// release clears the range, so a stale index traps instead of running freed
// code, and frees it for the next load: reloading the same blob takes back
// its own range, and the table stops growing. No dependencies.
//
// V8 compiles a wasm function lazily on its first call, on the calling
// thread, inside the frame that first calls it (Okami: learned code at
// f827/f833, 40-50 ms; the native blob at f304, 60 ms). A module core marks
// warm (core/native.odin Native_Warm) is queued, First ones ahead of After
// ones, and warm(deadline) calls its functions before the run does, from
// the pace sleep: each on a second instance of the same Module (so the
// same compiled code) with its own table, zeroed globals and fresh memory,
// at pc 1. No block starts at pc 1, so the code leaves with None at once
// and runs no guest code (recomp/r5900/native.odin, the entry search); a
// trap on the dummy memory is caught. A call starts only when its
// compile, guessed from its body's bytes, ends by the deadline, so the
// sleep is not overrun; one guessed over WARM_MAX_MS, more than most
// frames' sleep, is left to its first call, and the next waits for a sleep
// it fits in.
//
// Liftoff compile time per body byte: most of Okami's calls over 150 KB
// (2.7e-5 to 5.7e-5 ms, Brave 157, 2026-11-19, tmp/okami60/step4-results.md).
const WARM_MS_PER_BYTE = 6e-5;
const WARM_MAX_MS = 12;

export class Native {
	// log(text): where a failed instantiate is said, once.
	constructor({ log }) {
		this.log = log;
		this.said = false;
		this.free = []; // {base, n}, the released ranges
		this.used = new Map(); // base -> n
		this.queue = []; // {table, sizes, next, order}: modules to warm, by order
		this.imports = {
			instantiate: (code, n, slots, nSlots, nFuncs, warm) => this.instantiate(code, n, slots, nSlots, nFuncs, warm),
			release: (base) => this.release(base),
		};
	}

	// Call after instantiating the runtime, before the run.
	attach(instance) {
		this.memory = instance.exports.memory;
		this.table = instance.exports.__indirect_function_table;
	}

	// Table index of the module code[0:n]'s first function, or 0; *nFuncs =
	// how many functions it put in the table. warm: a Native_Warm, 0 none.
	instantiate(code, n, slots, nSlots, nFuncs, warm = 0) {
		try {
			if (this.table === undefined) throw new Error("play.wasm exports no function table");
			const bytes = new Uint8Array(this.memory.buffer, code, n).slice();
			const module = new WebAssembly.Module(bytes);
			const count = elements(bytes);
			if (count === 0) throw new Error("the module has no functions");
			const base = this.take(count);
			const env = { memory: this.memory, table: this.table, base: global(base) };
			const s = new Uint32Array(this.memory.buffer, slots, nSlots);
			for (let k = 0; k < nSlots; k++) env["s" + k] = global(s[k]);
			try {
				new WebAssembly.Instance(module, { env });
			} catch (e) {
				this.release(base);
				throw e;
			}
			new DataView(this.memory.buffer).setUint32(nFuncs, count, true);
			if (warm !== 0) this.enqueue(module, bytes, count, warm);
			return base;
		} catch (e) {
			if (!this.said) this.log(`native: cannot instantiate the wasm32 code: ${e?.message ?? e}\n`);
			this.said = true;
			return 0;
		}
	}

	// Queue module (bytes, count functions) for warm after the queued ones
	// of its order or a lower one; a failure to make its second instance only
	// costs the warm, said once.
	enqueue(module, bytes, count, order) {
		try {
			const g = (v) => new WebAssembly.Global({ value: "i32", mutable: false }, v);
			const env = { table: new WebAssembly.Table({ element: "anyfunc", initial: count }), base: g(0) };
			const { memory, sizes } = layout(bytes, count);
			if (memory !== null) env.memory = new WebAssembly.Memory(memory);
			for (const { module: m, name, kind } of WebAssembly.Module.imports(module)) {
				if (m === "env" && kind === "global" && name !== "base") env[name] = g(0);
			}
			new WebAssembly.Instance(module, { env });
			const at = this.queue.findIndex((d) => d.order > order);
			this.queue.splice(at < 0 ? this.queue.length : at, 0, { table: env.table, sizes, next: 0, order });
		} catch (e) {
			if (!this.saidWarm) this.log(`native: cannot warm the wasm32 code: ${e?.message ?? e}\n`);
			this.saidWarm = true;
		}
	}

	// Call queued functions while each one's guessed compile ends before
	// deadline (a performance.now() time), until the queue is empty.
	warm(deadline) {
		while (this.queue.length > 0) {
			const d = this.queue[0];
			const ms = d.sizes[d.next] * WARM_MS_PER_BYTE;
			if (ms <= WARM_MAX_MS) {
				if (performance.now() + ms >= deadline) return;
				try {
					d.table.get(d.next)?.(1, 0);
				} catch {}
			}
			if (++d.next >= d.sizes.length) this.queue.shift();
		}
	}

	// A range of n table slots: the smallest free one that fits, its rest
	// kept free, else n new slots at the end.
	take(n) {
		let best = -1;
		for (let i = 0; i < this.free.length; i++) {
			if (this.free[i].n >= n && (best < 0 || this.free[i].n < this.free[best].n)) best = i;
		}
		let base;
		if (best < 0) {
			base = this.table.grow(n);
		} else {
			const r = this.free[best];
			base = r.base;
			if (r.n === n) this.free.splice(best, 1);
			else this.free[best] = { base: r.base + n, n: r.n - n };
		}
		this.used.set(base, n);
		return base;
	}

	release(base) {
		const n = this.used.get(base);
		if (n === undefined) throw new Error(`native: release of ${base}, which no instantiate returned`);
		this.used.delete(base);
		for (let i = base; i < base + n; i++) this.table.set(i, null);
		this.free.push({ base, n });
	}
}

const global = (v) => new WebAssembly.Global({ value: "i32", mutable: false }, v | 0);

// How many functions the module's one active element segment (wasm.odin's
// layout: flags 0, offset global.get base, end, then the indices) puts in
// the table.
function elements(b) {
	let at = 8;
	const uleb = () => {
		let v = 0, shift = 0, c;
		do {
			c = b[at++];
			v += (c & 0x7f) * 2 ** shift;
			shift += 7;
		} while (c & 0x80);
		return v;
	};
	while (at < b.length) {
		const id = b[at++];
		const size = uleb();
		const end = at + size;
		if (id === 9) {
			if (uleb() !== 1 || b[at++] !== 0x00 || b[at++] !== 0x23) break;
			uleb();
			if (b[at++] !== 0x0b) break;
			return uleb();
		}
		at = end;
	}
	throw new Error("no element segment of the expected form");
}

// Of module bytes b, whose element segment puts count functions in the
// table: its memory import's limits (the play memory's) as a
// WebAssembly.Memory descriptor, or null when it imports none, and the body
// bytes of the function at each table slot.
function layout(b, count) {
	let at = 8;
	const uleb = () => {
		let v = 0, shift = 0, c;
		do {
			c = b[at++];
			v += (c & 0x7f) * 2 ** shift;
			shift += 7;
		} while (c & 0x80);
		return v;
	};
	let memory = null, elems = null, bodies = null;
	while (at < b.length) {
		const id = b[at++];
		const size = uleb();
		const end = at + size;
		if (id === 2) {
			for (let n = uleb(); n > 0; n--) {
				for (let k = 0; k < 2; k++) {
					const len = uleb(); // module, then field name
					at += len;
				}
				const kind = b[at++];
				if (kind === 0) uleb();
				else if (kind === 1) {
					at++; // element type
					const flags = uleb();
					uleb();
					if (flags & 1) uleb();
				} else if (kind === 2) {
					const flags = uleb();
					const initial = uleb();
					const maximum = flags & 1 ? uleb() : undefined;
					memory = { initial, maximum: maximum ?? initial, shared: (flags & 2) !== 0 };
				} else if (kind === 3) at += 2;
			}
		} else if (id === 9) {
			// One active segment at global.get base (elements checked it).
			uleb(); // segments
			uleb(); // flags
			at++; // global.get
			uleb(); // base
			at++; // end
			elems = new Uint32Array(uleb());
			for (let k = 0; k < elems.length; k++) elems[k] = uleb();
		} else if (id === 10) {
			bodies = new Uint32Array(uleb());
			for (let k = 0; k < bodies.length; k++) {
				bodies[k] = uleb();
				at += bodies[k];
			}
		}
		at = end;
	}
	const sizes = new Uint32Array(count);
	for (let k = 0; k < count; k++) sizes[k] = bodies?.[elems?.[k]] ?? 0;
	return { memory, sizes };
}
