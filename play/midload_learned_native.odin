#+build !wasi
// A native build's mid-run learned compile (midload_learned.odin): a child
// of this executable (`play --learned-midload <records> <out> <parent
// pid>`) compiles the records from one temporary file into another
// (ps-learn-<run pid>-*), both removed once the blob is loaded, at exit and
// on a fatal error (core.fatal_cleanup). On Linux the child dies with the
// run (midload_child), and a run removes the temporary files of runs that
// ended without removing theirs (midload_tmp_sweep).
package play

import "core:fmt"
import "core:os"
import "core:time"

// The prefix of the compile's temporary files, before the run's pid.
@(private = "file")
MIDLEARN_TMP :: "ps-learn-"

@(private = "file")
mln: struct {
	self:    string, // this executable
	child:   os.Process,
	records: string, // the compile's records (a LEARN stream)
	out:     string, // its blob
}

// Find this executable and remove what runs that ended left; false, after
// a message, when there is no executable to start.
@(private)
midlearn_host_init :: proc() -> bool {
	self, err := os.get_executable_path(context.allocator)
	if err != nil {
		fmt.eprintln("play: mid-run learned loading off, cannot find this executable:", err)
		return false
	}
	mln = {self = self}
	midload_tmp_sweep(MIDLEARN_TMP)
	return true
}

// Start the child compiling mlrn's stream into a new temporary file.
@(private)
midlearn_host_start :: proc() -> Midload_Start {
	ok: bool
	if mln.records, ok = midload_tmp(MIDLEARN_TMP, ".rec", "learned compile"); !ok {
		midlearn_cleanup()
		return .Not
	}
	if mln.out, ok = midload_tmp(MIDLEARN_TMP, ".bin", "learned compile"); !ok {
		midlearn_cleanup()
		return .Not
	}
	if err := os.write_entire_file(mln.records, mlrn.stream[:]); err != nil {
		fmt.eprintln("play: mid-run learned compile: cannot write", mln.records, err)
		midlearn_cleanup()
		return .Not
	}
	ppid := fmt.tprint(os.get_pid())
	err: os.Error
	mln.child, err = os.process_start({command = {mln.self, "--learned-midload", mln.records, mln.out, ppid}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintln("play: mid-run learned compile: cannot start the child:", err)
		midlearn_cleanup()
		return .Not
	}
	return .Started
}

// Wait up to timeout for the child, taking its blob when it has ended.
@(private)
midlearn_host_poll :: proc(timeout: time.Duration) -> Midload_Poll {
	state, err := os.process_wait(mln.child, timeout)
	switch {
	case err == os.General_Error.Timeout:
		return .Running
	case err != nil:
		fmt.eprintln("play: mid-run learned compile: cannot wait for the child:", err)
		return .Lost
	}
	if !state.exited || state.exit_code != 0 {
		fmt.eprintfln("play: mid-run learned compile failed (%s)", midload_ended(state))
		midlearn_cleanup()
		return .Failed
	}
	start := time.tick_now()
	blob, rerr := os.read_entire_file(mln.out, context.allocator)
	if rerr != nil || len(blob) == 0 {
		fmt.eprintln("play: mid-run learned compile failed: no blob in", mln.out, rerr)
		delete(blob)
		midlearn_cleanup()
		return .Failed
	}
	defer delete(blob)
	return midlearn_take(blob, start)
}

// Kill the child and wait for it to end; false when it cannot be waited
// for, and may still run.
@(private)
midlearn_host_stop :: proc(_: bool) -> bool {
	_ = os.process_kill(mln.child)
	if _, err := os.process_wait(mln.child); err != nil {
		fmt.eprintln("play: mid-run learned loading off: a compile child cannot be waited for:", err)
		return false
	}
	return true
}

@(private)
midlearn_host_cleanup :: proc() {
	midload_tmp_remove(&mln.records)
	midload_tmp_remove(&mln.out)
}
