// play --ramdiff: the main RAM bytes that a press script moves, for a PRESS
// condition (core input_script_load). It reads the RAM dumps DUMP writes
// (ram_<frame>.bin: PS1 main RAM, 2 MB, at the presents PS_DUMP_RAM says;
// PS2 EE RAM, 32 MB, at every dumped frame) and prints each byte that
// changed between every two frames named in a row, with its value at each:
// "u8[801f2a40] 0 3 0", the address as a condition takes it (PS1 RAM at
// 80000000). A frame written "=<frame>" instead wants the byte unchanged
// since the frame before it, which drops the bytes that move on their own.
// Dump just before and after a few presses that move a cursor and the
// cursor's byte is among the few that are left.
package play

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// PS1 and PS2 main RAM's sizes, by which a dump is one or the other.
@(private = "file")
PS1_RAM :: 2 << 20
@(private = "file")
PS2_RAM :: 32 << 20

// Print the bytes, from the dumps in dir at frames (args after the
// directory); the exit status: 0, 1 when a dump cannot be read or is not
// PS1 or PS2 main RAM's size, 2 on a bad frame.
ramdiff :: proc(dir: string, frames: []string) -> int {
	rams := make([][]u8, len(frames), context.temp_allocator)
	same := make([]bool, len(frames), context.temp_allocator)
	for f, i in frames {
		n := f
		same[i] = strings.has_prefix(n, "=")
		if same[i] {
			n = n[1:]
		}
		frame, ok := strconv.parse_u64(n, 10)
		if !ok || strings.contains_rune(n, '_') || i == 0 && same[i] {
			fmt.eprintln("ramdiff: bad frame", f)
			return 2
		}
		// The name core.dump_put gives the dump.
		path, _ := filepath.join({dir, fmt.tprintf("ram_%d.bin", frame)}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintln("ramdiff: cannot read", path, err)
			return 1
		}
		if len(data) != PS1_RAM && len(data) != PS2_RAM {
			fmt.eprintln("ramdiff:", path, "is", len(data), "bytes, not PS1 (2 MB) or PS2 (32 MB) main RAM")
			return 1
		}
		if i > 0 && len(data) != len(rams[0]) {
			fmt.eprintln("ramdiff:", path, "is not the size of", frames[0])
			return 1
		}
		rams[i] = data
	}
	base := len(rams[0]) == PS1_RAM ? u32(0x80000000) : 0
	b := strings.builder_make(context.temp_allocator)
	for a in ramdiff_offsets(rams, same, context.temp_allocator) {
		strings.builder_reset(&b)
		fmt.sbprintf(&b, "u8[%08x]", base + u32(a))
		for r in rams {
			fmt.sbprintf(&b, " %d", r[a])
		}
		fmt.println(strings.to_string(b))
	}
	return 0
}

// The offsets of the bytes that changed between each dump and the one before
// it, or stayed the same where same[i], the dumps all the same size.
ramdiff_offsets :: proc(rams: [][]u8, same: []bool, allocator := context.allocator) -> []int {
	found := make([dynamic]int, allocator)
	next: for a in 0 ..< len(rams[0]) {
		for i in 1 ..< len(rams) {
			if (rams[i][a] == rams[i - 1][a]) != same[i] {
				continue next
			}
		}
		append(&found, a)
	}
	return found[:]
}
