// cdvdman and ioman as IOP modules import them (PS_IRX=1), over the disc the
// EE's cdvdfsv and fileio read (sif.odin): the same reader, and the same fd
// table, as on retail, where the EE's file calls are served by the IOP's
// ioman. A command is done when its call returns, as cdvdfsv's read is: no
// time passes. The callback sceCdCallback sets, which retail's drive
// interrupt runs when a command completes, runs at the next iop_tick after
// the command (cd_intr_run), on the handler coroutine (th_intr), with the
// function code retail gives it. Retail refuses a command while one is busy;
// none is busy here, so each command accepted gets its own callback run, in
// the order the commands were made: those runs not yet made are the state a
// snapshot holds.
package ps2_iop

import "core:fmt"
import "core:strings"
import "ps:core"
import "ps:core/disc"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

ENODEV :: 19

// The bytes of the sceCdlFILE sceCdSearchFile writes: {lsn, size, name[16],
// date[8], flag}.
CD_FILE :: 0x24

// The function codes a command's callback gets, retail's for sceCdRead,
// sceCdStandby, sceCdStop and sceCdPause.
CD_FUNC_READ :: 1
CD_FUNC_STANDBY :: 5
CD_FUNC_STOP :: 6
CD_FUNC_PAUSE :: 7

// The disk types cdvdman's sceCdGetDiskType and cdvdfsv's GetDiskType
// answer (cd_disk_type): a PS2 CD, one with audio tracks, and a PS2 DVD.
CD_DISK_PS2_CD :: 0x12
CD_DISK_PS2_CDDA :: 0x13
CD_DISK_PS2_DVD :: 0x14

// The drive statuses cdvdman's sceCdStatus and cdvdfsv's S-command Status
// answer (cd_status): stopped, the disc not spinning, after sceCdStop, and
// paused, spun up with no command running, else. Commands finish in their
// call here, so the drive is never seen reading or seeking, and the tray is
// never open.
CD_STAT_STOP :: 0x00
CD_STAT_PAUSE :: 0x0a

// The 8 bytes sceCdReadClock and cdvdfsv's S-command ReadClock write, the
// drive's clock {stat, second, minute, hour, pad, day, month, year} in BCD:
// all 0, a clock with no time, the same on every run so replays and netplay
// peers agree.
CD_CLOCK :: 8

// The most callback runs one tick can owe: commands made faster than ticks
// run their callbacks.
CD_PENDING :: 4

Iop_Cd :: struct {
	callback:  u32, // IOP address; 0 is none
	n_pending: u32,
	pending:   [CD_PENDING]u32, // the function codes of the completed commands' callbacks not yet run, first made first
	stopped:   bool, // sceCdStop stopped the disc, and no command has spun it up since
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_cd: Iop_Cd

// Function fno of cdvdman, as stdio_fn.
cdvdman_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2, a3 := r[4], r[5], r[6], r[7]
	switch fno {
	case 4: // sceCdInit(mode): 1 for every mode. 0 waits for the drive, always ready here; 5 shuts down, nothing held
		return 1, true
	case 5: // sceCdStandby: spins the disc up, done here; 1, the command accepted
		cd_spin()
		cd_done(CD_FUNC_STANDBY)
		return 1, true
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
		cd_done(CD_FUNC_READ)
		return 1, true
	case 8: // sceCdGetError: none
		return 0, true
	case 10: // sceCdSearchFile(sceCdlFILE *, name): sceCdLayerSearchFile on layer 0
		return cd_search(a0, a1, 0), true
	case 11: // sceCdSync(mode): the read is done
		return 0, true
	case 12: // sceCdGetDiskType
		return cd_disk_type(), true
	case 13: // sceCdDiskReady(mode): 2, ready
		return 2, true
	case 15: // sceCdStop: stops the disc, done here; 1, the command accepted
		iop_cd.stopped = true
		cd_done(CD_FUNC_STOP)
		return 1, true
	case 24: // sceCdReadClock(sceCdCLOCK *): 1, the clock read
		for &b in iop_ram_at(a0, CD_CLOCK) {b = 0}
		return 1, true
	case 28: // sceCdStatus
		return cd_status(), true
	case 38: // sceCdPause: spins the disc up and holds it there, done here; 1, the command accepted
		cd_spin()
		cd_done(CD_FUNC_PAUSE)
		return 1, true
	case 39: // sceCdBreak: 1, retail's whether or not a command is busy. No command runs here for it to break, so no callback comes of it
		return 1, true
	case 37: // sceCdCallback(func): the previous func. Retail returns 0 and sets nothing while a command is busy; none is here
		old := iop_cd.callback
		iop_cd.callback = a0
		return old, true
	case 44: // sceCdGetReadPos: the bytes the read in flight has put in its buffer, 0 with none. Reads are done in their call here, so 0
		return 0, true
	case 75: // sceCdMmode(media): 1. The media only gates disk type checks, none made here
		return 1, true
	case 83: // sceCdReadDvdDualInfo(int *on_dual, u32 *layer1_start): 1
		on_dual, layer1 := cd_dual_info()
		iop_u32(a0)^, iop_u32(a1)^ = on_dual, layer1
		return 1, true
	case 84: // sceCdLayerSearchFile(sceCdlFILE *, name, layer): 1 found, 0 not
		return cd_search(a0, a1, a2), true
	}
	return 0, false
}

// sceCdLayerSearchFile: writes the record of file `name` (an IOP address) in
// `layer`'s volume at `fp` and returns 1, or returns 0 and writes nothing.
// Any nonzero layer is the second, as for cdvdfsv's SearchFile.
@(private = "file")
cd_search :: proc(fp, name, layer: u32) -> u32 {
	file, found := cdvd_search(cstr(name), u8(layer != 0))
	if found {copy(iop_ram_at(fp, CD_FILE), file[:])}
	return u32(found)
}

// The disk type, by the image's medium (disc.dvd_probe); a PS2 DVD over
// disc_dir, which has no image to judge, as every disc there so far is one.
cd_disk_type :: proc() -> u32 {
	if image.volume == 0 || image.dvd {return CD_DISK_PS2_DVD}
	for t in image.tracks {
		if t.audio {return CD_DISK_PS2_CDDA}
	}
	return CD_DISK_PS2_CD
}

// sceCdReadDvdDualInfo's {on_dual, layer1_start}, as cdvdman takes them
// from the DVD's TOC (cdvdman.c sceCdReadDvdDualInfo): on_dual is 1 for a
// dual-layer disc (parallel or opposite track alike) and layer1_start the
// LSN the second layer's volume starts at. A single-layer disc's TOC holds
// its data area's end there, so it answers on_dual 0 and its sector count;
// over disc_dir there is no sector count: 0. A CD has no TOC of this kind:
// cdvdman zeroes both when !cdvdman_isdvd().
cd_dual_info :: proc() -> (on_dual, layer1: u32) {
	if cd_disk_type() != CD_DISK_PS2_DVD {return 0, 0}
	if image.layer1 != 0 {return 1, image.layer1}
	return 0, disc.end(&image)
}

// Owes the callback a run with function code `code` for a command just
// completed, when one is set; with CD_PENDING owed already, the run is
// dropped with a compat row.
@(private = "file")
cd_done :: proc(code: u32) {
	cb := iop_cd.callback
	if cb == 0 {return}
	if iop_cd.n_pending == CD_PENDING {
		core.compat_unknown(.Iop_Cd_Intr, cb, sub = code, pc = r3000.state.r[31])
		fmt.eprintfln("iop: cdvdman callback at %x: %d runs owed, code %d dropped", cb, CD_PENDING, code)
		return
	}
	iop_cd.pending[iop_cd.n_pending] = code
	iop_cd.n_pending += 1
	iop_wake_set()
}

// The disc spins up, as every read and seek of it does, whoever makes it
// (disc_sectors, disc_file_read, cdvdfsv's Seek), and sceCdStandby and
// sceCdPause: a sceCdStop is over (cd_status).
cd_spin :: proc() {
	iop_cd.stopped = false
}

// The drive's status, as CD_STAT_STOP and CD_STAT_PAUSE say.
cd_status :: proc() -> u32 {
	return CD_STAT_STOP if iop_cd.stopped else CD_STAT_PAUSE
}

// When, in EE cycles, the callback runs owed are due: at once (the IOP's
// clock) while one is; max(u64) when none is.
cd_next_ee :: proc() -> u64 {
	return max(u64) if iop_cd.n_pending == 0 else r3000.state.cycles * IOP_EE_RATIO
}

// Makes the callback runs owed, first owed first, each with the callback set
// when it runs, as retail's interrupt reads it at each completion; one that
// waits is stopped there with a compat row, and the rest still run.
cd_intr_run :: proc() {
	n := iop_cd.n_pending
	if n == 0 {return}
	codes := iop_cd.pending
	iop_cd.n_pending, iop_cd.pending = 0, {}
	for code in codes[:n] {
		cb := iop_cd.callback
		if cb == 0 {continue}
		switch th_intr(cb, code, 0) {
		case .None:
		case .Blocked:
			core.compat_unknown(.Iop_Cd_Intr, cb, pc = cb)
			fmt.eprintfln("iop: cdvdman callback at %x blocked", cb)
		case .Call:
			fmt.eprintfln("iop: cdvdman callback at %x stopped", cb)
		}
	}
}

// After a failed load: puts the callback and the runs owed back as they
// were when the load began (`saved`) if the callback lies in `freed`, the
// memory its undo frees. The load's own runs go; those owed before it stay,
// to run with the callback put back. The drive stays as it is: the disc's
// spin is not the load's to undo.
cd_undo :: proc(saved: Iop_Cd, freed: []Sys_Block) {
	if sys_in(freed, iop_cd.callback) {
		stopped := iop_cd.stopped
		iop_cd = saved
		iop_cd.stopped = stopped
	}
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
