// sifcmd's RPC client as IOP modules use it (PS_IRX=1): a module binds a
// server on the EE (sceSifBindRpc) and calls it (sceSifCallRpc). The EE's
// libsif answers as it answers any peer, by its handlers for RPC_BIND and
// RPC_CALL; its RPC_END comes back through sif_command (rpc_client_end).
//
// The packets live in IOP RAM, in a pool of retail's 32, because the EE
// writes one directly: a call that asks no RPC_END (NOWAIT with no end
// function) is finished by a DMA of the EE's packet over this one, its rec_id
// and rpc_id 0, which frees the slot. So rec_id's bit 1 is what says a slot is
// in use, as in retail.
//
// The caller's send bytes go to the EE's buffer before the packet (as retail's
// DMA list has them). The EE copies the reply to recv in the same DMA list as
// RPC_END, the bytes first; so recv holds them when an end function or a
// waiter runs.
//
// A client freed with a packet out leaves the packet an orphan (client | 1): its
// slot stays reserved until the answer, which the EE still owes, and that answer
// touches no memory the packet's client had.
//
// RPC_END runs where retail's sifcmd interrupt handler runs it: the end
// function on the handler coroutine (th_intr), where it cannot wait, then the
// waiter wakes, then the packet is freed.
package ps2_iop

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import mem "../mem"
import r3000 "ps:psx/cpu"

RPC_PKTS :: 32
RPC_PKT_SIZE :: 0x40

// sceSifBindRpc's and sceSifCallRpc's mode: return once the packet is sent.
RPC_NOWAIT :: 1

// SifRpcClientData_t, as retail's sifcmd reads and writes it.
CL_PKT :: 0x00 // the packet of its last call, 0 once RPC_END freed it
CL_RPC_ID :: 0x04 // that packet's rpc_id, by address
CL_WAITER :: 0x08 // the thread waiting for RPC_END, all ones for none
CL_UNUSED :: 0x10 // cleared by a bind
CL_BUFF :: 0x14 // the EE server's buffer
CL_CBUF :: 0x18 // the EE server's client buffer
CL_END :: 0x1c // the end function
CL_END_PARAM :: 0x20 // its argument
CL_SERVER :: 0x24 // the EE server's descriptor, 0 until a bind found one

// The packet, past its 16-byte header.
PK_REC_ID :: 0x10 // slot << 16 | 6; bit 1 the slot is in use
PK_ADDR :: 0x14 // the packet's own address
PK_RPC_ID :: 0x18
PK_CLIENT :: 0x1c
PK_ARG :: 0x20 // bind: the server id; call: the function number
PK_SSIZE :: 0x24
PK_RECV :: 0x28
PK_RSIZE :: 0x2c
PK_RMODE :: 0x30 // whether the EE sends RPC_END
PK_SERVER :: 0x34

PK_IN_USE :: 2

// In RPC_END, as the EE sends it.
END_CLIENT :: 0x1c
END_CID :: 0x20
END_SERVER :: 0x24
END_BUFF :: 0x28
END_CBUF :: 0x2c

// Function number of a compat row for a bind no EE server answered.
RPC_NO_SERVER :: 0xfffffffe
// Function number of a compat row for a waited call with no thread to wait.
RPC_NO_THREAD :: 0xfffffffd

// sceSifBindRpc(client, sid, mode). A sid with no server is no error here: the
// EE answers RPC_END with server 0 and the call returns 0, as retail; a module
// that polls for the server then polls on, and the row says why.
rpc_client_bind :: proc(client, sid, mode: u32) -> u32 {
	if !rpc_client_ok(client) {
		rpc_client_refused(client, sid)
		return ke(-2)
	}
	pkt := rpc_pkt_new(client)
	if pkt == 0 {return ke(-1)}
	w32(client + CL_UNUSED, 0)
	w32(client + CL_SERVER, 0)
	w32(pkt + PK_ARG, sid)
	w32(pkt + PK_RMODE, 1)
	if cpu.debug >= 1 {fmt.eprintfln("iop: rpc bind to EE server %08x, client %x", sid, client)}
	rpc_client_send(client, SIF_CMD_RPC_BIND, pkt, 0, 0, 0, mode)
	return 0
}

// sceSifCallRpc(client, fno, mode, send, ssize, recv, rsize, end, param). A
// client with no server, or bytes that lie outside the two RAMs, are refused
// as retail refuses a packet it could not send, with a row: retail would
// send them, and the EE would write through a null descriptor.
rpc_client_call :: proc(client, fno, mode, send: u32) -> u32 {
	sp := r3000.state.r[29]
	ssize, recv, rsize, end, param := r32(sp + 16), r32(sp + 20), r32(sp + 24), r32(sp + 28), r32(sp + 32)
	if !rpc_client_ok(client) || r32(client + CL_SERVER) == 0 || !rpc_iop_fits(send, ssize) || !rpc_iop_fits(recv, rsize) || (end != 0 && !rpc_iop_fits(end, 4)) {
		rpc_client_refused(client, fno)
		return ke(-2)
	}
	buff := r32(client + CL_BUFF)
	if ssize != 0 && !rpc_ee_fits(buff, ssize) {
		rpc_client_refused(client, fno)
		return ke(-2)
	}
	pkt := rpc_pkt_new(client)
	if pkt == 0 {return ke(-1)}
	w32(client + CL_END, end)
	w32(client + CL_END_PARAM, param)
	w32(pkt + PK_ARG, fno)
	w32(pkt + PK_SSIZE, ssize)
	w32(pkt + PK_RECV, recv)
	w32(pkt + PK_RSIZE, rsize)
	w32(pkt + PK_SERVER, r32(client + CL_SERVER))
	// With no end function a NOWAIT call asks no RPC_END: the EE's DMA frees the
	// packet, and a status check is all that can see it end.
	w32(pkt + PK_RMODE, 1 if mode & RPC_NOWAIT == 0 || end != 0 else 0)
	if cpu.debug >= 1 {fmt.eprintfln("iop: rpc call to EE, client %x fno %#x send %d recv %d", client, fno, ssize, rsize)}
	rpc_client_send(client, SIF_CMD_RPC_CALL, pkt, send, buff, ssize, mode)
	return 0
}

// Sends the packet, and without NOWAIT waits for its RPC_END on the running
// thread. Not on a thread (the loader) nothing can wait, with a row; a handler
// is stopped there, as any handler that waits.
@(private = "file")
rpc_client_send :: proc(client, cid, pkt, src, dest, size, mode: u32) {
	wait := mode & RPC_NOWAIT == 0
	on_thread := th_find(iop_sched.cur) != nil
	if wait && !on_thread && !iop_sched.intr {core.compat_unknown(.Iop_Rpc, client, sub = RPC_NO_THREAD)}
	w32(client + CL_WAITER, iop_sched.cur if wait && on_thread else ~u32(0))
	sifcmd_send(cid, pkt, RPC_PKT_SIZE, src, dest, size)
	if wait {th_rpc_wait()}
}

// sif_command's RPC_END, the packet at `a`, with no module's handler for it.
// An END for a client with no packet out is dropped with a row: the EE's word,
// trusted no further than the packets this side sent. Each END frees one of
// the client's packets; retail frees the last sent, and loses the rest. An
// orphan goes first: it is the older, and the EE answers in order.
rpc_client_end :: proc(a: u32) {
	client, cid := iop_u32(a + END_CLIENT)^, iop_u32(a + END_CID)^
	iop_sync(cpu.state.cycles)
	if orphan := rpc_pkt_of(client | 1); orphan != 0 {
		rpc_pkt_free(orphan)
		core.compat_unknown(.Iop_Rpc, client, sub = cid)
		fmt.eprintfln("iop: RPC_END of %08x for client %x, which was freed", cid, client)
		return
	}
	pkt := rpc_pkt_of(client)
	if pkt == 0 {
		core.compat_unknown(.Iop_Rpc, client, sub = cid)
		fmt.eprintfln("iop: RPC_END of %08x for client %x, which has no packet out", cid, client)
		return
	}
	switch cid {
	case SIF_CMD_RPC_CALL:
		if end := r32(client + CL_END); end != 0 {
			if cpu.debug >= 1 {fmt.eprintfln("iop: rpc END client %x fno %#x, end function %x", client, r32(pkt + PK_ARG), end)}
			switch th_intr(end, r32(client + CL_END_PARAM), 0) {
			case .None:
			case .Blocked, .Call:
				core.compat_unknown(.Iop_Intr, cid, pc = end)
				fmt.eprintfln("iop: rpc end function at %x stopped", end)
			}
		} else if cpu.debug >= 1 {
			fmt.eprintfln("iop: rpc END client %x fno %#x", client, r32(pkt + PK_ARG))
		}
	case SIF_CMD_RPC_BIND:
		server := iop_u32(a + END_SERVER)^
		w32(client + CL_SERVER, server)
		w32(client + CL_BUFF, iop_u32(a + END_BUFF)^)
		w32(client + CL_CBUF, iop_u32(a + END_CBUF)^)
		sid := r32(pkt + PK_ARG)
		if cpu.debug >= 1 {fmt.eprintfln("iop: rpc bind to EE server %08x answered, server %x", sid, server)}
		if server == 0 {core.compat_unknown(.Iop_Rpc, sid, sub = RPC_NO_SERVER)}
	}
	if w := r32(client + CL_WAITER); w != ~u32(0) {th_rpc_wake(w)}
	rpc_pkt_free(pkt)
	// What the client's last field says of its packets: the one left, if any.
	left := rpc_pkt_of(client)
	w32(client + CL_PKT, left)
	if left != 0 {w32(client + CL_RPC_ID, left + PK_RPC_ID)}
	iop_sched.start_done = false
	th_schedule(r3000.state.cycles + IOP_SLICE)
	iop_wake_set()
}

// `freed` is about to be memory no module owns. Each packet out for a client
// there is orphaned and its waiter woken, so its RPC_END reaches none of that;
// a client that lives on, with its end function there, ends with none. The pool
// itself is never in `freed`: the EE holds its addresses (undo_restore).
rpc_client_freed :: proc(freed: []Sys_Block) {
	s := &iop_sifcmd
	if s.rpc_pool == 0 {return}
	woke := false
	for i in u32(0) ..< RPC_PKTS {
		pkt := s.rpc_pool + i * RPC_PKT_SIZE
		client := r32(pkt + PK_CLIENT)
		if r32(pkt + PK_REC_ID) & PK_IN_USE == 0 || client & 1 != 0 {continue}
		if sys_in(freed, client) {
			if w := r32(client + CL_WAITER); w != ~u32(0) {
				th_rpc_wake(w)
				woke = true
			}
			w32(pkt + PK_CLIENT, client | 1)
		} else if sys_in(freed, r32(client + CL_END)) {
			w32(client + CL_END, 0)
		}
	}
	// Not th_schedule: this may be on a thread, and the next slice runs what woke.
	if woke {iop_wake_set()}
}

@(private = "file")
rpc_pkt_free :: proc(pkt: u32) {
	w32(pkt + PK_REC_ID, r32(pkt + PK_REC_ID) &~ PK_IN_USE)
	w32(pkt + PK_RPC_ID, 0)
}

// A free packet made ready for `client`, recorded there; 0 with none, which
// bind and call return as -1.
@(private = "file")
rpc_pkt_new :: proc(client: u32) -> u32 {
	s := &iop_sifcmd
	if s.rpc_pool == 0 {
		s.rpc_pool = sys_alloc(.High, RPC_PKTS * RPC_PKT_SIZE)
		if s.rpc_pool == 0 {
			fmt.eprintln("iop: no memory for the rpc client's packets")
			return 0
		}
		for b in 0 ..< u32(RPC_PKTS * RPC_PKT_SIZE) / 4 {w32(s.rpc_pool + 4 * b, 0)}
	}
	for i in u32(0) ..< RPC_PKTS {
		pkt := s.rpc_pool + i * RPC_PKT_SIZE
		if r32(pkt + PK_REC_ID) & PK_IN_USE != 0 {continue}
		s.rpc_id += 1
		if s.rpc_id == 0 {s.rpc_id = 1}
		w32(pkt + PK_REC_ID, i << 16 | 6)
		w32(pkt + PK_ADDR, pkt)
		w32(pkt + PK_RPC_ID, s.rpc_id)
		w32(pkt + PK_CLIENT, client)
		w32(client + CL_PKT, pkt)
		w32(client + CL_RPC_ID, pkt + PK_RPC_ID)
		return pkt
	}
	return 0
}

// The first packet out for `client` that its RPC_END will answer, 0 if none. A
// NOWAIT call's packet with no end function has no RPC_END to be taken by.
@(private = "file")
rpc_pkt_of :: proc(client: u32) -> u32 {
	s := &iop_sifcmd
	if s.rpc_pool == 0 || client == 0 {return 0}
	for i in u32(0) ..< RPC_PKTS {
		pkt := s.rpc_pool + i * RPC_PKT_SIZE
		if r32(pkt + PK_REC_ID) & PK_IN_USE != 0 && r32(pkt + PK_CLIENT) == client && r32(pkt + PK_RMODE) != 0 {return pkt}
	}
	return 0
}

// A client struct: IOP RAM, word aligned, room for its last field.
@(private = "file")
rpc_client_ok :: proc(client: u32) -> bool {
	return client & 3 == 0 && rpc_iop_fits(client, CL_SERVER + 4) && client & 0x1fffffff != 0
}

@(private = "file")
rpc_iop_fits :: proc(a, n: u32) -> bool {
	if n == 0 {return true}
	p := a & 0x1fffffff
	return p < IOP_RAM_SIZE && n <= IOP_RAM_SIZE - p
}

@(private = "file")
rpc_ee_fits :: proc(a, n: u32) -> bool {
	p := a & 0x0fffffff
	return a >> 28 != 7 && p < mem.RAM_SIZE && n <= mem.RAM_SIZE - p
}

@(private = "file")
rpc_client_refused :: proc(client, what: u32) {
	core.compat_unknown(.Iop_Rpc, client, sub = what)
	fmt.eprintfln("iop: rpc from client %x refused (%x)", client, what)
}
