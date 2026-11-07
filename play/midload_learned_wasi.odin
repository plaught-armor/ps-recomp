#+build wasi
// A wasm32 build's mid-run learned compile (midload_learned.odin): the host
// compiles in a worker of its own, through the "system:ps_learn" imports
// (web/learn.js).
package play

import "core:fmt"
import "core:time"
import "ps:core"

foreign import ps_learn "system:ps_learn"

@(default_calling_convention = "contextless")
foreign ps_learn {
	// Start compiling the LEARN records rec and the interp list interp
	// (native.Blob_Interp each) in the host's worker: the compile's
	// generation (> 0), or -1 for a host that compiles nothing.
	@(link_name = "start")
	learn_host_start :: proc(rec: [^]u8, rec_len: i32, interp: [^]u8, interp_len: i32) -> i32 ---
	// Wait up to timeout_ms for compile gen: -1 still running, -2 failed
	// (an empty blob too), -3 a blob over the host's size, dropped; else
	// the blob's size, copied to buf (and taken) only when cap holds it. A
	// blob of another compile (one from before, late) is dropped.
	@(link_name = "poll")
	learn_host_poll :: proc(buf: [^]u8, cap: i32, timeout_ms: i32, gen: i32) -> i32 ---
}

@(private = "file")
LEARN_RUNNING :: -1
@(private = "file")
LEARN_FAILED :: -2
@(private = "file")
LEARN_OVERSIZED :: -3

// The host's compile in flight: its generation (0 none).
@(private = "file")
mlw: struct {
	gen: i32,
}

// Nothing to set up: the host says at the first start whether it compiles.
@(private)
midlearn_host_init :: proc() -> bool {
	return true
}

// Start the host compiling mlrn's stream; .Off for a host with no worker.
@(private)
midlearn_host_start :: proc() -> Midload_Start {
	bytes := learned_interp_bytes(mlrn.interp)
	mlw.gen = learn_host_start(raw_data(mlrn.stream), i32(len(mlrn.stream)), raw_data(bytes), i32(len(bytes)))
	if mlw.gen <= 0 {
		fmt.eprintln("play: mid-run learned loading off: this host has no worker to compile in")
		midlearn_cleanup()
		return .Off
	}
	return .Started
}

// Wait up to timeout for the host's compile, taking its blob when it is done.
@(private)
midlearn_host_poll :: proc(timeout: time.Duration) -> Midload_Poll {
	n := learn_host_poll(nil, 0, i32(time.duration_milliseconds(timeout)), mlw.gen)
	switch n {
	case LEARN_RUNNING:
		return .Running
	case LEARN_FAILED, 0:
		fmt.eprintln("play: mid-run learned compile failed")
		midlearn_cleanup()
		return .Failed
	case LEARN_OVERSIZED:
		// The host said so, once; not again until the records grow.
		mlrn.oversized = core.learn_count(.Psx)
		midlearn_cleanup()
		return .Failed
	}
	if n < 0 {
		fmt.eprintln("play: mid-run learned compile: the host answered", n)
		return .Lost
	}
	start := time.tick_now()
	blob := make([]u8, n)
	defer delete(blob)
	if learn_host_poll(raw_data(blob), n, 0, mlw.gen) != n {
		fmt.eprintln("play: mid-run learned compile: the host's blob went away")
		return .Lost
	}
	return midlearn_take(blob, start)
}

// The host's compile cannot be stopped: it may still run, and none other
// starts.
@(private)
midlearn_host_stop :: proc(quit: bool) -> bool {
	if !quit {
		fmt.eprintln("play: mid-run learned loading off: a compile that cannot be stopped may still run")
	}
	return false
}

@(private)
midlearn_host_cleanup :: proc() {
	mlw.gen = 0
}
