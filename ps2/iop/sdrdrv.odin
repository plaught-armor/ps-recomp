// sdrdrv as IOP modules import it (PS_IRX=1): the user command handlers a
// module registers for the EE's sdrdrv RPCs 0x9000 to 0x90f0. The RPCs
// themselves are answered by the host's sdr_server (spu.odin), which cannot
// run a guest handler: a handler is registered and never called, the EE
// gets 0 as it would with none, and each such call raises a compat row.
package ps2_iop

import "core:fmt"
import "ps:core"
import r3000 "ps:psx/cpu"

// The first user command; a command's handler slot is bits 4-7.
SDR_USER :: 0x9000
SDR_SLOTS :: 16

Iop_Sdr :: struct {
	user: [SDR_SLOTS]u32, // handler IOP addresses, by slot; 0 is none
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_sdr: Iop_Sdr

// Function fno of sdrdrv, as stdio_fn.
sdrdrv_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	switch fno {
	case 5: // sceSdrSetUserCommandFunction(command, func): the previous func
		// The low 4 bits pick nothing: 0x9001 is slot 0. 0x90f1-0x90ff are out
		// of range, as retail's (command - 0x9000) < 0xf1 check has it.
		if r[4] - SDR_USER > 0xf0 {return ke(-1), true}
		slot := &iop_sdr.user[(r[4] >> 4) & 0xf]
		old := slot^
		slot^ = r[5]
		return old, true
	}
	return 0, false
}

// The handler an EE sdrdrv RPC `fno` would run, 0 for none. Retail runs it
// for any fno whose bits 4-15 name a user command, 0x90f1-0x90ff included.
sdr_user_handler :: proc(fno: u32) -> u32 {
	if !iop_irx || (fno & 0xfff0) - SDR_USER > 0xf0 {return 0}
	return iop_sdr.user[(fno >> 4) & 0xf]
}

// An EE sdrdrv RPC `fno` whose handler is set and not run: a compat row,
// and on the first such call a line with the request's first `buf` words,
// what the handler would have read.
sdr_user_unrun :: proc(fno: u32, handler: u32, buf: []u32) {
	core.compat_unknown(.Iop_Sdr, fno, pc = handler)
	if core.compat.calls[core.Compat_Key{.Iop_Sdr, fno, 0}].n == 1 {
		fmt.eprintfln("iop: sdrdrv command %04x handler %08x not run, buf %08x", fno, handler, buf[:min(len(buf), 8)])
	}
}

// After a failed load: puts back each slot whose handler lies in `freed`,
// the memory its undo frees, as it was when the load began (`saved`).
sdr_undo :: proc(saved: Iop_Sdr, freed: []Sys_Block) {
	for &h, i in iop_sdr.user {
		if sys_in(freed, h) {h = saved.user[i]}
	}
}
