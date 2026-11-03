// LEARN=<file>: record the code the interpreters run, for the recompiler.
//
// A function no recompiled code covers (a PS1 overlay, an IOP module, EE
// code loaded at run time, a jump target the recompiler never labelled) is
// interpreted from its entry. With LEARN set, each such run is noted when it
// returns: the words between the lowest and the highest address the run
// fetched itself (its callees are runs of their own), with the XXH3-64 of
// those words. A run that stored into that range is marked .Smc; one whose
// stores outran the store log is marked .Smc_Unknown, never clean.
//
// The file is a run of records, appended and never rewritten, so several
// runs can share one file and a run that never reaches its end keeps what it
// wrote:
//	'C', cpu: u8, flags: u8, 0: u8, entry: u32, lo: u32, n: u32, hash: u64,
//	words: [n]u32
// lo is the first word's address; hash is the XXH3-64 of the words' bytes,
// so a reader drops a record whose words do not match it. Integers are
// little-endian. Records repeat across runs; readers dedupe.
//
// Learning is host state, off the emulator heap: snapshots and rollback
// never roll it back, so a replayed frame is counted again. Without LEARN
// the interpreters only test a nil frame pointer; nothing else changes.
package core

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"

Learn_Cpu :: enum u8 {
	Psx,
	Ee,
	Iop,
}

Learn_Flag :: enum u8 {
	Smc,         // the run stored into its own range
	Smc_Unknown, // the store log was full during the run
	Large,       // the range is over LEARN_SPAN_MAX; no words kept
}
Learn_Flags :: bit_set[Learn_Flag;u8]

// The widest range kept, in bytes.
LEARN_SPAN_MAX :: 64 * 1024
// The most records one process writes, and the most bytes.
LEARN_RECORDS_MAX :: 4096
LEARN_BYTES_MAX :: 16 * 1024 * 1024
// The store log's length: the stores a run in progress can look back over.
LEARN_STORES_MAX :: 1 << 16

LEARN_HEADER :: 24

// One interpreted run in progress, on the interpreter's stack: guest
// threads switch coroutines mid-run, so runs need not nest.
Learn_Frame :: struct {
	cpu:      Learn_Cpu,
	entry:    u32,
	lo, hi:   u32, // the lowest and highest word fetched
	log_at:   u64, // Learn_Space.seq when the run began
}

Learn_Record :: struct {
	cpu:   Learn_Cpu,
	flags: Learn_Flags,
	entry: u32,
	lo:    u32,
	hash:  u64,
	words: []u32,
}

@(private = "file")
Learn_Key :: struct {
	cpu:   Learn_Cpu,
	flags: Learn_Flags,
	entry: u32,
	lo, n: u32,
	hash:  u64,
}

@(private = "file")
Learn_Space :: struct {
	cycles:  ^u64, // the processor's cycle counter
	cpi:     u64, // the cycles its interpreter charges an instruction
	insns:   u64, // instructions interpreted, delay slots included
	runs:    u64, // runs that returned
	begun:   u64,
	records: u64,
	smc:     u64, // records marked .Smc or .Smc_Unknown
	large:   u64,
	entries: map[u32]bool,
	words:   map[u64]bool, // address << 32 | word, over every record
	// The interpreter's store addresses, a ring of LEARN_STORES_MAX: a run
	// looks back over those since it began. Never cleared, as a run that
	// never returns (a guest thread's loop) must not hold it.
	log:     []u32,
	seq:     u64, // stores logged
}

learn: struct {
	on:      bool, // LEARN is set and its file open
	file:    ^os.File,
	written: int, // bytes this process wrote
	capped:  bool,
	keys:    map[Learn_Key]bool,
	space:   [Learn_Cpu]Learn_Space,
	buf:     [dynamic]u8,
}

// The frame handed from a run's start to its interpreter loop (learn_take).
learn_handoff: [Learn_Cpu]^Learn_Frame

@(rodata)
LEARN_CPU_NAMES := [Learn_Cpu]string {
	.Psx = "psx",
	.Ee  = "ee",
	.Iop = "iop",
}

// Open the LEARN file, once; false when LEARN is unset or the file cannot
// be opened (after a message).
learn_open :: proc() -> bool {
	if learn.on {
		return true
	}
	path := env("LEARN")
	if path == "" {
		return false
	}
	return learn_open_path(path)
}

learn_open_path :: proc(path: string) -> bool {
	context.allocator = runtime.heap_allocator()
	f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Read_All + {.Write_User})
	if err != nil {
		fmt.eprintfln("learn: cannot open %s: %v", path, err)
		return false
	}
	learn.file = f
	learn.on = true
	return true
}

// Name cpu's cycle counter and the cycles its interpreter charges an
// instruction, for the summary.
learn_cpu :: proc(cpu: Learn_Cpu, cycles: ^u64, cycles_per_insn: u64) {
	learn.space[cpu].cycles = cycles
	learn.space[cpu].cpi = cycles_per_insn
}

// A run of cpu's interpreter from entry begins.
learn_begin :: proc(cpu: Learn_Cpu, entry: u32) -> Learn_Frame {
	s := &learn.space[cpu]
	s.begun += 1
	return {cpu = cpu, entry = entry, lo = entry, hi = entry, log_at = s.seq}
}

// The interpreter fetched the word at pc for f's run.
learn_fetch :: #force_inline proc(f: ^Learn_Frame, pc: u32) {
	f.lo = min(f.lo, pc)
	f.hi = max(f.hi, pc)
	learn.space[f.cpu].insns += 1
}

// f's run stores at addr.
learn_store :: proc(f: ^Learn_Frame, addr: u32) {
	s := &learn.space[f.cpu]
	if s.log == nil {
		s.log = make([]u32, LEARN_STORES_MAX, runtime.heap_allocator())
	} else if s.seq > 0 && s.log[(s.seq - 1) % LEARN_STORES_MAX] == addr {
		return
	}
	s.log[s.seq % LEARN_STORES_MAX] = addr
	s.seq += 1
}

// The frame learn_begin made for cpu's next loop, if any, handed over once.
learn_take :: #force_inline proc(cpu: Learn_Cpu) -> ^Learn_Frame {
	f := learn_handoff[cpu]
	learn_handoff[cpu] = nil
	return f
}

// f's run returned; read gives the word at an address.
learn_end :: proc(f: ^Learn_Frame, read: proc(addr: u32) -> u32) {
	s := &learn.space[f.cpu]
	s.runs += 1
	flags: Learn_Flags
	at := f.log_at
	if s.seq - at > LEARN_STORES_MAX {
		flags += {.Smc_Unknown}
		at = s.seq - LEARN_STORES_MAX
	}
	// Runs of other guest threads may have stored since too; a run is marked
	// by their stores as well, never missing its own.
	for i in at ..< s.seq {
		a := s.log[i % LEARN_STORES_MAX]
		if a + 3 >= f.lo && a <= f.hi + 3 {
			flags += {.Smc}
			break
		}
	}
	if learn.capped {
		return
	}
	span := f.hi - f.lo + 4
	n := span / 4
	if span > LEARN_SPAN_MAX {
		flags += {.Large}
		n = 0
	}
	context.allocator = runtime.heap_allocator()
	resize(&learn.buf, LEARN_HEADER + int(n) * 4)
	words := ([^]u32le)(raw_data(learn.buf[LEARN_HEADER:]))[:n]
	for &w, i in words {
		w = u32le(read(f.lo + u32(i) * 4))
	}
	hash := u64(xxhash.XXH3_64_default(learn.buf[LEARN_HEADER:]))
	key := Learn_Key{f.cpu, flags, f.entry, f.lo, n, hash}
	if key in learn.keys {
		return
	}
	if learn.written + len(learn.buf) > LEARN_BYTES_MAX || len(learn.keys) >= LEARN_RECORDS_MAX {
		learn.capped = true
		fmt.eprintfln("learn: cap reached (%d records, %d bytes); no more are kept", len(learn.keys), learn.written)
		return
	}
	learn.keys[key] = true
	learn_header(learn.buf[:LEARN_HEADER], f.cpu, flags, f.entry, f.lo, n, hash)
	if _, err := os.write(learn.file, learn.buf[:]); err != nil {
		fmt.eprintfln("learn: write failed: %v; no more are kept", err)
		learn.capped = true
		return
	}
	learn.written += len(learn.buf)
	s.records += 1
	if flags & {.Smc, .Smc_Unknown} != {} {s.smc += 1}
	if .Large in flags {s.large += 1}
	s.entries[f.entry] = true
	for w, i in words {
		s.words[u64(f.lo + u32(i) * 4) << 32 | u64(w)] = true
	}
}

@(private = "file")
learn_header :: proc(h: []u8, cpu: Learn_Cpu, flags: Learn_Flags, entry, lo, n: u32, hash: u64) {
	h[0] = 'C'
	h[1] = u8(cpu)
	h[2] = transmute(u8)flags
	h[3] = 0
	(^u32le)(&h[4])^ = u32le(entry)
	(^u32le)(&h[8])^ = u32le(lo)
	(^u32le)(&h[12])^ = u32le(n)
	(^u64le)(&h[16])^ = u64le(hash)
}

// The records in data, in order. A record whose words do not hash to its
// hash is dropped (bad); a short or unknown tail ends the read (bad, once).
// The words point into data.
learn_read :: proc(data: []u8, allocator := context.allocator) -> (recs: [dynamic]Learn_Record, bad: int) {
	recs = make([dynamic]Learn_Record, allocator)
	for at := 0; at < len(data); {
		h := data[at:]
		if len(h) < LEARN_HEADER || h[0] != 'C' || h[1] > u8(max(Learn_Cpu)) {
			return recs, bad + 1
		}
		n := int((^u32le)(&h[12])^)
		size := LEARN_HEADER + n * 4
		if n > LEARN_SPAN_MAX / 4 || len(h) < size {
			return recs, bad + 1
		}
		at += size
		hash := u64((^u64le)(&h[16])^)
		if u64(xxhash.XXH3_64_default(h[LEARN_HEADER:size])) != hash {
			bad += 1
			continue
		}
		append(&recs, Learn_Record {
			cpu = Learn_Cpu(h[1]),
			flags = transmute(Learn_Flags)h[2],
			entry = u32((^u32le)(&h[4])^),
			lo = u32((^u32le)(&h[8])^),
			hash = hash,
			words = ([^]u32)(raw_data(h[LEARN_HEADER:]))[:n],
		})
	}
	return recs, bad
}

// Under LEARN, print a line per processor that interpreted: its distinct
// entries and words kept, the instructions interpreted and its whole run in
// instructions (its cycles over what an instruction costs). Call where the
// run ends.
learn_report :: proc() {
	if !learn.on {
		return
	}
	for &s, cpu in learn.space {
		if s.begun == 0 && s.insns == 0 {
			continue
		}
		total: u64
		if s.cycles != nil && s.cpi != 0 {
			total = s.cycles^ / s.cpi
		}
		fmt.eprintfln(
			"learn: %s entries %d words %d records %d smc %d large %d runs %d open %d insns %d of %d",
			LEARN_CPU_NAMES[cpu], len(s.entries), len(s.words), s.records, s.smc, s.large,
			s.runs, s.begun - s.runs, s.insns, total,
		)
	}
	if learn.capped {
		fmt.eprintln("learn: capped")
	}
	os.close(learn.file)
	learn.on = false
}
