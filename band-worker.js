// A band Worker of the play Worker's pool (web/band.js): its first message
// is the pool's data; it answers {ready} once it has instantiated the
// module, then {log} for what band_entry writes to fd 2. Past ready it
// never yields: it waits on its ctl word for a spawn.
import { bandWorker } from "./band.js";

onmessage = ({ data }) => {
	onmessage = null;
	bandWorker(data, () => postMessage({ ready: true }), (text) => postMessage({ log: text })).catch((e) =>
		postMessage({ error: String(e?.stack ?? e) }));
};
