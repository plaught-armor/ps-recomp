// VU0_CAPTURE=<file>, VU1_CAPTURE=<file>: record each VU's microcode as it
// runs, for the recompiler.
//
// Programs whose microcode the EE builds from VIF MPG packets in data, not
// in a .vutext section, can only be found by watching them run. Each
// distinct micro memory image a program starts from is appended to the
// VU's file once, then each address control enters it at: the program
// start, and every JR/JALR target. Capturing runs that VU entirely in the
// interpreter, so every jump is seen.
//
// The file is a run of records, appended and never rewritten, so several
// runs can share one file and a run that never reaches quit() keeps what it
// wrote:
//	'I', hash: u64, micro: [size]u8   an image, keyed by the XXH3-64 of micro
//	'E', hash: u64, pc: u32           an entry into that image
// size is the VU's micro memory: 4 KiB for VU0, 16 KiB for VU1. Integers
// are little-endian. Records repeat across runs; readers dedupe.
package ps2_vu

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "base:runtime"
import "ps:core"

@(private)
Capture :: struct {
	file: ^os.File,
	gen:  u32, // the VU's micro generation when hash was taken
	hash: u64,
	seen: map[[2]u64]bool, // {hash, pc}, with pc ~0 for the image
}

@(private)
vu0_cap, vu1_cap: Capture

@(private)
vu_capture_options :: proc() {
	if capture_open(&vu0_cap, "VU0_CAPTURE", 0) {vu0_table.nocomp = true}
	if capture_open(&vu1_cap, "VU1_CAPTURE", 1) {vu1_table.nocomp = true}
}

@(private = "file")
capture_open :: proc(c: ^Capture, env: string, unit: int) -> bool {
	path := core.env(env)
	if path == "" {return false}
	// Off the emulator heap: snapshots must not roll capture state back.
	context.allocator = runtime.heap_allocator()
	c.seen = make(map[[2]u64]bool)
	f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Read_All + {.Write_User})
	if err != nil {
		fmt.eprintfln("vu%d: cannot open capture file %s: %v", unit, path, err)
		return false
	}
	c.file = f
	c.gen = 0
	return true
}

// v's capture; its file is nil when v is not being captured.
@(private)
capture_of :: #force_inline proc(v: ^Vu) -> ^Capture {
	return v == &vu1 ? &vu1_cap : &vu0_cap
}

// Note that control enters v's micro memory at addr.
@(private)
vu_capture :: proc(v: ^Vu, addr: u32) {
	c := capture_of(v)
	gen := v == &vu1 ? vu1_micro_gen : vu0_micro_gen
	if c.gen != gen {
		c.gen = gen
		c.hash = u64(xxhash.XXH3_64_default(v.micro))
		if capture_record(c, {c.hash, ~u64(0)}) {
			rec: [1 + 8]u8
			rec[0] = 'I'
			(^u64le)(&rec[1])^ = u64le(c.hash)
			os.write(c.file, rec[:])
			os.write(c.file, v.micro)
		}
	}
	pc := addr & u32(len(v.micro) - 1) &~ 7
	if capture_record(c, {c.hash, u64(pc)}) {
		rec: [1 + 8 + 4]u8
		rec[0] = 'E'
		(^u64le)(&rec[1])^ = u64le(c.hash)
		(^u32le)(&rec[9])^ = u32le(pc)
		os.write(c.file, rec[:])
	}
}

// Whether key is new, marking it seen.
@(private = "file")
capture_record :: proc(c: ^Capture, key: [2]u64) -> bool {
	if key in c.seen {return false}
	c.seen[key] = true
	return true
}
