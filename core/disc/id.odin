package disc

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"

// The disc's id, the name its user data lives under: the serial SYSTEM.CNF's
// boot name makes, `.`, then 16 hex digits of XXH3-64 over the volume
// descriptor (sector 16), then SYSTEM.CNF and the boot executable, each
// after its length as a little-endian u32 (0 for no SYSTEM.CNF); the digits
// alone when there is no serial.
// These three tell discs and their revisions apart without reading a whole
// DVD. With no SYSTEM.CNF the executable is PSX.EXE, as the PS1 BIOS boots
// it; a SYSTEM.CNF that does not parse, or a boot file that is missing, fails.
// The id holds only letters, digits, `-` and `.`.
id :: proc(d: ^Disc, allocator := context.allocator) -> (id: string, ok: bool) {
	pvd: [DATA]u8
	read(d, 16, pvd[:]) or_return
	cnf: []u8
	boot, serial := "PSX.EXE", ""
	if _, found := find(d, "SYSTEM.CNF", context.temp_allocator); found {
		c := system_cnf(d, context.temp_allocator) or_return
		cnf = read_file(d, "SYSTEM.CNF", context.temp_allocator) or_return
		boot, serial = c.boot, c.serial
	}
	exe := read_file(d, boot, context.temp_allocator) or_return
	input := make([]u8, len(pvd) + 4 + len(cnf) + 4 + len(exe), context.temp_allocator)
	at := 0
	for part in ([][]u8{pvd[:], cnf, exe}) {
		if at > 0 {
			endian.put_u32(input[at:], .Little, u32(len(part)))
			at += 4
		}
		at += copy(input[at:], part)
	}
	h := xxhash.XXH3_64_default(input)
	if serial == "" {
		return fmt.aprintf("%016x", h, allocator = allocator), true
	}
	return fmt.aprintf("%s.%016x", serial, h, allocator = allocator), true
}
