// Disc readers for web/wasi.js in a Worker: {size, read(offset, length) ->
// Uint8Array}. A picked file is read through FileReaderSync on File.slice,
// so the image is never read whole; a test page's URL is read by HTTP
// Range requests; a stored disc (below) through OPFS sync access handles.

export const fileReader = (f) => {
	const fr = new FileReaderSync();
	return { size: f.size, read: (offset, length) => new Uint8Array(fr.readAsArrayBuffer(f.slice(offset, offset + length))) };
};

export const urlReader = ({ url, size }) => ({
	size,
	read(offset, length) {
		const x = new XMLHttpRequest();
		x.open("GET", url, false);
		x.responseType = "arraybuffer";
		x.setRequestHeader("Range", `bytes=${offset}-${offset + length - 1}`);
		x.send();
		if (x.status !== 206) throw new Error(`${url}: HTTP ${x.status} for a range read`);
		return new Uint8Array(x.response);
	},
});

// The disc map for Wasi from a Worker message: picked files or test URLs.
export const discOf = ({ files, urls }) =>
	new Map(files ? files.map((f) => [f.name, fileReader(f)]) : urls.map((u) => [u.name, urlReader(u)]));

// ---- discs stored in the origin private file system (OPFS) ----
//
// Each stored disc is a directory under "discs", named after the file play
// opens (the .cue, or the only file), holding its files. MARK, written last,
// says the copy is whole; a directory without it is a broken copy.

const DISCS = "discs";
const MARK = ".stored";

async function discsDir() {
	return (await navigator.storage.getDirectory()).getDirectoryHandle(DISCS, { create: true });
}

// The names of the stored discs. A broken copy is skipped, not removed: it
// may be one another tab is still writing; storing that name replaces it.
export async function storedNames() {
	const dir = await discsDir();
	const names = [];
	for await (const [name, h] of dir.entries()) {
		if (h.kind !== "directory") continue;
		try {
			await h.getFileHandle(MARK);
			names.push(name);
		} catch {
			// no MARK: broken or still being written
		}
	}
	return names.sort();
}

export async function forget(name) {
	await (await discsDir()).removeEntry(name, { recursive: true });
}

// Copies the disc's files (picked Files, or test {name, url}) into the store
// as `name`, replacing a copy there. Workers only: it writes through sync
// access handles, the one OPFS write every engine has. Throws on a full
// quota, after removing the partial copy, and when the copy there cannot be
// removed (open in another tab); its MARK goes first, so a copy left half
// removed is never listed.
export async function store(name, sources) {
	const root = await discsDir();
	const old = await root.getDirectoryHandle(name).catch(notFound);
	await old?.removeEntry(MARK).catch(notFound);
	await root.removeEntry(name, { recursive: true }).catch((e) => {
		if (e.name === "NotFoundError") return;
		throw new DOMException(`${name}: the stored copy cannot be replaced, it may be playing in another tab (${e.name}: ${e.message})`, e.name);
	});
	const dir = await root.getDirectoryHandle(name, { create: true });
	try {
		for (const src of sources) {
			const h = await (await dir.getFileHandle(src.name, { create: true })).createSyncAccessHandle();
			try {
				const body = src instanceof Blob ? src.stream() : (await fetchOk(src.url)).body;
				const reader = body.getReader();
				let at = 0;
				for (;;) {
					const { done, value } = await reader.read();
					if (done) break;
					if (h.write(value, { at }) !== value.length) throw new DOMException(`${src.name}: short write`, "QuotaExceededError");
					at += value.length;
				}
				h.truncate(at);
				h.flush();
			} finally {
				h.close();
			}
		}
		const mark = await (await dir.getFileHandle(MARK, { create: true })).createSyncAccessHandle();
		mark.close();
	} catch (e) {
		await root.removeEntry(name, { recursive: true }).catch(() => {});
		throw e;
	}
}

// For a catch: null when the entry is not there, else rethrown.
function notFound(e) {
	if (e.name === "NotFoundError") return null;
	throw e;
}

async function fetchOk(url) {
	const r = await fetch(url);
	if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
	return r;
}

// The stored disc `name` for Wasi: {disc: Map of name -> reader, close()},
// read through sync access handles (Workers only).
export async function openStored(name) {
	const dir = await (await discsDir()).getDirectoryHandle(name);
	const handles = [];
	const disc = new Map();
	try {
		for await (const [file, h] of dir.entries()) {
			if (h.kind !== "file" || file === MARK) continue;
			const sync = await h.createSyncAccessHandle();
			handles.push(sync);
			disc.set(file, {
				size: sync.getSize(),
				read(offset, length) {
					const b = new Uint8Array(length);
					const n = sync.read(b, { at: offset });
					return n === length ? b : b.subarray(0, n);
				},
			});
		}
	} catch (e) {
		for (const h of handles) h.close();
		throw e;
	}
	return { disc, close: () => handles.forEach((h) => h.close()) };
}
