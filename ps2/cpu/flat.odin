// Counts for a FLAT run (core/flat.odin), printed as the game ends.
package ps2_cpu

import "core:fmt"

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

// Why wasm32 native code (recomp/r5900/native.odin) returned to the FLAT
// runner, which does the rest: compiled code never runs events, a syscall
// or a guest call in-line, since only the runner may switch threads.
Native_Exit_Reason :: enum u32 {
	None,   // go on at pc
	Events, // run the due events, then go on at pc; back: a backward jr's second check is owed
	Call,   // a call of pc returning to arg (the runner's flat_enter)
	Return, // `jr $ra` to pc (flat_return)
	Sys,    // the SYSCALL at pc - 4 is to run, then go on at pc
	Eret,   // ERET ran: return from the exception (flat_return)
}

// Written by the code just before it returns; each reason sets the fields
// it names, the rest are stale.
Native_Exit :: struct {
	reason: Native_Exit_Reason,
	pc:     u32,
	arg:    u32,
	back:   u32,
}
native_exit: Native_Exit

flat_print :: proc() {
	when core.FLAT {
		fmt.eprintfln("ee flat: %d returns, %d with $ra not the call's return address, %d deep at most", flat_returns, flat_mismatch, flat_max_depth)
		fmt.eprintfln("ipu flat: %d re-runs, %d quadwords replayed, %d quadwords since a checkpoint at most", ipu_reruns, ipu_replayed, ipu_journal_max)
		if iop_flat_print != nil {iop_flat_print()}
	} else {
		fmt.eprintfln("ee interp: %d calls open at most", interp_max_depth)
	}
}
