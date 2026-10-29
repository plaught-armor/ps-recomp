// VU1_CAPTURE=<file>: record VU1 microcode as it runs, for the recompiler.
//
// Programs whose microcode the EE builds from VIF MPG packets in data, not
// in a .vutext section, can only be found by watching them run. Each
// distinct micro memory image a program starts from is appended to the file
// once, then each address control enters it at: the program start, and
// every JR/JALR target. Capturing runs everything in the interpreter, so
// every jump is seen.
//
// The file is a run of records, appended and never rewritten, so several
// runs can share one file and a run that never reaches quit() keeps what it
// wrote:
//	'I', hash: u64, micro: [16 KiB]u8   an image, keyed by the XXH3-64 of micro
//	'E', hash: u64, pc: u32             an entry into that image
// Integers are little-endian. Records repeat across runs; readers dedupe.
package ps2_vu

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "base:runtime"
import "ps:core"

@(private)
vu1_capture_file: ^os.File
@(private)
vu1_capture_gen: u32 // vu1_micro_gen when vu1_capture_hash was taken
@(private)
vu1_capture_hash: u64
@(private)
vu1_capture_seen: map[[2]u64]bool // {hash, pc}, with pc ~0 for the image

vu1_capture_options :: proc() {
	path := core.env("VU1_CAPTURE")
	if path == "" {return}
	// Off the emulator heap: snapshots must not roll capture state back.
	context.allocator = runtime.heap_allocator()
	vu1_capture_seen = make(map[[2]u64]bool)
	f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Read_All + {.Write_User})
	if err != nil {
		fmt.eprintfln("vu1: cannot open capture file %s: %v", path, err)
		return
	}
	vu1_capture_file = f
	vu1_capture_gen = 0
	vu1_nocomp = true
}

// Note that control enters micro memory at addr.
@(private)
vu1_capture :: proc(addr: u32) {
	if vu1_capture_gen != vu1_micro_gen {
		vu1_capture_gen = vu1_micro_gen
		vu1_capture_hash = u64(xxhash.XXH3_64_default(vu1_micro[:]))
		if vu1_capture_record({vu1_capture_hash, ~u64(0)}) {
			rec: [1 + 8]u8
			rec[0] = 'I'
			(^u64le)(&rec[1])^ = u64le(vu1_capture_hash)
			os.write(vu1_capture_file, rec[:])
			os.write(vu1_capture_file, vu1_micro[:])
		}
	}
	pc := addr & u32(len(vu1_micro) - 1) &~ 7
	if vu1_capture_record({vu1_capture_hash, u64(pc)}) {
		rec: [1 + 8 + 4]u8
		rec[0] = 'E'
		(^u64le)(&rec[1])^ = u64le(vu1_capture_hash)
		(^u32le)(&rec[9])^ = u32le(pc)
		os.write(vu1_capture_file, rec[:])
	}
}

// Whether key is new, marking it seen.
@(private = "file")
vu1_capture_record :: proc(key: [2]u64) -> bool {
	if key in vu1_capture_seen {return false}
	vu1_capture_seen[key] = true
	return true
}
