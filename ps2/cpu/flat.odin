// Counts for a FLAT run (core/flat.odin), printed as the game ends.
package ps2_cpu

import "core:fmt"

import "ps:core"

// Calls returned by `jr $ra`, and those of them whose $ra was not the
// address the call pushed: the run went on at the pushed one, as the
// coroutine model's interpreter does (ps2/kernel/flat.odin).
flat_returns, flat_mismatch: u64

flat_print :: proc() {
	when core.FLAT {
		fmt.eprintfln("ee flat: %d returns, %d with $ra not the call's return address", flat_returns, flat_mismatch)
	}
}
