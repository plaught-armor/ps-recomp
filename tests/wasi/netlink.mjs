// The link for play.mjs's netplay, on a worker_thread (the module blocks
// the main one): serves the NET buffer (web/net.js serveLink) with a UDP
// socket bound to PS_NET_BIND, taking datagrams only from PS_NET_PEER, as
// core/net_udp.odin does, so a wasm peer can play a native one. Both are
// IPv4 host:port; the peer's host must be an address, as the datagrams'
// source is compared with it. Posts "ready" once it serves the buffer.
import { createSocket } from "node:dgram";
import { parentPort, workerData } from "node:worker_threads";
import { serveLink } from "../../web/net.js";

function endpoint(s) {
	const at = s.lastIndexOf(":");
	const port = Number(s.slice(at + 1));
	if (at <= 0 || !Number.isInteger(port) || port <= 0 || port > 65535) throw new Error(`net: not host:port: ${s}`);
	return { host: s.slice(0, at), port };
}

const connect = (bind, peer, deliver) =>
	new Promise((resolve, reject) => {
		const b = endpoint(bind);
		const p = endpoint(peer);
		const sock = createSocket("udp4");
		sock.once("error", reject);
		sock.on("message", (m, from) => {
			if (from.address === p.host && from.port === p.port) deliver(new Uint8Array(m.buffer, m.byteOffset, m.length));
		});
		sock.bind(b.port, b.host, () => {
			sock.off("error", reject);
			sock.on("error", (e) => console.error(`net: ${e.message}`));
			resolve({ send: (d) => sock.send(d, p.port, p.host), close: () => sock.close() });
		});
	});

const { done } = serveLink(workerData.buffer, connect);
// A pending Atomics.waitAsync holds no handle, so Node would end this
// thread before the module's open; the timer keeps it until the link ends.
const alive = setInterval(() => {}, 1 << 30);
parentPort.postMessage("ready");
done.catch((e) => console.error(`net: ${e.message}`)).finally(() => clearInterval(alive));
