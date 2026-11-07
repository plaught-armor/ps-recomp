// A mid-run learned compile for play.mjs, on a worker_thread (the module
// blocks the main one): runs `play --learned psx` on another instance of
// the module, with the records and interp list play passed (web/learn.js),
// and delivers its blob, or a failure, through the LEARN buffer. The main
// thread sees none of this thread's events, so every failure is caught and
// delivered here, and the log goes straight to fd 2.
import { writeSync } from "node:fs";
import { workerData } from "node:worker_threads";
import { LEARN_ARGS, LEARN_OUT, learnDeliver, learnSeed, NO_LEARN, NO_SDL } from "../../web/learn.js";
import { Native } from "../../web/native.js";
import { NO_NET } from "../../web/net.js";
import { Wasi } from "../../web/wasi.js";

const { buffer, module, records, interp } = workerData;
const say = (text) => writeSync(2, text);
let blob = null;
try {
	const t0 = performance.now();
	const wasi = new Wasi({ args: LEARN_ARGS, env: {}, disc: new Map(), log: (_fd, text) => say(text) });
	wasi.seed(learnSeed(records, interp));
	const native = new Native({ log: say });
	const instance = await WebAssembly.instantiate(module, {
		...wasi.imports,
		"system:SDL2": NO_SDL,
		"system:ps_native": native.imports,
		"system:ps_net": NO_NET,
		"system:ps_learn": NO_LEARN,
	});
	native.attach(instance);
	const t1 = performance.now();
	const code = wasi.run(instance);
	if (code === 0) blob = wasi.files(wasi.data).get(LEARN_OUT) ?? null;
	say(`learnlink: exit ${code}, instantiate ${(t1 - t0).toFixed(1)} ms, run ${Math.round(performance.now() - t1)} ms\n`);
} catch (e) {
	say(`learnlink: ${e?.stack ?? e}\n`);
}
learnDeliver(buffer, blob, say);
