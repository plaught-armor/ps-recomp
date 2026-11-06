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

export class Native {
	// log(text): where a failed instantiate is said, once.
	constructor({ log }) {
		this.log = log;
		this.said = false;
		this.free = []; // {base, n}, the released ranges
		this.used = new Map(); // base -> n
		this.imports = {
			instantiate: (code, n, slots, nSlots, nFuncs) => this.instantiate(code, n, slots, nSlots, nFuncs),
			release: (base) => this.release(base),
		};
	}

	// Call after instantiating the runtime, before the run.
	attach(instance) {
		this.memory = instance.exports.memory;
		this.table = instance.exports.__indirect_function_table;
	}

	// Table index of the module code[0:n]'s first function, or 0; *nFuncs =
	// how many functions it put in the table.
	instantiate(code, n, slots, nSlots, nFuncs) {
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
			return base;
		} catch (e) {
			if (!this.said) this.log(`native: cannot instantiate the wasm32 code: ${e?.message ?? e}\n`);
			this.said = true;
			return 0;
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
