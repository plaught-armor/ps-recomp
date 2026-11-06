// Netplay's link for play.wasm (core/net_wasi.odin): the "system:ps_net"
// imports, over the NET SharedArrayBuffer (web/layout.js), and the other end
// of that buffer, which carries the datagrams to the peer.
//
// The module's side (NetImports) runs where the module does and never
// yields: open blocks in Atomics.wait until the link is up, send and recv
// only touch the rings. The link's side (serveLink) runs on a thread that
// does yield (the page's main thread, or a Node worker_thread), takes
// datagrams out of the outgoing ring as they come, and puts the peer's into
// the incoming one. Both rings drop a datagram when full, as a socket
// would; the protocol (core/net.odin) resends.
import { NET } from "./layout.js";

const utf8 = new TextEncoder();
const text = new TextDecoder();

// One ring of the buffer: SLOTS datagrams of at most DATAGRAM_MAX bytes.
// write and read are running counts, each moved by one side only.
class Ring {
	constructor(buffer, writeWord, readWord, at) {
		this.words = new Int32Array(buffer, 0, NET.HEADER / 4);
		this.bytes = new Uint8Array(buffer, at, NET.SLOTS * NET.SLOT_SIZE);
		this.lens = new DataView(buffer, at, NET.SLOTS * NET.SLOT_SIZE);
		this.writeWord = writeWord;
		this.readWord = readWord;
	}

	// False when the ring is full or the datagram empty or too long
	// (dropped): pop's 0 means an empty ring.
	push(data) {
		const w = Atomics.load(this.words, this.writeWord);
		const r = Atomics.load(this.words, this.readWord);
		if (((w - r) | 0) >= NET.SLOTS || data.length === 0 || data.length > NET.DATAGRAM_MAX) return false;
		const at = (w & (NET.SLOTS - 1)) * NET.SLOT_SIZE;
		this.lens.setUint32(at, data.length, true);
		this.bytes.set(data, at + 4);
		Atomics.store(this.words, this.writeWord, (w + 1) | 0);
		Atomics.notify(this.words, this.writeWord);
		return true;
	}

	// The next datagram, copied by take(view) before the slot is freed; its
	// length, or 0 when the ring is empty. A slot whose length is not one
	// push writes is freed untaken: -1.
	pop(take) {
		const w = Atomics.load(this.words, this.writeWord);
		const r = Atomics.load(this.words, this.readWord);
		if (w === r) return 0;
		const at = (r & (NET.SLOTS - 1)) * NET.SLOT_SIZE;
		const len = this.lens.getUint32(at, true);
		const ok = len >= 1 && len <= NET.DATAGRAM_MAX;
		if (ok) take(this.bytes.subarray(at + 4, at + 4 + len));
		Atomics.store(this.words, this.readWord, (r + 1) | 0);
		return ok ? len : -1;
	}
}

// The module's side. buffer: the NET SharedArrayBuffer. build: a BigInt,
// the module's build id (buildId).
export class NetImports {
	constructor(buffer, build) {
		this.words = new Int32Array(buffer, 0, NET.HEADER / 4);
		this.config = new Uint8Array(buffer, NET.CONFIG, NET.CONFIG_MAX);
		this.out = new Ring(buffer, NET.OUT_WRITE_WORD, NET.OUT_READ_WORD, NET.OUT);
		this.in = new Ring(buffer, NET.IN_WRITE_WORD, NET.IN_READ_WORD, NET.IN);
		this.build = build;
		this.memory = null;
		this.imports = this.makeImports();
	}

	attach(instance) {
		this.memory = instance.exports.memory;
	}

	mem(ptr, len) {
		return new Uint8Array(this.memory.buffer, ptr, len);
	}

	makeImports() {
		return {
			// bind and peer as given (PS_NET_BIND, PS_NET_PEER); the link
			// decides what they mean. 0 once the link is up, -1 when it
			// fails or is not up within NET.OPEN_MS.
			open: (bind, bindLen, peer, peerLen) => {
				const config = utf8.encode(
					`${text.decode(this.mem(bind, bindLen))}\n${text.decode(this.mem(peer, peerLen))}`);
				if (config.length > NET.CONFIG_MAX) return -1;
				this.config.fill(0);
				this.config.set(config);
				Atomics.store(this.words, NET.CONFIG_LEN_WORD, config.length);
				Atomics.store(this.words, NET.STATE_WORD, NET.ASKED);
				Atomics.notify(this.words, NET.STATE_WORD);
				const until = performance.now() + NET.OPEN_MS;
				for (;;) {
					const s = Atomics.load(this.words, NET.STATE_WORD);
					if (s === NET.OPEN) return 0;
					if (s !== NET.ASKED) return -1;
					const left = until - performance.now();
					// Given up: FAILED, so the link does not open after all,
					// unless it just did.
					if (left <= 0) return Atomics.compareExchange(this.words, NET.STATE_WORD, NET.ASKED, NET.FAILED) === NET.OPEN ? 0 : -1;
					Atomics.wait(this.words, NET.STATE_WORD, NET.ASKED, left);
				}
			},
			close: () => {
				Atomics.store(this.words, NET.STATE_WORD, NET.CLOSED);
				Atomics.notify(this.words, NET.STATE_WORD);
				Atomics.notify(this.words, NET.OUT_WRITE_WORD); // the sender's wait
			},
			send: (ptr, len) => {
				this.out.push(this.mem(ptr, len));
			},
			// The next datagram from the peer copied to ptr: its length, 0
			// when none is waiting, -1 when it is over cap (dropped).
			recv: (ptr, cap) => {
				let over = false;
				const n = this.in.pop((d) => {
					if (d.length > cap) over = true;
					else this.mem(ptr, d.length).set(d);
				});
				return over ? -1 : n;
			},
			build: () => this.build,
		};
	}
}

// The first 8 bytes of the module's SHA-256, little-endian, as a BigInt:
// two peers check they run the same module (core/net.odin's HELLO).
export async function buildId(bytes) {
	const h = new DataView(await crypto.subtle.digest("SHA-256", bytes));
	return h.getBigUint64(0, true);
}

// Imports for a module that has none of netplay's: open always fails. A
// host that runs no netplay passes these, so the module still links.
export const NO_NET = {
	open: () => -1,
	close: () => {},
	send: () => {},
	recv: () => 0,
	build: () => 0n,
};

// The link's side: waits for the module's open, then calls
// connect(bind, peer), which resolves to {send(Uint8Array), close()} once
// the link is up and calls deliver(Uint8Array) with each datagram from the
// peer. Returns {stats, done}: done resolves when the module closes the
// link or gives up on it, and rejects when connect fails. stats counts
// datagrams sent, received, and dropped for a full ring. One link per
// buffer: a second open finds no one serving it and times out.
export function serveLink(buffer, connect) {
	const words = new Int32Array(buffer, 0, NET.HEADER / 4);
	const config = new Uint8Array(buffer, NET.CONFIG, NET.CONFIG_MAX);
	const out = new Ring(buffer, NET.OUT_WRITE_WORD, NET.OUT_READ_WORD, NET.OUT);
	const inRing = new Ring(buffer, NET.IN_WRITE_WORD, NET.IN_READ_WORD, NET.IN);
	const stats = { sent: 0, received: 0, dropped: 0 };
	const wait = async (word, value, ms) => {
		const w = Atomics.waitAsync(words, word, value, ms);
		if (w.async) await w.value;
	};
	const set = (state) => {
		Atomics.store(words, NET.STATE_WORD, state);
		Atomics.notify(words, NET.STATE_WORD);
	};
	const done = (async () => {
		let s;
		while ((s = Atomics.load(words, NET.STATE_WORD)) === NET.IDLE) await wait(NET.STATE_WORD, NET.IDLE);
		if (s !== NET.ASKED) return;
		const len = Atomics.load(words, NET.CONFIG_LEN_WORD);
		const [bind, peer] = text.decode(config.slice(0, len)).split("\n");
		let link;
		try {
			link = await connect(bind, peer, (d) => {
				if (inRing.push(d)) stats.received++;
				else stats.dropped++;
			});
		} catch (e) {
			set(NET.FAILED);
			throw e;
		}
		if (Atomics.compareExchange(words, NET.STATE_WORD, NET.ASKED, NET.OPEN) !== NET.ASKED) {
			link.close();
			return;
		}
		Atomics.notify(words, NET.STATE_WORD);
		// Send what the module queues until it closes the link.
		for (;;) {
			const w = Atomics.load(words, NET.OUT_WRITE_WORD);
			while (out.pop((d) => link.send(d.slice())) > 0) stats.sent++;
			if (Atomics.load(words, NET.STATE_WORD) !== NET.OPEN) break;
			// Woken by a push or by close; the timeout covers a close that
			// lands between the check above and the wait.
			await wait(NET.OUT_WRITE_WORD, w, 100);
		}
		link.close();
	})();
	return { stats, done };
}
