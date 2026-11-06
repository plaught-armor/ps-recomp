// WASI preview1 for recomp.wasm and play.wasm: just the imports the modules
// have, shared by the web pages' Workers and tests/wasi/run.mjs. No
// dependencies.
//
// One preopen, "." (fd 3): an in-memory directory that collects what recomp
// writes, with two directories mounted in it: "disc", read-only, of named
// readers {size, read(offset, length) -> Uint8Array}; and "data", for play's
// settings and saves, lost when the page goes. Odin's core:os strips the
// leading "/" from paths and preopen names alike, so "/disc/x" is "disc/x"
// in the preopen. One preopen, not one per directory: core:os indexes past
// the end of a path that equals a preopen's name (match_preopen), and
// make_directory_all("/data/x") reaches "/data" itself. Clocks are performance.now() and Date.now(); poll_oneoff takes clock
// subscriptions only and blocks the thread until the deadline, which a Worker
// or Node may do. Rights are not checked: Odin's
// core:os opens read-only files without the fd_seek right that fd_pread
// needs. A 64 KiB block cache sits in front of each reader, so sector-sized
// reads do not each reach the reader. One instance per run: proc_exit throws.

const ERR = {
	SUCCESS: 0, ACCES: 2, BADF: 8, BUSY: 10, EXIST: 20, INVAL: 28, ISDIR: 31, NOENT: 44,
	NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58, ROFS: 69, SPIPE: 70,
	NOTCAPABLE: 76,
};
const CLOCK = { REALTIME: 0, MONOTONIC: 1, PROCESS_CPUTIME: 2, THREAD_CPUTIME: 3 };
const EVENTTYPE_CLOCK = 0;
const SUBCLOCK_ABSTIME = 1;
const FILETYPE = { CHARACTER_DEVICE: 2, DIRECTORY: 3, REGULAR_FILE: 4 };
const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };
const FDFLAG_APPEND = 1;
const WHENCE = { SET: 0, CUR: 1, END: 2 };

const BLOCK = 65536;
const BLOCKS = 64; // 4 MiB of cache per reader
const DIRECT = 1 << 20; // reads this large go to the reader in one call

// The exit status of a run, thrown by proc_exit.
export class Exit extends Error {
	constructor(code) {
		super(`exit ${code}`);
		this.code = code;
	}
}

// A reader behind an LRU of BLOCK-aligned blocks.
class Cached {
	constructor(reader, stats) {
		this.reader = reader;
		this.size = reader.size;
		this.stats = stats;
		this.blocks = new Map(); // block index -> Uint8Array, oldest first
	}
	block(i) {
		let b = this.blocks.get(i);
		if (b) {
			this.stats.hits++;
			this.blocks.delete(i);
		} else {
			this.stats.misses++;
			const at = i * BLOCK;
			b = this.fetch(at, Math.min(BLOCK, this.size - at));
			if (this.blocks.size >= BLOCKS) this.blocks.delete(this.blocks.keys().next().value);
		}
		this.blocks.set(i, b);
		return b;
	}
	fetch(at, n) {
		const b = this.reader.read(at, n);
		if (b.length !== n) throw new Error(`reader: ${b.length} of ${n} bytes at ${at}`);
		this.stats.bytes += n;
		return b;
	}
	// Copies bytes at `at` into dst; returns the count (short only at the end).
	read(at, dst) {
		const end = Math.min(at + dst.length, this.size);
		if (at >= end) return 0;
		if (end - at >= DIRECT) {
			this.stats.direct++;
			dst.set(this.fetch(at, end - at));
			return end - at;
		}
		for (let o = at; o < end;) {
			const i = Math.floor(o / BLOCK), b = this.block(i), s = o - i * BLOCK;
			const n = Math.min(b.length - s, end - o);
			dst.set(b.subarray(s, s + n), o - at);
			o += n;
		}
		return end - at;
	}
}

// A file recomp writes: a buffer that grows.
class Mem {
	constructor() {
		this.buf = new Uint8Array(0);
		this.size = 0;
	}
	read(at, dst) {
		const n = Math.max(0, Math.min(dst.length, this.size - at));
		dst.set(this.buf.subarray(at, at + n));
		return n;
	}
	write(at, src) {
		const end = at + src.length;
		if (end > this.buf.length) {
			const b = new Uint8Array(Math.max(end, this.buf.length * 2, 4096));
			b.set(this.buf.subarray(0, this.size));
			this.buf = b;
		}
		this.buf.set(src, at);
		this.size = Math.max(this.size, end);
	}
}

const dir = (writable) => ({ entries: new Map(), writable });
const isDir = (node) => node.entries !== undefined;

export class Wasi {
	// args: argv strings. env: an object of environment variables. disc: Map
	// of name -> reader. log(fd, text): fd 1 and 2.
	constructor({ args, env = {}, disc, log }) {
		this.args = args.map((a) => new TextEncoder().encode(a + "\0"));
		this.env = Object.entries(env).map(([k, v]) => new TextEncoder().encode(`${k}=${v}\0`));
		this.log = log;
		this.decoders = [null, new TextDecoder(), new TextDecoder()];
		this.stats = {
			calls: {},
			unknown: [],
			cache: { hits: 0, misses: 0, direct: 0, bytes: 0 },
		};
		const discDir = dir(false);
		for (const [name, reader] of disc) discDir.entries.set(name, new Cached(reader, this.stats.cache));
		this.out = dir(true);
		this.data = dir(true);
		this.out.entries.set("disc", discDir);
		this.out.entries.set("data", this.data);
		// Neither removed nor renamed, and not among recomp's files.
		this.mounts = new Set([discDir, this.data]);
		this.fds = new Map([[3, { node: this.out, pos: 0, preopen: "." }]]);
		this.next = 4;
		this.sleeper = null; // an Int32Array on a SharedArrayBuffer, for Atomics.wait
		this.memory = null;
		this.view = null;

		const fns = {};
		for (const [name, fn] of Object.entries(this.calls())) {
			fns[name] = (...a) => {
				this.stats.calls[name] = (this.stats.calls[name] ?? 0) + 1;
				return fn(...a);
			};
		}
		const unknown = new Set();
		this.imports = {
			wasi_snapshot_preview1: new Proxy(fns, {
				get: (t, name) => {
					if (name in t || typeof name !== "string") return t[name];
					return () => {
						if (!unknown.has(name)) {
							unknown.add(name);
							this.stats.unknown.push(name);
							this.log(2, `wasi: ${name} not provided\n`);
						}
						return ERR.NOSYS;
					};
				},
			}),
		};
	}

	// Runs the instance's _start; returns the exit code. A trap propagates.
	run(instance) {
		this.memory = instance.exports.memory;
		try {
			instance.exports._start();
			return 0;
		} catch (e) {
			if (e instanceof Exit) return e.code;
			throw e;
		} finally {
			for (const fd of [1, 2]) {
				const tail = this.decoders[fd].decode();
				if (tail) this.log(fd, tail);
			}
		}
	}

	// Put files in /data before the run: path ("a/b") -> bytes.
	seed(files) {
		for (const [path, bytes] of files) {
			const names = path.split("/");
			let node = this.data;
			for (const name of names.slice(0, -1)) {
				if (!node.entries.has(name)) node.entries.set(name, dir(true));
				node = node.entries.get(name);
			}
			const f = new Mem();
			f.write(0, bytes);
			node.entries.set(names.at(-1), f);
		}
	}

	// The files recomp wrote (or, with root this.data, play's): path -> bytes
	// (views of the file buffers). The mounts are not walked.
	files(root = this.out) {
		const out = new Map();
		const walk = (node, prefix) => {
			for (const [name, n] of node.entries) {
				if (this.mounts.has(n)) continue;
				if (isDir(n)) walk(n, prefix + name + "/");
				else out.set(prefix + name, n.buf.subarray(0, n.size));
			}
		};
		walk(root, "");
		return out;
	}

	// Blocks the thread for `ms` milliseconds.
	sleep(ms) {
		if (!(ms > 0)) return;
		if (this.sleeper === null && typeof SharedArrayBuffer === "function") {
			this.sleeper = new Int32Array(new SharedArrayBuffer(4));
		}
		if (this.sleeper !== null) {
			Atomics.wait(this.sleeper, 0, 0, ms);
			return;
		}
		for (const end = performance.now() + ms; performance.now() < end;);
	}

	dv() {
		if (!this.view || this.view.buffer !== this.memory.buffer) this.view = new DataView(this.memory.buffer);
		return this.view;
	}
	bytes(ptr, len) {
		return new Uint8Array(this.memory.buffer, ptr, len);
	}
	str(ptr, len) {
		return new TextDecoder().decode(this.bytes(ptr, len));
	}
	iovs(ptr, n) {
		const dv = this.dv(), r = [];
		for (let i = 0; i < n; i++) r.push(this.bytes(dv.getUint32(ptr + i * 8, true), dv.getUint32(ptr + i * 8 + 4, true)));
		return r;
	}

	// Walks a relative path from a directory fd. Returns {parent, name, node}
	// (node undefined when the last component is missing) or an errno.
	resolve(fd, path) {
		const f = this.fds.get(fd);
		if (!f) return ERR.BADF;
		if (!isDir(f.node)) return ERR.NOTDIR;
		const parts = path.split("/").filter((p) => p !== "" && p !== ".");
		if (parts.includes("..")) return ERR.NOTCAPABLE;
		if (parts.length === 0) return { parent: f.node, name: ".", node: f.node };
		let parent = f.node;
		for (const p of parts.slice(0, -1)) {
			parent = parent.entries.get(p);
			if (!parent) return ERR.NOENT;
			if (!isDir(parent)) return ERR.NOTDIR;
		}
		const name = parts[parts.length - 1];
		return { parent, name, node: parent.entries.get(name) };
	}

	// Nanoseconds on clock `id`, or null for an unknown clock. The CPU-time
	// clocks read the monotonic one.
	now(id) {
		switch (id) {
			case CLOCK.REALTIME:
				return BigInt(Date.now()) * 1000000n;
			case CLOCK.MONOTONIC:
			case CLOCK.PROCESS_CPUTIME:
			case CLOCK.THREAD_CPUTIME:
				return BigInt(Math.round(performance.now() * 1e6));
		}
		return null;
	}

	// The directory holding directory `d`, or null for a preopen's root.
	parentOf(d) {
		const find = (node) => {
			for (const n of node.entries.values()) {
				if (!isDir(n)) continue;
				if (n === d) return node;
				const p = find(n);
				if (p) return p;
			}
			return null;
		};
		for (const f of this.fds.values()) {
			if (f.preopen === undefined) continue;
			if (f.node === d) return null;
			const p = find(f.node);
			if (p) return p;
		}
		return null;
	}

	filestat(ptr, node, size) {
		const dv = this.dv();
		this.bytes(ptr, 64).fill(0);
		dv.setUint8(ptr + 16, node === null ? FILETYPE.CHARACTER_DEVICE : isDir(node) ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
		dv.setBigUint64(ptr + 24, 1n, true);
		dv.setBigUint64(ptr + 32, BigInt(size), true);
		return ERR.SUCCESS;
	}

	read(fd, iovs, at) {
		if (fd === 0) return [ERR.SUCCESS, 0];
		const f = this.fds.get(fd);
		if (!f) return [ERR.BADF, 0];
		if (isDir(f.node)) return [ERR.ISDIR, 0];
		let pos = at ?? f.pos, total = 0;
		for (const v of iovs) {
			const n = f.node.read(pos, v);
			pos += n;
			total += n;
			if (n < v.length) break;
		}
		if (at === undefined) f.pos = pos;
		return [ERR.SUCCESS, total];
	}

	write(fd, iovs, at) {
		const f = this.fds.get(fd);
		if (fd === 1 || fd === 2) {
			if (at !== undefined) return [ERR.SPIPE, 0];
			let total = 0;
			for (const v of iovs) {
				this.log(fd, this.decoders[fd].decode(v, { stream: true }));
				total += v.length;
			}
			return [ERR.SUCCESS, total];
		}
		if (!f || fd === 0) return [ERR.BADF, 0];
		if (isDir(f.node)) return [ERR.ISDIR, 0];
		if (!(f.node instanceof Mem)) return [ERR.ROFS, 0];
		let pos = at ?? (f.append ? f.node.size : f.pos), total = 0;
		for (const v of iovs) {
			f.node.write(pos, v);
			pos += v.length;
			total += v.length;
		}
		if (at === undefined) f.pos = pos;
		return [ERR.SUCCESS, total];
	}

	calls() {
		const enc = new TextEncoder();
		const out32 = (ptr, v) => this.dv().setUint32(ptr, v, true);
		return {
			args_sizes_get: (argc, size) => {
				out32(argc, this.args.length);
				out32(size, this.args.reduce((s, a) => s + a.length, 0));
				return ERR.SUCCESS;
			},
			args_get: (argv, buf) => {
				for (const [i, a] of this.args.entries()) {
					out32(argv + i * 4, buf);
					this.bytes(buf, a.length).set(a);
					buf += a.length;
				}
				return ERR.SUCCESS;
			},
			environ_sizes_get: (count, size) => {
				out32(count, this.env.length);
				out32(size, this.env.reduce((s, e) => s + e.length, 0));
				return ERR.SUCCESS;
			},
			environ_get: (environ, buf) => {
				for (const [i, e] of this.env.entries()) {
					out32(environ + i * 4, buf);
					this.bytes(buf, e.length).set(e);
					buf += e.length;
				}
				return ERR.SUCCESS;
			},
			clock_time_get: (id, _precision, out) => {
				const ns = this.now(id);
				if (ns === null) return ERR.INVAL;
				this.dv().setBigUint64(out, ns, true);
				return ERR.SUCCESS;
			},
			// Clock subscriptions only: sleeps until the earliest deadline and
			// reports every subscription due by then.
			poll_oneoff: (subs, events, n, out) => {
				if (n === 0) return ERR.INVAL;
				const dv = this.dv(), due = [];
				let wake = null;
				for (let i = 0; i < n; i++) {
					const s = subs + i * 48;
					if (dv.getUint8(s + 8) !== EVENTTYPE_CLOCK) return ERR.NOTSUP;
					const id = dv.getUint32(s + 16, true), now = this.now(id);
					if (now === null) return ERR.INVAL;
					const timeout = dv.getBigUint64(s + 24, true);
					const at = dv.getUint16(s + 40, true) & SUBCLOCK_ABSTIME ? timeout : now + timeout;
					const ms = Number(at - now) / 1e6;
					due.push({ userdata: dv.getBigUint64(s, true), ms });
					wake = wake === null ? ms : Math.min(wake, ms);
				}
				this.sleep(wake);
				let k = 0;
				for (const d of due) {
					if (d.ms > wake) continue;
					const e = events + k++ * 32;
					this.bytes(e, 32).fill(0);
					dv.setBigUint64(e, d.userdata, true);
					dv.setUint8(e + 10, EVENTTYPE_CLOCK);
				}
				out32(out, k);
				return ERR.SUCCESS;
			},
			fd_prestat_get: (fd, ptr) => {
				const f = this.fds.get(fd);
				if (!f?.preopen) return ERR.BADF;
				this.dv().setUint32(ptr, 0, true); // tag 0: a directory
				out32(ptr + 4, enc.encode(f.preopen).length);
				return ERR.SUCCESS;
			},
			fd_prestat_dir_name: (fd, ptr, len) => {
				const f = this.fds.get(fd);
				if (!f?.preopen) return ERR.BADF;
				const name = enc.encode(f.preopen);
				if (len < name.length) return ERR.INVAL;
				this.bytes(ptr, name.length).set(name);
				return ERR.SUCCESS;
			},
			proc_exit: (code) => {
				throw new Exit(code);
			},
			random_get: (ptr, len) => {
				for (let o = 0; o < len; o += 65536) crypto.getRandomValues(this.bytes(ptr + o, Math.min(65536, len - o)));
				return ERR.SUCCESS;
			},
			path_open: (fd, _dirflags, path, len, oflags, _base, _inheriting, fdflags, out) => {
				const r = this.resolve(fd, this.str(path, len));
				if (typeof r === "number") return r;
				let node = r.node;
				if (node) {
					if (oflags & OFLAGS.CREAT && oflags & OFLAGS.EXCL) return ERR.EXIST;
					if (oflags & OFLAGS.DIRECTORY && !isDir(node)) return ERR.NOTDIR;
					if (oflags & OFLAGS.TRUNC) {
						if (!(node instanceof Mem)) return isDir(node) ? ERR.ISDIR : ERR.ROFS;
						node.size = 0;
					}
				} else {
					if (!(oflags & OFLAGS.CREAT)) return ERR.NOENT;
					if (!r.parent.writable) return ERR.ROFS;
					node = new Mem();
					r.parent.entries.set(r.name, node);
				}
				const n = this.next++;
				this.fds.set(n, { node, pos: 0, append: (fdflags & FDFLAG_APPEND) !== 0 });
				out32(out, n);
				return ERR.SUCCESS;
			},
			path_create_directory: (fd, path, len) => {
				const r = this.resolve(fd, this.str(path, len));
				if (typeof r === "number") return r;
				if (r.node) return ERR.EXIST;
				if (!r.parent.writable) return ERR.ROFS;
				r.parent.entries.set(r.name, dir(true));
				return ERR.SUCCESS;
			},
			path_unlink_file: (fd, path, len) => {
				const r = this.resolve(fd, this.str(path, len));
				if (typeof r === "number") return r;
				if (!r.node) return ERR.NOENT;
				if (isDir(r.node)) return ERR.ISDIR;
				if (!r.parent.writable) return ERR.ROFS;
				r.parent.entries.delete(r.name);
				return ERR.SUCCESS;
			},
			path_remove_directory: (fd, path, len) => {
				const r = this.resolve(fd, this.str(path, len));
				if (typeof r === "number") return r;
				if (!r.node) return ERR.NOENT;
				if (!isDir(r.node)) return ERR.NOTDIR;
				if (this.mounts.has(r.node)) return ERR.BUSY;
				if (r.name === "." || !r.parent.writable) return ERR.ROFS;
				if (r.node.entries.size > 0) return ERR.NOTEMPTY;
				r.parent.entries.delete(r.name);
				return ERR.SUCCESS;
			},
			// As POSIX rename: replaces a file, or an empty directory with a
			// directory.
			path_rename: (fd, path, len, newFd, newPath, newLen) => {
				const a = this.resolve(fd, this.str(path, len));
				if (typeof a === "number") return a;
				const b = this.resolve(newFd, this.str(newPath, newLen));
				if (typeof b === "number") return b;
				if (!a.node) return ERR.NOENT;
				if (a.name === "." || b.name === ".") return ERR.INVAL;
				if (this.mounts.has(a.node) || this.mounts.has(b.node)) return ERR.BUSY;
				if (!a.parent.writable || !b.parent.writable) return ERR.ROFS;
				if (a.node === b.node) return ERR.SUCCESS;
				if (isDir(a.node)) {
					for (let d = b.parent; d; d = this.parentOf(d)) if (d === a.node) return ERR.INVAL;
				}
				if (b.node) {
					if (isDir(a.node) !== isDir(b.node)) return isDir(b.node) ? ERR.ISDIR : ERR.NOTDIR;
					if (isDir(b.node) && b.node.entries.size > 0) return ERR.NOTEMPTY;
				}
				a.parent.entries.delete(a.name);
				b.parent.entries.set(b.name, a.node);
				return ERR.SUCCESS;
			},
			path_filestat_get: (fd, _flags, path, len, ptr) => {
				const r = this.resolve(fd, this.str(path, len));
				if (typeof r === "number") return r;
				if (!r.node) return ERR.NOENT;
				return this.filestat(ptr, r.node, isDir(r.node) ? 0 : r.node.size);
			},
			fd_filestat_get: (fd, ptr) => {
				const f = this.fds.get(fd);
				if (fd <= 2) return this.filestat(ptr, null, 0);
				if (!f) return ERR.BADF;
				return this.filestat(ptr, f.node, isDir(f.node) ? 0 : f.node.size);
			},
			fd_readdir: (fd, buf, len, cookie, used) => {
				const f = this.fds.get(fd);
				if (!f) return ERR.BADF;
				if (!isDir(f.node)) return ERR.NOTDIR;
				const names = [".", "..", ...f.node.entries.keys()];
				const bytes = [];
				let size = 0;
				for (let i = Number(cookie); i < names.length && size < len; i++) {
					const name = enc.encode(names[i]), node = f.node.entries.get(names[i]);
					const e = new Uint8Array(24 + name.length), dv = new DataView(e.buffer);
					dv.setBigUint64(0, BigInt(i + 1), true);
					dv.setUint32(16, name.length, true);
					dv.setUint8(20, !node || isDir(node) ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
					e.set(name, 24);
					bytes.push(e);
					size += e.length;
				}
				let o = 0;
				for (const e of bytes) {
					const n = Math.min(e.length, len - o);
					this.bytes(buf + o, n).set(e.subarray(0, n));
					o += n;
				}
				out32(used, o);
				return ERR.SUCCESS;
			},
			fd_read: (fd, iovs, n, out) => {
				const [err, total] = this.read(fd, this.iovs(iovs, n));
				if (err === ERR.SUCCESS) out32(out, total);
				return err;
			},
			fd_pread: (fd, iovs, n, at, out) => {
				const [err, total] = this.read(fd, this.iovs(iovs, n), Number(at));
				if (err === ERR.SUCCESS) out32(out, total);
				return err;
			},
			fd_write: (fd, iovs, n, out) => {
				const [err, total] = this.write(fd, this.iovs(iovs, n));
				if (err === ERR.SUCCESS) out32(out, total);
				return err;
			},
			fd_pwrite: (fd, iovs, n, at, out) => {
				const [err, total] = this.write(fd, this.iovs(iovs, n), Number(at));
				if (err === ERR.SUCCESS) out32(out, total);
				return err;
			},
			fd_seek: (fd, offset, whence, out) => {
				const f = this.fds.get(fd);
				if (fd <= 2) return ERR.SPIPE;
				if (!f) return ERR.BADF;
				if (isDir(f.node)) return ERR.ISDIR;
				const base = whence === WHENCE.SET ? 0 : whence === WHENCE.CUR ? f.pos : whence === WHENCE.END ? f.node.size : NaN;
				const pos = base + Number(offset);
				if (!(pos >= 0)) return ERR.INVAL;
				f.pos = pos;
				this.dv().setBigUint64(out, BigInt(pos), true);
				return ERR.SUCCESS;
			},
			fd_sync: (fd) => (this.fds.has(fd) || fd <= 2 ? ERR.SUCCESS : ERR.BADF),
			fd_close: (fd) => (this.fds.delete(fd) ? ERR.SUCCESS : ERR.BADF),
		};
	}
}
