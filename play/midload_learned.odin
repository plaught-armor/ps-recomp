#+build wasi
// The mid-run load of a wasm32 build's PS1 learned functions (midload.odin
// has the policy).
//
// A PS1 run records the code it interprets (core/learn.odin); the next run
// compiles the records to a learned blob and runs them native
// (learned_blob). Until then that code runs in the interpreter. So while the
// game runs, once its records have stopped growing, the host compiles the
// records of the entries no loaded blob covers yet, all records of each, in
// a worker of its own (`play --learned psx <records> <out> <interp>`, through
// the "system:ps_learn" imports: web/learn.js), and the run loads the blob it
// returns. Nothing is stored: the next run compiles its own set, by its own
// key (learned_blob), as it would have.
//
// The blob is for the code the snapshot's interp list (psx_interp) left to
// the interpreter. A thread switch this run makes known (native_switched)
// changes that list, and a blob compiled before it would run the switch's
// code native: one whose key (learned_set), from the snapshot's records and
// the list as it is now, is not the one it started with is dropped as stale.
//
// On only in a wasm32 build that runs a PS1 game's learned code and records
// its runs (play), unless MIDLOAD=0; the host has the say on whether it can
// compile (a host without a worker says so once, and none starts).
package play

import "core:fmt"
import "core:os"
import "core:time"
import "ps:core"
import "ps:recomp/native"
import psxnative "ps:psx/native"

foreign import ps_learn "system:ps_learn"

@(default_calling_convention = "contextless")
foreign ps_learn {
	// Start compiling the LEARN records rec and the interp list interp
	// (native.Blob_Interp each) in the host's worker: 0 started, -1 a host
	// that compiles nothing.
	@(link_name = "start")
	learn_host_start :: proc(rec: [^]u8, rec_len: i32, interp: [^]u8, interp_len: i32) -> i32 ---
	// Wait up to timeout_ms for the compile: -1 still running, -2 failed,
	// -3 a blob over the host's size, dropped; else the blob's size,
	// copied to buf (and taken) only when cap holds it.
	@(link_name = "poll")
	learn_host_poll :: proc(buf: [^]u8, cap: i32, timeout_ms: i32) -> i32 ---
}

@(private = "file")
LEARN_RUNNING :: -1
@(private = "file")
LEARN_FAILED :: -2
@(private = "file")
LEARN_OVERSIZED :: -3

@(private = "file")
Midload_Learned :: struct {
	dir:     string,
	records: string, // the LEARN file
	covered: map[u32]bool, // the entries a loaded blob was compiled from
	// The compile in flight: its records, as a LEARN stream, their
	// entries, the interp list it leaves out and its key.
	stream:  [dynamic]u8,
	entries: [dynamic]u32,
	interp:  []native.Blob_Interp,
	set:     string,
	loads:   int, // blobs loaded
	recs:    int, // the records they were compiled from
	stale:   int, // blobs dropped as stale
}

@(private = "file")
mlrn: Midload_Learned

// Set up loading the learned functions of the records file records (in the
// disc directory dir) mid-run; startup: whether a stored learned blob was
// loaded at the boot, compiled from the file as it is now. False when it is
// off (the comment above), and the boot then hooks nothing.
midlearn_init :: proc(dir, records: string, startup: bool) -> bool {
	if midload_off() {return false}
	job := Midload_Job {
		what    = "learned",
		noun    = "compile",
		grown   = midlearn_grown,
		start   = midlearn_start,
		poll    = midlearn_poll,
		stop    = midlearn_stop,
		cleanup = midlearn_cleanup,
		report  = midlearn_report,
	}
	if !midload_begin(job) {return false}
	mlrn = {
		dir     = dir,
		records = records,
	}
	if startup {
		data, err := os.read_entire_file(records, context.temp_allocator)
		if err == nil {
			recs, _ := core.learn_read(data, context.temp_allocator)
			for r in recs {
				if r.cpu == .Psx {mlrn.covered[r.entry] = true}
			}
		}
	}
	return true
}

// The stored learned blob would not load (learned_failed): none of its
// entries are covered.
midlearn_uncover :: proc() {
	clear(&mlrn.covered)
}

@(private = "file")
midlearn_grown :: proc() -> u64 {
	return core.learn_count(.Psx)
}

@(private = "file")
midlearn_report :: proc(fails: int) {
	fmt.eprintfln("play: mid-run learned loads: %d (%d records), %d stale, %d failed", mlrn.loads, mlrn.recs, mlrn.stale, fails)
}

// Start the host compiling the records of the entries no loaded blob covers.
@(private = "file")
midlearn_start :: proc() -> Midload_Start {
	data, err := os.read_entire_file(mlrn.records, context.temp_allocator)
	if err != nil {
		fmt.eprintln("play: mid-run learned compile: cannot read", mlrn.records, err)
		return .Not
	}
	// Compacted, the records are in the order a load's compile has them.
	compact, _ := core.learn_compact(data)
	defer delete(compact)
	recs, _ := core.learn_read(compact, context.temp_allocator)
	kept := make([dynamic]core.Learn_Record, context.temp_allocator)
	for r in recs {
		if r.cpu == .Psx && r.entry not_in mlrn.covered {append(&kept, r)}
	}
	if len(kept) == 0 {return .Not}
	interp, iok := psx_interp(mlrn.dir)
	if !iok {return .Not}
	set, _ := learned_set(kept[:], .Psx, interp)
	midlearn_cleanup()
	for r in kept {
		at := len(mlrn.stream)
		resize(&mlrn.stream, at + core.LEARN_HEADER + 4 * len(r.words))
		core.learn_header(mlrn.stream[at:][:core.LEARN_HEADER], r.cpu, r.flags, r.entry, r.lo, u32(len(r.words)), r.hash)
		copy(mlrn.stream[at + core.LEARN_HEADER:], ([^]u8)(raw_data(r.words))[:4 * len(r.words)])
		append(&mlrn.entries, r.entry)
	}
	mlrn.interp = make([]native.Blob_Interp, len(interp))
	copy(mlrn.interp, interp)
	mlrn.set = fmt.aprint(set)
	bytes := learned_interp_bytes(mlrn.interp)
	if learn_host_start(raw_data(mlrn.stream), i32(len(mlrn.stream)), raw_data(bytes), i32(len(bytes))) != 0 {
		fmt.eprintln("play: mid-run learned loading off: this host has no worker to compile in")
		midlearn_cleanup()
		return .Off
	}
	return .Started
}

// Wait up to timeout for the host's compile, taking its blob when it is done.
@(private = "file")
midlearn_poll :: proc(timeout: time.Duration) -> Midload_Poll {
	n := learn_host_poll(nil, 0, i32(time.duration_milliseconds(timeout)))
	switch n {
	case LEARN_RUNNING:
		return .Running
	case LEARN_FAILED:
		fmt.eprintln("play: mid-run learned compile failed")
		return .Failed
	case LEARN_OVERSIZED:
		// The host said so, once.
		return .Failed
	}
	if n < 0 {
		fmt.eprintln("play: mid-run learned compile: the host answered", n)
		return .Lost
	}
	start := time.tick_now()
	blob := make([]u8, n)
	defer delete(blob)
	if learn_host_poll(raw_data(blob), n, 0) != n {
		fmt.eprintln("play: mid-run learned compile: the host's blob went away")
		return .Lost
	}
	return midlearn_take(blob, start)
}

// Load the compile's blob, unless it is stale (the comment above).
@(private = "file")
midlearn_take :: proc(blob: []u8, start: time.Tick) -> Midload_Poll {
	defer midlearn_cleanup()
	interp, iok := psx_interp(mlrn.dir)
	if !iok {return .Failed}
	when core.COMMIT == "test" {
		// MIDLEARN_STALE=1: as if a thread switch were made known while
		// the compile ran (tests/wasi).
		if core.env("MIDLEARN_STALE") == "1" {
			more := make([]native.Blob_Interp, len(interp) + 1, context.temp_allocator)
			copy(more, interp)
			more[len(interp)] = {1, 1, 1}
			interp = more
		}
	}
	recs, _ := core.learn_read(mlrn.stream[:], context.temp_allocator)
	if set, _ := learned_set(recs[:], .Psx, interp); set != mlrn.set {
		mlrn.stale += 1
		fmt.eprintln("play: mid-run learned load dropped: a thread switch made known since its compile started changes what it may run")
		return .Done
	}
	when core.COMMIT == "test" {
		// MIDLEARN_CHECK=1: the worker's blob against the same compile in
		// this process (tests/wasi).
		if core.env("MIDLEARN_CHECK") == "1" {
			here, ok := learned_compile_here(.Psx, mlrn.stream[:], mlrn.interp)
			fmt.eprintfln("play: mid-run learned check: worker blob %s (%d bytes, here %d)", "same" if ok && string(here) == string(blob) else "differs", len(blob), len(here))
			delete(here)
		}
	}
	if !psxnative.load_learned_blob(blob, "the mid-run learned code") {return .Failed}
	for e in mlrn.entries {mlrn.covered[e] = true}
	mlrn.loads += 1
	mlrn.recs += len(recs)
	fmt.eprintfln("play: mid-run learned load: %d records, %.1f ms on this thread", len(recs), time.duration_milliseconds(time.tick_since(start)))
	return .Done
}

// The host's compile cannot be stopped: it may still run, and none other
// starts.
@(private = "file")
midlearn_stop :: proc(quit: bool) -> bool {
	if !quit {
		fmt.eprintln("play: mid-run learned loading off: a compile that cannot be stopped may still run")
	}
	return false
}

@(private = "file")
midlearn_cleanup :: proc() {
	clear(&mlrn.stream)
	clear(&mlrn.entries)
	delete(mlrn.interp)
	mlrn.interp = nil
	delete(mlrn.set)
	mlrn.set = ""
}
