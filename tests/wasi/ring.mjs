// The NET buffer's rings (web/net.js), through both sides' public faces:
// serveLink's deliver and link.send on one, NetImports' send and recv on
// the other. Each ring must hold exactly NET.SLOTS datagrams, drop the
// next one, an empty one and an oversized one, and give them back in order
// with their bytes, also when the running counts wrap past 2^31.
// node tests/wasi/ring.mjs; exit 1 on a failure.
import { exit } from "node:process";
import { NET } from "../../web/layout.js";
import { NetImports, serveLink } from "../../web/net.js";

let failed = 0;
function check(ok, what) {
	if (!ok) {
		failed++;
		console.error(`ring: FAIL ${what}`);
	}
}

// Datagram i: a length from 1 up to NET.DATAGRAM_MAX, bytes from i.
function datagram(i) {
	const len = i === 0 ? NET.DATAGRAM_MAX : 1 + ((i * 37) % NET.DATAGRAM_MAX);
	const d = new Uint8Array(len);
	for (let k = 0; k < len; k++) d[k] = (i * 7 + k) & 255;
	return d;
}

const same = (a, b) => a.length === b.length && a.every((x, k) => x === b[k]);

const tick = () => new Promise((resolve) => setTimeout(resolve, 1));

async function until(cond, what) {
	for (let t = 0; t < 2000 && !cond(); t++) await tick();
	check(cond(), `${what} (timed out)`);
}

// One link, with both rings' counts starting at `start`.
async function run(start) {
	const at = `start ${start}`;
	const buffer = new SharedArrayBuffer(NET.SIZE);
	const words = new Int32Array(buffer, 0, NET.HEADER / 4);
	for (const w of [NET.OUT_WRITE_WORD, NET.OUT_READ_WORD, NET.IN_WRITE_WORD, NET.IN_READ_WORD]) words[w] = start;
	const memory = new WebAssembly.Memory({ initial: 1 });
	const net = new NetImports(buffer, 1n);
	net.attach({ exports: { memory } });
	const mem = new Uint8Array(memory.buffer);

	let deliver = null;
	const sent = [];
	const { stats, done } = serveLink(buffer, async (_bind, _peer, d) => {
		deliver = d;
		return { send: (d) => sent.push(d), close() {} };
	});
	// What open does, without blocking this thread, which serves the link.
	Atomics.store(words, NET.CONFIG_LEN_WORD, 0);
	Atomics.store(words, NET.STATE_WORD, NET.ASKED);
	Atomics.notify(words, NET.STATE_WORD);
	await until(() => Atomics.load(words, NET.STATE_WORD) === NET.OPEN, `${at}: the link opens`);

	// The incoming ring: the link delivers, the module receives.
	check(net.imports.recv(0, NET.DATAGRAM_MAX) === 0, `${at}: an empty ring gives 0`);
	for (let i = 0; i < NET.SLOTS; i++) deliver(datagram(i));
	check(stats.received === NET.SLOTS && stats.dropped === 0, `${at}: SLOTS datagrams fit (${stats.received}, ${stats.dropped} dropped)`);
	deliver(datagram(NET.SLOTS));
	check(stats.received === NET.SLOTS && stats.dropped === 1, `${at}: a full ring drops the next one`);
	for (let i = 0; i < NET.SLOTS; i++) {
		const n = net.imports.recv(0, NET.DATAGRAM_MAX);
		const want = datagram(i);
		check(n === want.length && same(mem.subarray(0, n), want), `${at}: datagram ${i} comes back in order (${n} bytes)`);
	}
	check(net.imports.recv(0, NET.DATAGRAM_MAX) === 0, `${at}: drained`);
	deliver(new Uint8Array(0));
	deliver(new Uint8Array(NET.DATAGRAM_MAX + 1));
	check(stats.dropped === 3 && net.imports.recv(0, NET.DATAGRAM_MAX) === 0, `${at}: empty and oversized datagrams are dropped`);
	deliver(datagram(1));
	deliver(datagram(2));
	check(net.imports.recv(0, datagram(1).length - 1) === -1, `${at}: one over recv's cap gives -1`);
	check(net.imports.recv(0, NET.DATAGRAM_MAX) === datagram(2).length, `${at}: ... and is freed, so the next one comes`);

	// The outgoing ring: the module sends, the link takes them to the peer.
	// Nothing is taken until this thread yields, so the ring fills.
	for (let i = 0; i <= NET.SLOTS; i++) {
		mem.set(datagram(i), 0);
		net.imports.send(0, datagram(i).length);
	}
	await until(() => sent.length >= NET.SLOTS, `${at}: the link sends what was queued`);
	await tick();
	check(sent.length === NET.SLOTS && stats.sent === NET.SLOTS, `${at}: a full ring drops the next send (${sent.length} sent)`);
	for (let i = 0; i < Math.min(sent.length, NET.SLOTS); i++) {
		check(same(sent[i], datagram(i)), `${at}: sent datagram ${i} in order`);
	}

	net.imports.close();
	await done;
	check(Atomics.load(words, NET.STATE_WORD) === NET.CLOSED, `${at}: closed`);
}

// 0x7ffffff0: both counts pass 2^31 (to negative) within the run.
for (const start of [0, 0x7ffffff0]) await run(start);
console.log(failed ? `ring: ${failed} failed` : "ring: ok");
exit(failed ? 1 : 0);
