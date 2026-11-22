// The play Worker: runs play.wasm (or, for the gate, another module with the
// same imports) on web/wasi.js and web/sdl.js. It never yields while the
// module runs; the page reaches it only through the SharedArrayBuffers.
import { Bands, NO_BAND } from "./band.js";
import { buildId, NetImports, NO_NET } from "./net.js";
import { LearnImports, NO_LEARN, NO_SDL, NO_VU, VuImports } from "./learn.js";
import { dataLoad, dataSave, discOf, openStored, store } from "./readers.js";
import { Native } from "./native.js";
import { Sdl } from "./sdl.js";
import { memoryImport, Wasi } from "./wasi.js";

addEventListener("securitypolicyviolation", (e) =>
	postMessage({ csp: `csp (worker): ${e.effectiveDirective} blocked ${e.blockedURI || "inline"}` }));

// The bytes of a list of Int16Array chunks, one after the other.
function concat(chunks) {
	const out = new Uint8Array(chunks.reduce((n, c) => n + c.byteLength, 0));
	let at = 0;
	for (const c of chunks) {
		out.set(new Uint8Array(c.buffer, c.byteOffset, c.byteLength), at);
		at += c.byteLength;
	}
	return out;
}

// The transfer list for written files: each one's own buffer.
const buffers = (files) => (files ?? []).map(([, b]) => b.buffer);

// openStored tries on a held lock: LOCK_TRIES more, LOCK_WAIT_MS apart.
const LOCK_TRIES = 30;
const LOCK_WAIT_MS = 100;
// gs_warm calls per step of the raster warm (ps2/gs/warm_wasm.odin): one
// step is 1024 empty rows, so it overruns its sleep's deadline by little.
// The whole warm is 73728 calls; in Okami its nine procs reach TurboFan
// long before frame 254 (OKAMI-60 STEP 20).
const GS_WARM_STEP = 1024;

// The disc for Wasi, {disc, close()}, and how it is read, which goes to the
// page as {store: {kind, ...}}. stored: play that stored disc. store with
// files or urls: copy them into the store under that name first, and read
// them as picked or by URL if that fails (no OPFS, a full quota). Neither:
// read files or urls directly.
async function discFor({ files, urls, store: name, stored }) {
	if (stored) {
		// A Worker the page just stopped (Skip on the conversion) lets go of
		// the disc's handles a little after, so a lock is tried for a while
		// before it is put down to another tab.
		for (let i = 0; ; i++) {
			try {
				return { ...(await openStored(stored)), info: { kind: "stored", name: stored } };
			} catch (e) {
				if (e.name !== "NoModificationAllowedError") throw e;
				if (i === LOCK_TRIES) throw new Error(`${stored}: this disc is playing in another tab`);
			}
			await new Promise((resolve) => setTimeout(resolve, LOCK_WAIT_MS));
		}
	}
	if (name) {
		const t0 = performance.now();
		try {
			await store(name, files ?? urls);
			const d = await openStored(name);
			return { ...d, info: { kind: "opfs", name, copyMs: Math.round(performance.now() - t0) } };
		} catch (e) {
			const estimate = await navigator.storage?.estimate?.().catch(() => null);
			const fallback = { kind: files ? "file" : "url", stored: false, error: `${e.name}: ${e.message}`, estimate };
			return { disc: discOf({ files, urls }), close() {}, info: fallback };
		}
	}
	return { disc: discOf({ files, urls }), close() {}, info: { kind: files ? "file" : "url" } };
}

// wasm: the module's URL. args: argv after the program name. env: the
// module's environment. files, urls, store, stored: the disc (discFor). control,
// audio, present: the page's buffers; net, for netplay, the NET one. test: also send back, with done or
// error, the files the module wrote and, as ring.pcm, every sample it
// queued (their buffers transferred, not copied), plus the compile and run
// times. failSaves: false stores /data back only when the module exits
// with 0 (`play --convert-store`, whose failure leaves its temporary file
// there). Before /data is stored the page gets {saving}: from then on
// stopping the Worker could cut a write short. A mid-run learned compile
// (web/learn.js) goes to the page as {learn: {records, interp, buffer,
// gen, cpu}}: the LEARN buffer, made at the first, the compile's generation
// and its cpu. A mid-run VU conversion goes as {vu: {exe, vu0, vu1,
// buffer, gen}} (VuImports), on a buffer of its own.
//
// The software GS's band workers (PS_BANDS, ps2/gs/band_wasm.odin) run on
// a pool of Workers (web/band.js) made before the run: as many as
// PS_BANDS says, or by default one fewer than the CPUs, at most 8. A page
// that is not cross-origin isolated cannot share memory with them, and
// draws on this Worker.
//
// The run's game data (core/gamedata.odin) counts the CPUs (PS_CORES),
// which it writes only rounded down to 1, 2, 4, 8 or 16.
//
// out: a tool run, as a mid-run learned compile's (web/learn.js): no disc,
// no store and no window; /data holds only seed (path -> bytes), and done
// carries what the module wrote there as files.
//
// useStore: a test run (test mode's convert=1) that loads and stores /data
// as a normal run does, not one from an empty /data.
onmessage = async ({ data }) => {
	const { wasm, args, env = {}, test = false, useStore = false, failSaves = true, control, audio, present, net: netBuffer, out = false, seed } = data;
	let wasi = null;
	let disc = null;
	const ring = [];
	const times = { compileMs: null, runMs: null };
	let t1 = null; // when the module started
	let stored = null; // what dataLoad gave, null when /data is not stored
	// /data back into the store, before done or error goes to the page: a
	// run started after it then finds the store whole.
	const save = async (ok) => {
		if (stored === null || (!ok && !failSaves)) return;
		postMessage({ saving: true });
		await dataSave(wasi.files(wasi.data), stored).catch((e) =>
			postMessage({ log: `play: the data of this run cannot be stored (${e.name}: ${e.message})\n` }));
	};
	// The files for the page, copied out of the shim's buffers.
	const written = () => {
		if (out && wasi !== null) return [...wasi.files(wasi.data)].map(([name, bytes]) => [name, bytes.slice()]);
		if (!test || wasi === null) return undefined;
		const list = [...wasi.files()].map(([name, bytes]) => [name, bytes.slice()]);
		list.push(["ring.pcm", concat(ring)]);
		return list;
	};
	try {
		const t0 = performance.now();
		// The bytes, not a stream: netplay's build id is their hash.
		const response = await fetch(wasm);
		if (!response.ok) throw new Error(`${wasm}: ${response.status}`);
		const bytes = await response.arrayBuffer();
		const module = await WebAssembly.compile(bytes);
		// play.wasm imports its memory, shared with the band Workers.
		const limits = memoryImport(bytes);
		const memory = limits && new WebAssembly.Memory(limits);
		if (!out && env.PS_BANDS === undefined) {
			env.PS_BANDS = self.crossOriginIsolated ? String(Math.max(1, Math.min(navigator.hardwareConcurrency - 1, 8))) : "1";
		}
		if (!out && env.PS_CORES === undefined && navigator.hardwareConcurrency) {
			env.PS_CORES = String(navigator.hardwareConcurrency);
		}
		const nBands = out ? 1 : Number(env.PS_BANDS);
		const bands = memory && nBands > 1 && self.crossOriginIsolated
			? await Bands.make(module, memory, nBands, (id, data) => new Promise((resolve, reject) => {
					const w = new Worker(new URL("band-worker.js", import.meta.url), { type: "module" });
					w.onmessage = ({ data: m }) => {
						if (m.ready) resolve();
						else if (m.error !== undefined) reject(new Error(`band worker ${id}: ${m.error}`));
						else if (m.log !== undefined) postMessage({ log: m.log });
					};
					w.onerror = (e) => reject(new Error(`band worker ${id}: ${e.message}`));
					w.postMessage(data);
				}))
			: null;
		const net = netBuffer ? new NetImports(netBuffer, await buildId(bytes)) : null;
		const learn = out
			? null
			: new LearnImports((records, interp, buffer, gen, cpu) => {
					postMessage({ learn: { records, interp, buffer, gen, cpu } }, [records.buffer, interp.buffer]);
					return true;
				});
		const vu = out
			? null
			: new VuImports((exe, vu0, vu1, buffer, gen) => {
					postMessage({ vu: { exe, vu0, vu1, buffer, gen } }, [exe.buffer, vu0.buffer, vu1.buffer]);
					return true;
				});
		times.compileMs = Math.round(performance.now() - t0);
		const log = (_fd, text) => postMessage({ log: text });
		if (out) {
			disc = { disc: new Map(), close() {} };
		} else {
			disc = await discFor(data);
			postMessage({ store: disc.info });
		}
		// The run's game data each time the module writes it (core/gamedata.odin
		// renames a tmp file over gamedata.tsv, core/file.odin
		// write_file_atomic), copied to the page for its Send: /data reaches
		// the store only when the run ends.
		const renamed = out ? null : (path, bytes) => {
			if (path.split("/").at(-1) !== "gamedata.tsv") return;
			const copy = bytes.slice();
			postMessage({ gamedata: copy }, [copy.buffer]);
		};
		// Learned code, then the native blob, is compiled in the pace sleep
		// before the run first calls it (web/native.js warm); PS_WARM=0
		// turns that off.
		const native = new Native({ log: (text) => postMessage({ log: text }) });
		// The runtime's own raster procs go first: ps2/gs/warm_wasm.odin.
		let gsWarm = null;
		const idle = env.PS_WARM === "0" ? null : (deadline) => {
			gsWarm?.(deadline);
			native.warm(deadline);
		};
		wasi = new Wasi({ args: [wasm.replace(/\.wasm$/, ""), ...args], env, disc: disc.disc, log, renamed, idle });
		// /data from the store (readers.js), but in test mode, whose runs start
		// from an empty /data so they compare with native ones (unless useStore).
		if (seed) wasi.seed(seed);
		if ((!test || useStore) && !out && typeof navigator.storage?.getDirectory === "function") {
			try {
				stored = await dataLoad();
				wasi.seed(stored);
			} catch (e) {
				stored = null;
				postMessage({ log: `play: the stored data cannot be read (${e.name}: ${e.message}); this run starts without it and stores nothing\n` });
			}
		}
		const tee = test ? (samples) => ring.push(samples.slice()) : null;
		const sdl = out ? null : new Sdl({ control, audio, present, post: (m) => postMessage(m), tee });
		const instance = await WebAssembly.instantiate(module, {
			...wasi.imports,
			...(memory && { env: { memory } }),
			"system:SDL2": sdl?.imports ?? NO_SDL,
			"system:ps_native": native.imports,
			"system:ps_net": net?.imports ?? NO_NET,
			"system:ps_learn": learn?.imports ?? NO_LEARN,
			"system:ps_vu": vu?.imports ?? NO_VU,
			"system:ps_band": bands?.imports ?? NO_BAND,
		});
		sdl?.attach(instance);
		native.attach(instance);
		net?.attach(instance);
		learn?.attach(instance);
		vu?.attach(instance);
		const warmStep = instance.exports.gs_warm;
		if (warmStep !== undefined) {
			gsWarm = (deadline) => {
				while (performance.now() < deadline) {
					if (warmStep(GS_WARM_STEP) <= 0) {
						gsWarm = null;
						return;
					}
				}
			};
		}
		t1 = performance.now();
		const code = wasi.run(instance);
		times.runMs = Math.round(performance.now() - t1);
		await save(code === 0);
		const files = written();
		postMessage({ done: { code, stats: wasi.stats, ...times }, files }, buffers(files));
	} catch (e) {
		if (t1 !== null) times.runMs = Math.round(performance.now() - t1);
		await save(false);
		const files = written();
		postMessage({ error: String(e?.stack ?? e), times, files }, buffers(files));
	} finally {
		disc?.close();
	}
};

