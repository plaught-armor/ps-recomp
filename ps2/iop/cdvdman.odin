// cdvdman and ioman as IOP modules import them (PS_IRX=1), over the disc the
// EE's cdvdfsv and fileio read (sif.odin): the same reader, and the same fd
// table, as on retail, where the EE's file calls are served by the IOP's
// ioman. A read is done when its call returns, as cdvdfsv's is: no time
// passes, and nothing is pending for a snapshot to hold.
package ps2_iop

import "core:fmt"
import "core:strings"
import "ps:core"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

ENODEV :: 19

// The bytes of the sceCdlFILE sceCdSearchFile writes: {lsn, size, name[16],
// date[8], flag}.
CD_FILE :: 0x24

// Function fno of cdvdman, as stdio_fn.
cdvdman_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2, a3 := r[4], r[5], r[6], r[7]
	switch fno {
	case 6: // sceCdRead(lsn, sectors, buffer, sceCdRMode *{trycount, spindlctrl, datapattern})
		if a3 != 0 {
			if pattern := iop_ram_at(a3 + 2, 1)[0]; pattern != 0 { // 0x918- and 0x924-byte sectors
				core.compat_unknown(.Iop_Cd, u32(pattern), pc = r[31])
				fmt.eprintfln("iop: cdvdman read with data pattern %d", pattern)
				return 0, true
			}
		}
		if cpu.debug >= 1 {fmt.eprintfln("iop: cdvdman read lsn %x sectors %d -> %x", a0, a1, a2)}
		// A sector at a time through the stack: a module's thread streams
		// with this, and the call allocates nothing.
		sector: [DISC_SECTOR]u8
		for k in 0 ..< min(a1, IOP_RAM_SIZE / DISC_SECTOR) {
			disc_sectors(a0 + k, sector[:])
			copy(iop_ram_at(a2 + k * DISC_SECTOR, DISC_SECTOR), sector[:])
		}
		return 1, true
	case 8: // sceCdGetError: none
		return 0, true
	case 10: // sceCdSearchFile(sceCdlFILE *, name): 1 found, 0 not
		file, found := cdvd_search(cstr(a1))
		if found {copy(iop_ram_at(a0, CD_FILE), file[:])}
		return u32(found), true
	case 11: // sceCdSync(mode): the read is done
		return 0, true
	case 13: // sceCdDiskReady(mode): 2, ready
		return 2, true
	}
	return 0, false
}

// Function fno of ioman, as stdio_fn. Results as fileio_server's.
ioman_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2 := r[4], r[5], r[6]
	switch fno {
	case 4: // open(name, flags)
		name := cstr(a0)
		dev := name[:max(strings.index_byte(name, ':'), 0)]
		if dev != "cdrom" && dev != "cdrom0" {
			id: [4]u8
			copy(id[:], name)
			core.compat_unknown(.Iop_Io, transmute(u32)id, pc = r[31])
			fmt.eprintfln("iop: ioman open \"%s\" on no device here", name)
			return ke(-ENODEV), true
		}
		return u32(fileio_open(name, a1)), true
	case 5: // close(fd)
		return u32(fileio_close(a0)), true
	case 6: // read(fd, buffer, size): the count read
		f := fileio_file(a0)
		if f == nil {return ke(-EBADF), true}
		n := fileio_left(f, a2)
		sector: [DISC_SECTOR]u8 // as sceCdRead's
		done: i64
		for done < n {
			got := fileio_read(f, sector[:min(n - done, DISC_SECTOR)])
			copy(iop_ram_at(a1 + u32(done), u32(got)), sector[:got])
			done += i64(got)
			if got < DISC_SECTOR {break}
		}
		return u32(done), true
	case 8: // lseek(fd, offset, whence)
		return u32(fileio_seek(a0, i32(a1), a2)), true
	}
	return 0, false
}
