// LEARN=<file>: record the code the interpreters run, for the recompiler.
//
// A function no recompiled code covers (a PS1 overlay, an IOP module, EE
// code loaded at run time, a jump target the recompiler never labelled) is
// interpreted from its entry. With LEARN set, each such run is noted when it
// returns: the words between the lowest and the highest address the run
// fetched itself (its callees are runs of their own), with the XXH3-64 of
// those words. A run that stored into that range is marked .Smc. A run that
// never returns (a guest thread's loop) is noted when the process reports,
// with what it fetched so far, marked .Open.
//
// A run is also marked .Smc when the words it fetched are not the words
// written: a fetch of a RAM word saw another word than an earlier fetch of
// it in the run, or than RAM holds when the record is written. That is code
// changed mid-run by a store no interpreter notes (recompiled code, a DMA,
// the host): a callee patching its caller's calls, say, and the caller
// restoring them later. Each RAM word keeps the word last fetched there and
// when, so the check is exact; a fetch outside RAM (a ROM) is not checked.
//
// How stores are checked depends on the processor (learn_cpu). With RAM
// stamps (PS1, IOP), each RAM word keeps the number of the last store into
// it, so the check is exact for any run length; a range outside RAM cannot
// be checked and is marked .Smc_Unknown. Without (EE), a ring of the last
// LEARN_STORES_MAX store addresses is looked back over; a run whose stores
// outran it is marked .Smc_Unknown, never clean.
//
// The file's format is core/learnfile's.
//
// Learning is host state, off the emulator heap: snapshots and rollback
// never roll it back, so a replayed frame is counted again. Without LEARN
// the interpreters only test a nil frame pointer; nothing else changes.
package core

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "ps:core/learnfile"

// The LEARN file format lives in core/learnfile; these are its names here.
Learn_Cpu :: learnfile.Learn_Cpu
Learn_Flag :: learnfile.Learn_Flag
Learn_Flags :: learnfile.Learn_Flags
Learn_Record :: learnfile.Learn_Record
LEARN_SPAN_MAX :: learnfile.LEARN_SPAN_MAX
LEARN_HEADER :: learnfile.LEARN_HEADER
LEARN_TAG :: learnfile.LEARN_TAG
learn_read :: learnfile.learn_read
learn_compact :: learnfile.learn_compact
learn_compilable :: learnfile.learn_compilable

// The most records one process writes, and the most bytes.
LEARN_RECORDS_MAX :: 4096
LEARN_BYTES_MAX :: 16 * 1024 * 1024
// The store ring's length: the stores a run in progress can look back over,
// on a processor without RAM stamps.
LEARN_STORES_MAX :: 1 << 16
// The most runs in progress at once, over every processor. A run begun past
// it is not noted (learn_begin returns nil) and is counted as dropped.
LEARN_LIVE_MAX :: 1024

// One interpreted run in progress. Frames live in learn.pool, not on the
// interpreter's stack: guest threads switch coroutines mid-run, so runs need
// not nest, and a run whose coroutine is reaped or rolled back never ends
// but must still be safe to report.
Learn_Frame :: struct {
	cpu:    Learn_Cpu,
	slot:   u16, // its index in learn.pool
	entry:  u32,
	lo, hi: u32, // the lowest and highest word fetched
	log_at:   u64, // Learn_Space.seq when the run began
	fetch_at: u64, // Learn_Space.insns when the run began
	changed:  bool, // a fetch saw another word than an earlier one there
}

@(private = "file")
Learn_Space :: struct {
	cycles:    ^u64, // the processor's cycle counter
	cpi:       u64, // the cycles its interpreter charges an instruction
	read:      proc(addr: u32) -> u32, // a word of its memory
	ram:       []u8, // its RAM, ram_bytes long, when the host gives it: read directly
	ram_bytes: u32, // RAM size, a power of two: the words fetched and stamped
	stamped:   bool, // stores are checked by RAM stamps, not the ring
	insns:     u64, // instructions interpreted, delay slots included
	runs:      u64, // runs that returned
	begun:     u64,
	dropped:   u64, // runs begun with every frame in use
	records:   u64,
	smc:       u64, // records marked .Smc or .Smc_Unknown
	large:     u64,
	entries:   map[u32]bool,
	words:     map[u64]bool, // address << 32 | word, over every record
	seq:       u64, // stores noted
	begin_seq: u64, // seq when the latest run began
	// With RAM stamps: per RAM word, the seq of the last store into it (0:
	// none since learning began).
	stamps:    []u64,
	// Per RAM word, the word last fetched there and the insns count of
	// that fetch (0: none since learning began).
	fetched:    []u32,
	fetched_at: []u64,
	// Without: the store addresses, a ring of LEARN_STORES_MAX; a run looks
	// back over those since it began. Never cleared, as a run that never
	// returns must not hold it.
	log:       []u32,
}

Learn_Cpus :: bit_set[Learn_Cpu;u8]

learn: struct {
	on:      bool, // LEARN is set and its file open
	cpus:    Learn_Cpus, // the processors whose runs are noted while on
	file:    ^os.File,
	written: int, // bytes this process wrote
	capped:  bool,
	keys:    map[learnfile.Learn_Key]bool,
	space:   [Learn_Cpu]Learn_Space,
	buf:     [dynamic]u8,
	// The frames of runs in progress: pool[k] is in use while used[k];
	// free[:n_free] are the others.
	pool:    [LEARN_LIVE_MAX]Learn_Frame,
	used:    [LEARN_LIVE_MAX]bool,
	free:    [LEARN_LIVE_MAX]u16,
	n_free:  int,
	pooled:  bool, // free is filled
}

// The frame handed from a run's start to its interpreter loop (learn_take).
learn_handoff: [Learn_Cpu]^Learn_Frame

// What learn_hold set aside, put back by learn_release, and the scratch
// arrays each processor fetches and stores into meanwhile.
@(private = "file")
learn_held: struct {
	on:      bool,
	cpus:    Learn_Cpus,
	space:   [Learn_Cpu]Learn_Space,
	pool:    [LEARN_LIVE_MAX]Learn_Frame,
	used:    [LEARN_LIVE_MAX]bool,
	free:    [LEARN_LIVE_MAX]u16,
	n_free:  int,
	pooled:  bool,
	handoff: [Learn_Cpu]^Learn_Frame,
	scratch: [Learn_Cpu]struct {
		fetched:            []u32,
		fetched_at, stamps: []u64,
		log:                []u32,
	},
}

// A compat probe's branches begin from a saved state (compat_probe_begin):
// until learn_release no run begins a frame (no processor is learned) and
// a run that ends notes nothing. The runs in progress at the save, which
// the branches carry on, fetch and store into scratch arrays; learn_release
// puts their frames, the counts and the arrays back as they were, so the
// branches leave no trace in what is learned. No check on the per-word
// paths: learn_fetch and learn_store cost the same.
learn_hold :: proc() {
	h := &learn_held
	assert(!h.on)
	// One copy per statement: a tuple assignment loads the right side whole
	// first, and the pool's aggregate load unrolls into hundreds of KB of
	// code on wasm32 (which wasm-opt then cannot optimize in 8 GB).
	h.on = true
	h.cpus = learn.cpus
	h.space = learn.space
	h.handoff = learn_handoff
	h.pool = learn.pool
	h.used = learn.used
	h.free = learn.free
	h.n_free = learn.n_free
	h.pooled = learn.pooled
	learn.cpus = {}
	for &s, cpu in learn.space {
		if s.ram_bytes == 0 {
			continue // not set up: it runs no frames
		}
		x := &h.scratch[cpu]
		if x.fetched == nil {
			x.fetched = make([]u32, s.ram_bytes / 4, long_allocator())
			x.fetched_at = make([]u64, s.ram_bytes / 4, long_allocator())
			if s.stamped {
				x.stamps = make([]u64, s.ram_bytes / 4, long_allocator())
			} else {
				x.log = make([]u32, LEARN_STORES_MAX, long_allocator())
			}
		}
		s.fetched, s.fetched_at, s.stamps, s.log = x.fetched, x.fetched_at, x.stamps, x.log
	}
}

// The probe's branches ended, its saved state loaded again: learning goes
// on from where learn_hold left it.
learn_release :: proc() {
	h := &learn_held
	assert(h.on)
	h.on = false
	// One copy per statement, as in learn_hold.
	learn.cpus = h.cpus
	learn.space = h.space
	learn_handoff = h.handoff
	learn.pool = h.pool
	learn.used = h.used
	learn.free = h.free
	learn.n_free = h.n_free
	learn.pooled = h.pooled
}

@(rodata)
LEARN_CPU_NAMES := [Learn_Cpu]string {
	.Psx = "psx",
	.Ee  = "ee",
	.Iop = "iop",
}

// Open the LEARN file, once; false when LEARN is unset or 0, or the file
// cannot be opened (after a message). LEARN=1 is play's (play/main.odin).
learn_open :: proc() -> bool {
	if learn.on {
		return true
	}
	path := env("LEARN")
	if path == "" || path == "0" {
		return false
	}
	if path == "1" {
		// play opens the disc directory's records before the run.
		fmt.eprintln("learn: LEARN=1 records into a disc's directory, which only play knows; name a file")
		return false
	}
	return learn_open_path(path)
}

// Open path as the LEARN file, noting the runs of the processors in cpus
// alone (default: all); false after a message when it cannot be opened.
learn_open_path :: proc(path: string, cpus := ~Learn_Cpus{}) -> bool {
	context.allocator = long_allocator()
	f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Read_All + {.Write_User})
	if err != nil {
		fmt.eprintfln("learn: cannot open %s: %v", path, err)
		return false
	}
	learn.file = f
	learn.on = true
	learn.cpus = cpus
	return true
}

// Whether cpu's interpreter notes its runs: LEARN is open, for cpu.
learn_on :: #force_inline proc(cpu: Learn_Cpu) -> bool {
	return cpu in learn.cpus
}

// Name cpu's cycle counter, the cycles its interpreter charges an
// instruction (for the summary), how to read a word of its memory and the
// size of its RAM, a power of two, at physical 0 with its mirrors below
// physical max(0x800000, ram_bytes) (the R3000 map; the EE's 32 MB has
// none). With stamps its stores are checked by RAM stamps, else the ring.
// ram, when given, is that RAM itself: the words a record holds are read
// from it rather than through read, one call per word.
learn_cpu :: proc(cpu: Learn_Cpu, cycles: ^u64, cycles_per_insn: u64, read: proc(addr: u32) -> u32, ram_bytes: u32, stamps: bool, ram: []u8 = nil) {
	assert(ram_bytes != 0 && ram_bytes & (ram_bytes - 1) == 0)
	assert(ram == nil || len(ram) == int(ram_bytes))
	s := &learn.space[cpu]
	s.cycles = cycles
	s.cpi = cycles_per_insn
	s.read = read
	s.ram = ram
	s.ram_bytes = ram_bytes
	s.stamped = stamps
}

// The RAM word index of addr; false outside RAM.
@(private = "file")
ram_word :: #force_inline proc(s: ^Learn_Space, addr: u32) -> (u32, bool) {
	phys := addr & 0x1fff_ffff
	if phys >= max(0x80_0000, s.ram_bytes) {
		return 0, false
	}
	return (phys & (s.ram_bytes - 1)) >> 2, true
}

// A run of cpu's interpreter from entry begins: its frame, or nil when every
// frame is in use (the run is then not noted).
learn_begin :: proc(cpu: Learn_Cpu, entry: u32) -> ^Learn_Frame {
	s := &learn.space[cpu]
	if !learn.pooled {
		for k in 0 ..< LEARN_LIVE_MAX {
			learn.free[k] = u16(LEARN_LIVE_MAX - 1 - k)
		}
		learn.n_free = LEARN_LIVE_MAX
		learn.pooled = true
	}
	if learn.n_free == 0 {
		s.dropped += 1
		return nil
	}
	learn.n_free -= 1
	k := learn.free[learn.n_free]
	learn.used[k] = true
	s.begun += 1
	s.begin_seq = s.seq
	f := &learn.pool[k]
	f^ = {cpu = cpu, slot = k, entry = entry, lo = entry, hi = entry, log_at = s.seq, fetch_at = s.insns}
	return f
}

// f's run as a handle an interpreter keeps in its own records (the FLAT
// interpreter's shadow stack, psx/cpu/interp_flat.odin): 0 for none.
learn_handle :: #force_inline proc(f: ^Learn_Frame) -> u16 {
	return f == nil ? 0 : f.slot + 1
}

// The run of handle h, begun from entry, or nil: none, or one that is not in
// progress. A record put back by a snapshot can hold the handle of a run
// that ended since, whose frame another run may hold now.
learn_frame :: #force_inline proc(h: u16, entry: u32) -> ^Learn_Frame {
	if h == 0 {
		return nil
	}
	f := &learn.pool[h - 1]
	if !learn.used[h - 1] || f.entry != entry {
		return nil
	}
	return f
}

// The interpreter fetched w, the word at pc, for f's run.
learn_fetch :: #force_inline proc(f: ^Learn_Frame, pc, w: u32) #no_bounds_check {
	f.lo = min(f.lo, pc)
	f.hi = max(f.hi, pc)
	s := &learn.space[f.cpu]
	s.insns += 1
	k, in_ram := ram_word(s, pc)
	if !in_ram {
		return
	}
	if s.fetched == nil {
		learn_fetched_make(s)
	}
	if s.fetched[k] != w && s.fetched_at[k] > f.fetch_at {
		f.changed = true
	}
	s.fetched[k] = w
	s.fetched_at[k] = s.insns
}

// Untouched pages of the zeroed arrays are never committed: the host keeps
// only those of the RAM code is fetched from.
@(private = "file")
learn_fetched_make :: proc(s: ^Learn_Space) {
	s.fetched = make([]u32, s.ram_bytes / 4, long_allocator())
	s.fetched_at = make([]u64, s.ram_bytes / 4, long_allocator())
}

// f's run stores at addr.
learn_store :: proc(f: ^Learn_Frame, addr: u32) #no_bounds_check {
	s := &learn.space[f.cpu]
	if s.stamped {
		w, in_ram := ram_word(s, addr)
		if !in_ram {
			return
		}
		if s.stamps == nil {
			s.stamps = make([]u64, s.ram_bytes / 4, long_allocator())
		}
		s.seq += 1
		s.stamps[w] = s.seq
		return
	}
	if s.log == nil {
		s.log = make([]u32, LEARN_STORES_MAX, long_allocator())
	} else if s.seq > s.begin_seq && s.log[(s.seq - 1) % LEARN_STORES_MAX] == addr {
		// The same address as the last store, which every run in progress
		// sees already: it began after the latest run did.
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

// f's run returned. f is not used after.
learn_end :: proc(f: ^Learn_Frame) {
	if learn_held.on {
		return // in a probe's branch: learn_release puts f back
	}
	s := &learn.space[f.cpu]
	s.runs += 1
	learn_write(s, f, learn_smc(s, f))
	learn.used[f.slot] = false
	learn.free[learn.n_free] = f.slot
	learn.n_free += 1
}

// Whether stores since f's run began reached its range. Runs of other guest
// threads may have stored since too; a run is marked by their stores as
// well, never missing its own.
@(private = "file")
learn_smc :: proc(s: ^Learn_Space, f: ^Learn_Frame) -> Learn_Flags #no_bounds_check {
	if s.stamped {
		if f.hi - f.lo + 4 > LEARN_SPAN_MAX {
			return {} // .Large: no words to check against
		}
		lo, lo_ok := ram_word(s, f.lo)
		hi, hi_ok := ram_word(s, f.hi)
		if !lo_ok || !hi_ok || hi < lo {
			return {.Smc_Unknown} // outside RAM, or across a mirror's end
		}
		if s.stamps == nil {
			return {}
		}
		for w in lo ..= hi {
			if s.stamps[w] > f.log_at {
				return {.Smc}
			}
		}
		return {}
	}
	flags: Learn_Flags
	at := f.log_at
	if s.seq - at > LEARN_STORES_MAX {
		flags += {.Smc_Unknown}
		at = s.seq - LEARN_STORES_MAX
	}
	for i in at ..< s.seq {
		a := s.log[i % LEARN_STORES_MAX]
		if a + 3 >= f.lo && a <= f.hi + 3 {
			flags += {.Smc}
			break
		}
	}
	return flags
}

// Write f's run as a record with flags, unless the same record was written.
@(private = "file")
learn_write :: proc(s: ^Learn_Space, f: ^Learn_Frame, flags: Learn_Flags) {
	if learn.capped {
		return
	}
	flags := flags
	span := f.hi - f.lo + 4
	n := span / 4
	if span > LEARN_SPAN_MAX {
		flags += {.Large}
		n = 0
	}
	context.allocator = long_allocator()
	resize(&learn.buf, LEARN_HEADER + int(n) * 4)
	words := ([^]u32le)(raw_data(learn.buf[LEARN_HEADER:]))[:n]
	if lo, ok := ram_word(s, f.lo); ok && s.ram != nil && int(lo) + int(n) <= len(s.ram) / 4 {
		copy(learn.buf[LEARN_HEADER:], s.ram[lo * 4:][:n * 4])
	} else {
		for &w, i in words {
			w = u32le(s.read(f.lo + u32(i) * 4))
		}
	}
	if n != 0 && learn_refetched(s, f, words) {
		flags += {.Smc}
	}
	hash := u64(xxhash.XXH3_64_default(learn.buf[LEARN_HEADER:]))
	key := learnfile.Learn_Key{f.cpu, flags, f.entry, f.lo, n, hash}
	if key in learn.keys {
		return
	}
	if learn.written + len(learn.buf) > LEARN_BYTES_MAX || len(learn.keys) >= LEARN_RECORDS_MAX {
		learn.capped = true
		fmt.eprintfln("learn: cap reached (%d records, %d bytes); no more are kept", len(learn.keys), learn.written)
		return
	}
	learn.keys[key] = true
	learnfile.learn_header(learn.buf[:LEARN_HEADER], f.cpu, flags, f.entry, f.lo, n, hash)
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

// Whether f's run fetched other words than words, its range's now: a fetch
// saw another word than an earlier fetch there, or the last fetch of a word
// since the run began is not that word.
@(private = "file")
learn_refetched :: proc(s: ^Learn_Space, f: ^Learn_Frame, words: []u32le) -> bool #no_bounds_check {
	if f.changed {
		return true
	}
	if s.fetched == nil {
		return false
	}
	for w, i in words {
		k, in_ram := ram_word(s, f.lo + u32(i) * 4)
		if in_ram && s.fetched[k] != u32(w) && s.fetched_at[k] > f.fetch_at {
			return true
		}
	}
	return false
}

// Under LEARN, write each run still in progress as an .Open record, then
// print a line per processor that interpreted: its distinct entries and
// words kept, the instructions interpreted and its whole run in
// instructions (its cycles over what an instruction costs). Call where the
// run ends.
learn_report :: proc() {
	if !learn.on {
		return
	}
	for used, k in learn.used {
		if used {
			f := &learn.pool[k]
			s := &learn.space[f.cpu]
			learn_write(s, f, learn_smc(s, f) + {.Open})
		}
	}
	for &s, cpu in learn.space {
		if s.begun == 0 && s.insns == 0 && s.dropped == 0 {
			continue
		}
		total: u64
		if s.cycles != nil && s.cpi != 0 {
			total = s.cycles^ / s.cpi
		}
		fmt.eprintfln(
			"learn: %s entries %d words %d records %d smc %d large %d runs %d open %d dropped %d insns %d of %d",
			LEARN_CPU_NAMES[cpu], len(s.entries), len(s.words), s.records, s.smc, s.large,
			s.runs, s.begun - s.runs, s.dropped, s.insns, total,
		)
	}
	if learn.capped {
		fmt.eprintln("learn: capped")
	}
	os.close(learn.file)
	learn.on = false
	learn.cpus = {}
}
