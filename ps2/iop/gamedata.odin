package ps2_iop

// The disc paths of the game's reads, for game data (core/gamedata.odin):
// a file read through fileio or ioman by the name it was opened with, a
// sector read by the file a search or an open placed over its sectors.
// Host state, filled only with game data on; a rollback keeps it.

import "core:fmt"
import "core:strings"
import "ps:core"

@(private = "file")
Gd_File_Key :: struct {
	f:   rawptr,
	lba: u32,
}

@(private = "file")
gd_files: map[Gd_File_Key]string

@(private = "file")
Gd_Extent :: struct {
	lsn, sectors: u32,
	size:         i64,
	name:         string,
}

@(private = "file")
gd_extents: [dynamic]Gd_Extent

// Note the name a disc file was opened or found by, and, at lsn (0: not
// known), the sectors of its size. A file of the ROM is not the disc's.
@(private)
gd_note :: proc(file: Disc_File, lsn: u32, name: string) {
	if !core.gamedata.on || file.rom != nil {return}
	context.allocator = core.long_allocator()
	key := Gd_File_Key{file.f, file.lba}
	if key not_in gd_files {gd_files[key] = strings.clone(core.gamedata_disc_path(name))}
	if lsn == 0 {return}
	for e in gd_extents {
		if e.lsn == lsn {return}
	}
	sectors := u32(max((file.size + DISC_SECTOR - 1) / DISC_SECTOR, 1))
	append(&gd_extents, Gd_Extent{lsn, sectors, file.size, gd_files[key]})
}

// cpu's read of data from byte pos of file into its RAM at dest; none of
// a file of the ROM.
@(private)
gd_file_load :: proc(cpu: core.Gamedata_Cpu, file: Disc_File, pos: i64, dest: u32, data: []u8) {
	if !core.gamedata.on || file.rom != nil {return}
	name := gd_files[{file.f, file.lba}] or_else fmt.tprintf("lsn:%08x", file.lba)
	core.gamedata_load(cpu, name, u64(pos), dest, data)
}

// cpu's read of data, sectors from lsn, into its RAM at dest: as a read of
// the file placed over lsn, cut to its end, or of `lsn:<lsn>`.
@(private)
gd_sector_load :: proc(cpu: core.Gamedata_Cpu, lsn, dest: u32, data: []u8) {
	if !core.gamedata.on {return}
	for e in gd_extents {
		if lsn < e.lsn || lsn >= e.lsn + e.sectors {continue}
		off := i64(lsn - e.lsn) * DISC_SECTOR
		n := int(clamp(e.size - off, 0, i64(len(data)))) // in i64: a file may pass 2 GiB
		core.gamedata_load(cpu, e.name, u64(off), dest, data[:n])
		return
	}
	core.gamedata_load(cpu, fmt.tprintf("lsn:%08x", lsn), 0, dest, data)
}
