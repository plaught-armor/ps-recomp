// Counts for a FLAT run (core/flat.odin), printed as the game ends.
package ps2_cpu

@(require) import "core:fmt" // used only under FLAT

import "ps:core"

// Calls returned by `jr $ra`, and those of them whose $ra was not the
// address the call pushed: the run went on at the pushed one, as the
// coroutine model's interpreter does (ps2/kernel/flat.odin).
flat_returns, flat_mismatch: u64
// The deepest shadow return stack of any run.
flat_max_depth: u32
// The IOP's counts (r3000.flat_print), set once the IOP is (iop_cpu_init).
iop_flat_print: proc()
// IPU commands re-run from a checkpoint after input ran dry, the quadwords
// they replayed, and the most quadwords pulled since any one checkpoint
// (ps2/ipu, the restartable command).
ipu_reruns, ipu_replayed: u64
ipu_journal_max: u32

flat_print :: proc() {
	when core.FLAT {
		fmt.eprintfln("ee flat: %d returns, %d with $ra not the call's return address, %d deep at most", flat_returns, flat_mismatch, flat_max_depth)
		fmt.eprintfln("ipu flat: %d re-runs, %d quadwords replayed, %d quadwords since a checkpoint at most", ipu_reruns, ipu_replayed, ipu_journal_max)
		if iop_flat_print != nil {iop_flat_print()}
	}
}
