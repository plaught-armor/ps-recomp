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

Iop_Sifcmd :: struct {
	user_tab:  u32, // the module's table, IOP address
	user_size: u32, // its entries
	sys:       [IOP_SYS_CMDS]struct {
		handler, harg: u32,
	},
	dma_id:    u32, // the last DMA id handed out
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
		pkt, psize, src := a1, max(a2 & 0xff, 16), r[7]
		dest, size := r32(r[29] + 16), r32(r[29] + 20)
		if size != 0 {copy(mem.ram_slice(dest, size), iop_ram_at(src, size))}
		w32(pkt, psize | size << 8)
		w32(pkt + 4, dest)
		w32(pkt + 8, a0)
		sif_send_raw(iop_ram_at(pkt, psize))
		return sifcmd_dma_id(), true
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
		copy(iop_ram[i:][:size], mem.ram[e:][:size])
		return 0, true
	}
	return 0, false
}

// Function fno of sifman, as stdio_fn. A DMA is done when it is set.
sifman_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	switch fno {
	case 5: // sceSifInit: SIF is set up at boot, so retail finds its flag set and returns it
		return 1, true
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
	case 29: // sceSifCheckInit: the flag sceSifInit sets, set at boot
		return 1, true
	}
	return 0, false
}

// After a failed load: puts back each handler it left with its handler or
// harg in `freed`, the memory its undo frees, as it was when the load began
// (`saved`, and `tab` the words of the user table then), so no command is
// delivered there. The table too, when it was in `freed`.
sifcmd_undo :: proc(saved: Iop_Sifcmd, tab: []u32, freed: []Sys_Block) {
	s := &iop_sifcmd
	for &h, i in s.sys {
		if sys_in(freed, h.handler) || sys_in(freed, h.harg) {h = saved.sys[i]}
	}
	if sys_in(freed, s.user_tab) {s.user_tab, s.user_size = saved.user_tab, saved.user_size}
	for i in 0 ..< min(s.user_size, IOP_RAM_SIZE / 8) {
		e := s.user_tab + 8 * i
		if !sys_in(freed, r32(e)) && !sys_in(freed, r32(e + 4)) {continue}
		old: [2]u32
		if s.user_tab == saved.user_tab && 2 * i + 1 < u32(len(tab)) {old = {tab[2 * i], tab[2 * i + 1]}}
		w32(e, old[0])
		w32(e + 4, old[1])
	}
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
