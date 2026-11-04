// sifcmd and sifman as IOP modules import them (PS_IRX=1). A module hands
// sifcmd a table of its own, in IOP RAM, of {handler, harg} per user
// command; system commands (bit 31 set) have a table of their own here, as
// retail sifcmd keeps its own. A packet the EE sends to a command with a
// handler, and that sif_command does not serve itself, is delivered to it
// (iop_cmd_deliver). What a module sends the EE, by sceSifSendCmd or by a
// DMA to the EE's command buffer, is queued like sif_command's replies.
package ps2_iop

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import mem "../mem"
import r3000 "ps:psx/cpu"

IOP_SYS_CMDS :: 32

// The completion callbacks sceSifSetDmaIntr may owe at once, as retail's
// per-buffer list holds.
SIF_DMA_CBS :: 32

Iop_Sifcmd :: struct {
	user_tab:  u32, // the module's table, IOP address
	user_size: u32, // its entries
	sys:       [IOP_SYS_CMDS]struct {
		handler, harg: u32,
	},
	dma_id:    u32, // the last DMA id handed out
	rpc_pool:  u32, // the RPC client's packets, IOP address (sifclient.odin)
	rpc_id:    u32, // the last rpc_id handed out
	dma_cb:    [SIF_DMA_CBS]Sif_Dma_Cb, // the completion callbacks owed, first owed first
	n_dma_cb:  u32,
}

// A completion callback owed: func(arg) once its transfer is done, at EE
// cycle `due`.
Sif_Dma_Cb :: struct {
	func, arg: u32,
	due:       u64,
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_sifcmd: Iop_Sifcmd

// Function fno of sifcmd, as stdio_fn.
sifcmd_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2 := r[4], r[5], r[6]
	s := &iop_sifcmd
	switch fno {
	case 4: // sceSifInitCmd: the link is up from the start
		return 0, true
	case 8: // sceSifSetCmdBuffer(db, size): the previous table
		old := s.user_tab
		s.user_tab, s.user_size = a0, a1
		return old, true
	case 10: // sceSifAddCmdHandler(cid, handler, harg)
		i := a0 & 0x7fffffff
		if a0 & 0x80000000 != 0 {
			if i >= IOP_SYS_CMDS {return ke(KE_ERROR), true}
			s.sys[i] = {a1, a2}
		} else {
			if i >= s.user_size {return ke(KE_ERROR), true}
			w32(s.user_tab + 8 * i, a1)
			w32(s.user_tab + 8 * i + 4, a2)
		}
		return 0, true
	case 12, 13: // sceSifSendCmd, isceSifSendCmd(cid, packet, psize, src, dest, size)
		return sifcmd_send(a0, a1, max(a2 & 0xff, 16), r[7], r32(r[29] + 16), r32(r[29] + 20)), true
	case 15: // sceSifBindRpc(client, sid, mode)
		return rpc_client_bind(a0, a1, a2), true
	case 16: // sceSifCallRpc(client, fno, mode, send, ...)
		return rpc_client_call(a0, a1, a2, r[7]), true
	case 14, 17, 19, 22, 24, 25:
		return sifrpc_fn(fno)
	case 23: // sceSifGetOtherData(rd, src, dest, size, mode): done at once
		src, dest, size := a1, a2, r[7]
		// EE RAM by its low 28 bits, as the EE's DMA addresses it; bit 28 names
		// registers or scratchpad, never RAM. IOP RAM by its physical address.
		e, i := src & 0x0fffffff, dest & 0x1fffffff
		if src & 0x10000000 != 0 || e >= mem.RAM_SIZE || size > mem.RAM_SIZE - e || i >= IOP_RAM_SIZE || size > IOP_RAM_SIZE - i {
			core.compat_unknown(.Iop_Other_Data, src, sub = size, pc = r[31])
			fmt.eprintfln("iop: GetOtherData of %x bytes from EE %08x to IOP %08x out of range", size, src, dest)
			return 0, true
		}
		copy(iop_mem(i, size), mem.ram[e:][:size])
		return 0, true
	}
	return 0, false
}

// Function fno of sifman, as stdio_fn. A DMA is done when it is set; a
// completion callback runs at the next tick (sif_dma_intr_run).
sifman_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	switch fno {
	case 5: // sceSifInit: SIF is set up at boot, so retail finds its flag set and returns it
		return 1, true
	case 7: // sceSifSetDma(SifDmaTransfer_t *, count): {src, dest, size, attr}
		id, _, _ := sifman_dma(r[4], r[5])
		return id, true
	case 8: // sceSifDmaStat(id): done
		return ke(-1), true
	case 29: // sceSifCheckInit: the flag sceSifInit sets, set at boot
		return 1, true
	case 32: // sceSifSetDmaIntr(SifDmaTransfer_t *, count, cb, arg): SetDma, then cb(arg) when done
		// Retail returns 0, nothing sent, when the transfer's tags do not
		// fit its 32-tag buffer. Ours are copied at once, so tags never
		// pile up; the callbacks owed stand in for that test.
		s := &iop_sifcmd
		if r[6] != 0 && s.n_dma_cb == SIF_DMA_CBS {return 0, true}
		cb, arg := r[6], r[7]
		id, bytes, pkt_due := sifman_dma(r[4], r[5])
		if cb != 0 {
			// Done once its bytes have crossed, as sif_set_dma times the
			// other direction, after the transfers owed before it (SIF0
			// runs one at a time), and at least an IOP cycle on so a
			// callback that sets another cannot run it in the same tick;
			// never before a packet it sent the EE is due there.
			start := max(cpu.state.cycles, r3000.state.cycles * IOP_EE_RATIO)
			if s.n_dma_cb > 0 {start = max(start, s.dma_cb[s.n_dma_cb - 1].due)}
			due := max(start + max(bytes * SIF_DMA_CYCLES_PER_BYTE, IOP_EE_RATIO), pkt_due)
			s.dma_cb[s.n_dma_cb] = {cb, arg, due}
			s.n_dma_cb += 1
			iop_wake_set()
		}
		return id, true
	}
	return 0, false
}

// Copies each of the `count` transfers listed at `list`, {src, dest, size,
// attr}, from IOP RAM to the EE; to the EE's command buffer it is sent as a
// command. The DMA's id, the bytes it moved and the due of the last packet
// it queued for the EE (0 when none).
@(private = "file")
sifman_dma :: proc(list, count: u32) -> (id: u32, bytes: u64, pkt_due: u64) {
	for n in 0 ..< count {
		e := list + 16 * n
		src, dest, size := r32(e), r32(e + 4), r32(e + 8)
		if dest == sif.ee_buf {
			sif_send_raw(iop_ram_at(src, size))
			pkt_due = sif.replies[len(sif.replies) - 1].due
		} else {
			copy(mem.ram_slice(dest, size), iop_ram_at(src, size))
		}
		bytes += u64(size)
	}
	return sifcmd_dma_id(), bytes, pkt_due
}

// When, in EE cycles, the first completion callback owed is due; max(u64)
// when none is.
sif_dma_next_ee :: proc() -> u64 {
	t := max(u64)
	for c in iop_sifcmd.dma_cb[:iop_sifcmd.n_dma_cb] {t = min(t, c.due)}
	return t
}

// Runs the completion callbacks due by EE cycle `now`, first owed first,
// each with a0 its arg, as retail's SIF0 DMA interrupt does; one that waits
// is stopped there with a compat row, and the rest still run. Those not yet
// due, and those the callbacks set, stay owed.
sif_dma_intr_run :: proc(now: u64) {
	s := &iop_sifcmd
	run: [SIF_DMA_CBS]Sif_Dma_Cb
	n_run, n: u32
	for c in s.dma_cb[:s.n_dma_cb] {
		if c.due <= now {
			run[n_run] = c
			n_run += 1
		} else {
			s.dma_cb[n] = c
			n += 1
		}
	}
	if n_run == 0 {return}
	for &c in s.dma_cb[n:s.n_dma_cb] {c = {}}
	s.n_dma_cb = n
	for c in run[:n_run] {
		switch th_intr(c.func, c.arg, 0) {
		case .None:
		case .Blocked:
			core.compat_unknown(.Iop_Sif_Intr, c.func, pc = c.func)
			fmt.eprintfln("iop: sifman DMA callback at %x blocked", c.func)
		case .Call:
			fmt.eprintfln("iop: sifman DMA callback at %x stopped", c.func)
		}
	}
}

// After a failed load: puts back each handler it left with its handler or
// harg in `freed`, the memory its undo frees, as it was when the load began
// (`saved`, and `tab` the words of the user table then), so no command is
// delivered there. The table too, when it was in `freed`. A callback owed
// is dropped when its func or its arg is in `freed`: the arg is a scalar to
// us, so one that only falls in freed memory goes too, as a harg does.
sifcmd_undo :: proc(saved: Iop_Sifcmd, tab: []u32, freed: []Sys_Block) {
	s := &iop_sifcmd
	for &h, i in s.sys {
		if sys_in(freed, h.handler) || sys_in(freed, h.harg) {h = saved.sys[i]}
	}
	if sys_in(freed, s.user_tab) {s.user_tab, s.user_size = saved.user_tab, saved.user_size}
	n: u32
	for c in s.dma_cb[:s.n_dma_cb] {
		if sys_in(freed, c.func) || sys_in(freed, c.arg) {continue}
		s.dma_cb[n] = c
		n += 1
	}
	for &c in s.dma_cb[n:s.n_dma_cb] {c = {}}
	s.n_dma_cb = n
	for i in 0 ..< min(s.user_size, IOP_RAM_SIZE / 8) {
		e := s.user_tab + 8 * i
		if !sys_in(freed, r32(e)) && !sys_in(freed, r32(e + 4)) {continue}
		old: [2]u32
		if s.user_tab == saved.user_tab && 2 * i + 1 < u32(len(tab)) {old = {tab[2 * i], tab[2 * i + 1]}}
		w32(e, old[0])
		w32(e + 4, old[1])
	}
	rpc_client_freed(freed)
}

// Sends the EE command cid, packet at `pkt`, and `size` bytes from src to dest
// ahead of it, as retail's DMA list has them. The DMA's id.
@(private)
sifcmd_send :: proc(cid, pkt, psize, src, dest, size: u32) -> u32 {
	if size != 0 {copy(mem.ram_slice(dest, size), iop_ram_at(src, size))}
	w32(pkt, psize | size << 8)
	w32(pkt + 4, dest)
	w32(pkt + 8, cid)
	sif_send_raw(iop_ram_at(pkt, psize))
	return sifcmd_dma_id()
}

// A DMA id, never 0, which a failed transfer returns.
@(private = "file")
sifcmd_dma_id :: proc() -> u32 {
	s := &iop_sifcmd
	s.dma_id = s.dma_id % 0xffff + 1
	return s.dma_id
}

// `n` bytes of IOP RAM from `a`, wrapped to RAM as IOP code addresses it,
// fewer where RAM ends.
@(private)
iop_ram_at :: proc(a, n: u32) -> []u8 {
	return iop_mem(a & (IOP_RAM_SIZE - 1), n)
}

// Delivers the packet at IOP_CMDBUF, command `cid`, to the handler a module
// gave it, if any, then runs the threads it readied for a slice. A handler
// that waits is stopped there with a compat row.
iop_cmd_deliver :: proc(cid: u32) -> bool {
	s := &iop_sifcmd
	i := cid & 0x7fffffff
	h, harg: u32
	if cid & 0x80000000 != 0 {
		if i >= IOP_SYS_CMDS {return false}
		h, harg = s.sys[i].handler, s.sys[i].harg
	} else {
		if i >= s.user_size {return false}
		h, harg = r32(s.user_tab + 8 * i), r32(s.user_tab + 8 * i + 4)
	}
	if h == 0 {return false}
	iop_sync(cpu.state.cycles)
	switch th_intr(h, IOP_CMDBUF, harg) {
	case .None:
	case .Blocked:
		core.compat_unknown(.Iop_Intr, cid, pc = h)
		fmt.eprintfln("iop: command %x handler at %x blocked", cid, h)
	case .Call:
		fmt.eprintfln("iop: command %x handler at %x stopped", cid, h)
	}
	iop_sched.start_done = false
	th_schedule(r3000.state.cycles + IOP_SLICE)
	iop_wake_set()
	return true
}
