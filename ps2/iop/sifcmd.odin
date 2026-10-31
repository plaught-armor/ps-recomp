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

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_sifcmd: struct {
	user_tab:  u32, // the module's table, IOP address
	user_size: u32, // its entries
	sys:       [IOP_SYS_CMDS]struct {
		handler, harg: u32,
	},
	dma_id:    u32, // the last DMA id handed out
}

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
		pkt, psize, src := a1, max(a2 & 0xff, 16), r[7]
		dest, size := r32(r[29] + 16), r32(r[29] + 20)
		if size != 0 {copy(mem.ram_slice(dest, size), iop_ram_at(src, size))}
		w32(pkt, psize | size << 8)
		w32(pkt + 4, dest)
		w32(pkt + 8, a0)
		sif_send_raw(iop_ram_at(pkt, psize))
		return sifcmd_dma_id(), true
	}
	return 0, false
}

// Function fno of sifman, as stdio_fn. A DMA is done when it is set.
sifman_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	switch fno {
	case 7: // sceSifSetDma(SifDmaTransfer_t *, count): {src, dest, size, attr}
		for n in 0 ..< r[5] {
			e := r[4] + 16 * n
			src, dest, size := r32(e), r32(e + 4), r32(e + 8)
			if dest == sif.ee_buf {
				sif_send_raw(iop_ram_at(src, size))
			} else {
				copy(mem.ram_slice(dest, size), iop_ram_at(src, size))
			}
		}
		return sifcmd_dma_id(), true
	case 8: // sceSifDmaStat(id): done
		return ke(-1), true
	}
	return 0, false
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
