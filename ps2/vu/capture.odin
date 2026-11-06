// VU0_CAPTURE=<file>, VU1_CAPTURE=<file>: record each VU's microcode as it
// runs, for the recompiler.
//
// Programs whose microcode the EE builds from VIF MPG packets in data, not
// in a .vutext section, can only be found by watching them run. Each
// distinct micro memory image a program starts from is appended to the
// VU's file once, then each address control enters it at: the program
// start, and every JR/JALR target.
//
// A full capture (VU_CAPTURE=1) runs that VU entirely in the interpreter,
// so every jump is seen. A miss capture (VU_CAPTURE=miss) runs compiled
// code where it holds and records only where none does: a start or JR/JALR
// target with no program to run, and a pc compiled code hands back to the
// interpreter with no other program to run there. That pc is outside the
// program, or a pair the program holds but leaves to the interpreter (a
// clamp elision). The next conversion compiles those, so a run that only
// repeats what a capture holds appends nothing.
//
// A file is created at its first record. Opening one reads what earlier
// runs left in it, so a record is written once across runs; a last record
// cut short (a run stopped mid-write) is cut off. A unit records at most
// CAPTURE_IMAGES images, counting those the file holds, then says so once
// and records no more: what it has not recorded runs in the interpreter.
//
// The file is a run of records, each written whole by one write, appended
// and never rewritten, so a run that never reaches quit() keeps what it
// wrote. Only one run at a time may capture into a file: opening cuts what
// looks like a record cut short, which may be another run's record still
// being written, and that run's later records would then be misaligned. So
// a run locks the file when it opens or creates it and holds the lock
// until it ends; a run that finds the file locked does not capture
// (capture_lock):
//	'I', hash: u64, micro: [size]u8   an image, keyed by the XXH3-64 of micro
//	'E', hash: u64, pc: u32           an entry into that image
// size is the VU's micro memory: 4 KiB for VU0, 16 KiB for VU1. Integers
// are little-endian. Readers dedupe records repeated by older files.
package ps2_vu

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strings"
import "ps:core"

// The images a unit's capture holds at most.
CAPTURE_IMAGES :: 2048

@(private)
Capture :: struct {
	on:     bool, // capturing
	path:   string,
	file:   ^os.File, // nil until the first record when no file was there
	miss:   bool, // record only where no compiled program runs
	full:   bool, // CAPTURE_IMAGES reached: record no new image
	told:   bool, // full said
	gen:    u32, // the VU's micro generation when hash was taken
	hash:   u64,
	kept:   bool, // the file holds the image of hash
	images: int,
	unit:   int,
	seen:   map[[2]u64]bool, // {hash, pc}, with pc ~0 for the image
}

@(private)
vu0_cap, vu1_cap: Capture

// Records written by both units' captures this run.
@(private = "file")
capture_records: u64

// The records both units' captures have written this run: it changes when
// a capture grows.
vu_capture_records :: proc() -> u64 {return capture_records}

@(private)
vu_capture_options :: proc() {
	miss := core.env("VU_CAPTURE") == "miss"
	if capture_open(&vu0_cap, "VU0_CAPTURE", 0, miss) && !miss {vu0_table.nocomp = true}
	if capture_open(&vu1_cap, "VU1_CAPTURE", 1, miss) && !miss {vu1_table.nocomp = true}
}

// Open the captures again, as vu_init does (tests: a run after another on
// the same file).
vu_capture_reopen :: proc() {
	for c in ([2]^Capture{&vu0_cap, &vu1_cap}) {
		if c.file != nil {_ = os.close(c.file)}
		delete(c.seen)
		delete(c.path, core.long_allocator())
		c^ = {}
	}
	vu_capture_options()
}

@(private = "file")
capture_open :: proc(c: ^Capture, env: string, unit: int, miss: bool) -> bool {
	path := core.env(env)
	if path == "" {return false}
	// Off the emulator heap: snapshots must not roll capture state back.
	context.allocator = core.long_allocator()
	c.seen = make(map[[2]u64]bool)
	c.unit, c.miss = unit, miss
	c.path = strings.clone(path)
	c.gen = 0
	if !os.exists(path) {
		c.on = true
		return true
	}
	f, err := os.open(path, {.Read, .Write, .Append})
	if err != nil {
		fmt.eprintfln("vu%d: cannot open capture file %s: %v", unit, path, err)
		return false
	}
	if !capture_take(f, path, unit) || !capture_load(c, f, path, unit) {
		_ = os.close(f)
		return false
	}
	c.file, c.on = f, true
	return true
}

// Lock f, the capture file at path, for this run; false, after a message,
// when another run holds it or it cannot be locked. The lock goes when f
// is closed, so f stays open for the run.
@(private = "file")
capture_take :: proc(f: ^os.File, path: string, unit: int) -> bool {
	held, busy := capture_lock(f)
	if held {return true}
	if busy {
		fmt.eprintfln("vu%d: capture file %s is in use by another run; not capturing", unit, path)
	} else {
		fmt.eprintfln("vu%d: cannot lock capture file %s; not capturing", unit, path)
	}
	return false
}

// Append rec to c's file, creating it at the first record; a file that
// cannot be created or locked ends the capture.
@(private = "file")
capture_write :: proc(c: ^Capture, rec: []u8) {
	if !c.on {return}
	if c.file == nil {
		f, err := os.open(c.path, {.Write, .Create, .Append}, os.Permissions_Read_All + {.Write_User})
		if err != nil {
			fmt.eprintfln("vu%d: cannot open capture file %s: %v", c.unit, c.path, err)
			c.on = false
			return
		}
		if !capture_take(f, c.path, c.unit) {
			_ = os.close(f)
			c.on = false
			return
		}
		c.file = f
	}
	os.write(c.file, rec)
	capture_records += 1
}

// Mark what f holds seen and count its images, cutting off a last record
// cut short. False, after a message, for a file that cannot be read or
// holds a bad record: appending to it would be lost (vu.capture_read
// rejects the whole file).
@(private = "file")
capture_load :: proc(c: ^Capture, f: ^os.File, path: string, unit: int) -> bool {
	data, err := os.read_entire_file(f, os.heap_allocator())
	defer delete(data, os.heap_allocator())
	if err != nil {
		fmt.eprintfln("vu%d: cannot read capture file %s: %v", unit, path, err)
		return false
	}
	image := unit == 0 ? len(vu0_micro) : len(vu1_micro)
	pos := 0
	for pos < len(data) {
		size := 9
		switch data[pos] {
		case 'I': size += image
		case 'E': size += 4
		case:
			fmt.eprintfln("vu%d: capture file %s has a bad record at %d; not capturing", unit, path, pos)
			return false
		}
		if pos + size > len(data) {break}
		hash := u64((^u64le)(&data[pos + 1])^)
		if data[pos] == 'I' {
			if capture_record(c, {hash, ~u64(0)}) {c.images += 1}
		} else {
			c.seen[{hash, u64((^u32le)(&data[pos + 9])^)}] = true
		}
		pos += size
	}
	if pos < len(data) {
		if e := os.truncate(f, i64(pos)); e != nil {
			fmt.eprintfln("vu%d: cannot cut capture file %s at %d: %v", unit, path, pos, e)
			return false
		}
	}
	c.full = c.images >= CAPTURE_IMAGES
	return true
}

// v's capture; on when v is being captured.
@(private)
capture_of :: #force_inline proc(v: ^Vu) -> ^Capture {
	return v == &vu1 ? &vu1_cap : &vu0_cap
}

// Note that control enters v's micro memory at addr; left is the program
// that handed addr back to the interpreter, if one did. A miss capture
// skips an addr where a compiled program runs: one other than left, which
// has no label there.
@(private)
vu_capture :: proc(v: ^Vu, addr: u32, left: ^Vu_Program = nil) {
	c := capture_of(v)
	pc := addr & u32(len(v.micro) - 1) &~ 7
	if c.miss {
		if p := v == &vu1 ? vu1_lookup(pc) : vu0_lookup(pc); p != nil && p != left {return}
	}
	gen := v == &vu1 ? vu1_micro_gen : vu0_micro_gen
	if c.gen != gen {
		c.gen = gen
		c.hash = u64(xxhash.XXH3_64_default(v.micro))
		c.kept = {c.hash, ~u64(0)} in c.seen
		if !c.kept && c.full && !c.told {
			c.told = true
			fmt.eprintfln("vu%d: vu capture cap %d reached; further programs stay interpreted", c.unit, CAPTURE_IMAGES)
		}
		if !c.kept && !c.full {
			c.seen[{c.hash, ~u64(0)}] = true
			c.kept = true
			c.images += 1
			c.full = c.images >= CAPTURE_IMAGES
			// One write, so a record is cut short only by a stopped run.
			rec: [1 + 8 + len(vu1_micro)]u8
			rec[0] = 'I'
			(^u64le)(&rec[1])^ = u64le(c.hash)
			copy(rec[9:], v.micro)
			capture_write(c, rec[:9 + len(v.micro)])
		}
	}
	if !c.kept {return}
	if capture_record(c, {c.hash, u64(pc)}) {
		rec: [1 + 8 + 4]u8
		rec[0] = 'E'
		(^u64le)(&rec[1])^ = u64le(c.hash)
		(^u32le)(&rec[9])^ = u32le(pc)
		capture_write(c, rec[:])
	}
}

// Whether key is new, marking it seen.
@(private = "file")
capture_record :: proc(c: ^Capture, key: [2]u64) -> bool {
	if key in c.seen {return false}
	c.seen[key] = true
	return true
}
