// sdrdrv as IOP modules import it (PS_IRX=1): the user command handlers a
// module registers for the EE's sdrdrv RPCs 0x9000 to 0x90f0.
//
// Retail sdrdrv serves its RPC on a thread of its own, which calls a user
// handler as handler(command, buffer). Here the RPCs are answered by the
// host's sdr_server (spu.odin) until a module has set a handler; the EE's
// next sdrdrv RPC then starts the HLE's own sdrdrv thread (sdr_thread_start),
// a sifrpc server like a module's, and from there on every sdrdrv RPC runs
// on it, in the order the EE sent them: a user command calls the handler,
// any other command runs sdr_server's body. Without the thread (it could
// not start), a handler is never called: the EE gets 0 as it would with
// none, and each such call raises a compat row.
package ps2_iop

import "core:fmt"
import "ps:core"
import r3000 "ps:psx/cpu"

// The first user command; a command's handler slot is bits 4-7.
SDR_USER :: 0x9000
SDR_SLOTS :: 16

// The EE's sdrdrv RPC server.
SDR_SID :: 0x80000701
// The sdrdrv thread: retail's stack size and default priority.
SDR_STACK :: 0x800
SDR_PRIO :: 24
// Function numbers of the HLE's sdrdrv stubs past any import's 16 bits.
SDR_SERVE :: 0x10000 // the server's function
// The HLE block of the thread: its two stubs (+0 the thread's entry, which
// is sceSifRpcLoop, +4 the server's function), the queue at +0x10, the
// server's descriptor at +0x40 and its buffer, the block's last SDR_BUF
// bytes, which bound the EE's request (rpc_fits).
SDR_HEAD :: 0x200
SDR_QD :: 0x10
SDR_SD :: 0x40
SDR_BUF :: 0x100
#assert(SDR_BUF >= 64 && SDR_SD + 0x44 <= SDR_HEAD - SDR_BUF)

Iop_Sdr :: struct {
	user:   [SDR_SLOTS]u32, // handler IOP addresses, by slot; 0 is none
	thread: u32, // the sdrdrv thread's id, 0 before it starts
	failed: bool, // it could not start: the host answers on
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
	case SDR_SERVE: // the server's function on the thread: (fno, buf, size)
		return sdr_serve(r[4], r[5], r[6]), true
	}
	return 0, false
}

// The handler an EE sdrdrv RPC `fno` would run, 0 for none. Retail runs it
// for any fno whose bits 4-15 name a user command, 0x90f1-0x90ff included.
sdr_user_handler :: proc(fno: u32) -> u32 {
	if !iop_irx || (fno & 0xfff0) - SDR_USER > 0xf0 {return 0}
	return iop_sdr.user[(fno >> 4) & 0xf]
}

// On the EE's sdrdrv RPC, before it is routed: starts the sdrdrv thread
// once a handler is set, never during a load, whose undo knows nothing of
// it; the call after the load starts it then. With no memory or no room
// for the server, the host answers on, the handler not run.
sdr_thread_start :: proc() {
	d := &iop_sdr
	if d.thread != 0 || d.failed || iop_loader.loading != 0 || d.user == {} {return}
	head := sys_alloc(.High, SDR_HEAD) if rpc_host_room() else 0
	stack := sys_alloc(.High, SDR_STACK) if head != 0 else 0
	if stack == 0 {
		if head != 0 {sys_free(head)}
		d.failed = true
		fmt.eprintln("iop: no memory or no rpc room for the sdrdrv thread, its user handlers not run")
		return
	}
	qd, sd, buf := head + SDR_QD, head + SDR_SD, head + SDR_HEAD - SDR_BUF
	hle_host_stub(head, "sifcmd", 22)
	hle_host_stub(head + 4, "sdrdrv", SDR_SERVE)
	t := th_new(head, stack, SDR_STACK, 0, SDR_PRIO)
	t.ctx.r[4] = qd
	th_ready(t)
	w32(qd, t.id)
	w32(sd, SDR_SID)
	w32(sd + 4, head + 4)
	w32(sd + 8, buf)
	rpc_host_server(SDR_SID, sd, qd, t.id)
	d.thread = t.id
}

// The server's function: runs the EE's RPC `fno` from the request at `buf`,
// then puts the result in the buffer's first word, the rest of its first
// 64 bytes 0, as sdr_server does, and returns it for the EE's reply. The
// handler is the one set when the request runs: one cleared since is not
// called.
@(private = "file")
sdr_serve :: proc(fno, buf, size: u32) -> u32 {
	b := iop_ram_at(buf, SDR_BUF)
	h := sdr_user_handler(fno)
	if h == 0 {
		// The row the host path raises for a command sdr_server does not know.
		if !sdr_server(fno, b, size) {core.compat_unknown(.Sif_Rpc, SDR_SID, fno, pc = r3000.state.r[31])}
		return buf
	}
	r := &r3000.state.r
	r[4], r[5] = fno, buf
	r3000.call(h)
	res := r[2]
	for &x in b[:64] {x = 0}
	w32(buf, res)
	return buf
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
