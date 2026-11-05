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

flat_print :: proc() {
	when core.FLAT {
		fmt.eprintfln("ee flat: %d returns, %d with $ra not the call's return address, %d deep at most", flat_returns, flat_mismatch, flat_max_depth)
	}
}
