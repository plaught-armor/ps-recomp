// sifcmd as IOP modules import it (PS_IRX=1): the command handler tables.
// A module hands sifcmd a table of its own, in IOP RAM, of {handler, harg}
// per user command; system commands (bit 31 set) have a table of their own
// here, as retail sifcmd keeps its own. Packets are not delivered to the
// handlers yet: the EE's commands are still served by sif_command.
package ps2_iop

import r3000 "ps:psx/cpu"

IOP_SYS_CMDS :: 32

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_sifcmd: struct {
	user_tab:  u32, // the module's table, IOP address
	user_size: u32, // its entries
	sys:       [IOP_SYS_CMDS]struct {
		handler, harg: u32,
	},
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
	}
	return 0, false
}
