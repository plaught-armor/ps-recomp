// The mid-run load of the VU microprograms a PS2 run captures while it runs
// (midload.odin has the policy).
//
// With VU_CAPTURE=miss a run records the microprograms no compiled one runs
// (ps2/vu/capture.odin); the next run's conversion compiles them. Until then
// they run in the interpreter, for the whole of a first run. So while the
// game runs, once its captures have stopped growing, a child of this
// executable (`play --convert-vu <disc image> <out> <vu0> <vu1> <parent
// pid>`) compiles the VU microprograms of the captures as they are, and the
// run loads the programs it has not (ps2.load_native_vus).
//
// The child takes no capture lock and writes nothing to the disc directory:
// its blob goes to a temporary file (ps-vu-<run pid>-*.bin), removed once
// loaded, at exit and on a fatal error (core.fatal_cleanup). It compiles
// status for every program (gen.odin vu_status=all), so a program a later
// load brings never needs it kept by one of these. The startup blob may not
// keep status (ps2.load_native_vus), and a load that would bring a program
// reading status beside it is skipped, said once. On Linux the child dies
// with the run (PR_SET_PDEATHSIG) and exits at once if the run is already
// gone, and a run removes the temporary files of runs that ended without
// removing theirs (killed, or a panic).
//
// On only for a PS2 disc with native code, capturing with VU_CAPTURE=miss
// (so never in a compat child or a FLAT build), unless VUNATIVE=0 or
// MIDLOAD=0.
package play

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "ps:core"
@(require) import "ps:ps2" // used only without FLAT
@(require) import vu "ps:ps2/vu" // used only without FLAT

// The prefix of the child's temporary blob (midload_tmp).
@(private = "file")
MIDLOAD_VU_TMP :: "ps-vu-"

@(private = "file")
Midload_Vu :: struct {
	image: string,
	self:  string, // this executable
	child: os.Process,
	tmp:   string, // the child's blob
	loads: int, // blobs that brought programs
	added: int, // programs they brought
	skips: int, // loads skipped for status
}

@(private = "file")
mv: Midload_Vu

// Set up loading the captured programs mid-run for the disc image, given
// what play chose: the native blob ("" none) and VU_CAPTURE. False when it
// is off (the comment above), and the boot then hooks nothing.
midload_init :: proc(image, native, capture: string) -> bool {
	when core.FLAT {
		return false
	} else {
		if native == "" || capture != "miss" || compat_child() {return false}
		if core.env("VUNATIVE") == "0" || midload_off() {return false}
		self, err := os.get_executable_path(context.allocator)
		if err != nil {
			fmt.eprintln("play: mid-run VU load off, cannot find this executable:", err)
			return false
		}
		job := Midload_Job {
			what    = "VU",
			noun    = "conversion",
			grown   = vu.vu_capture_records,
			start   = midload_vu_start,
			poll    = midload_vu_poll,
			stop    = midload_vu_stop,
			cleanup = midload_vu_remove,
			report  = midload_vu_report,
		}
		if !midload_begin(job) {return false}
		mv = {image = image, self = self}
		midload_tmp_sweep(MIDLOAD_VU_TMP)
		return true
	}
}

@(private = "file")
midload_vu_report :: proc(fails: int) {
	fmt.eprintfln("play: mid-run VU loads: %d (%d microprograms), %d skipped for status, %d failed", mv.loads, mv.added, mv.skips, fails)
}

// Wait up to timeout for the child, taking its blob when it has ended.
@(private = "file")
midload_vu_poll :: proc(timeout: time.Duration) -> Midload_Poll {
	when core.FLAT {
		return .Lost
	} else {
		state, err := os.process_wait(mv.child, timeout)
		switch {
		case err == nil:
			return midload_vu_take(state)
		case err == os.General_Error.Timeout:
			return .Running
		}
		fmt.eprintln("play: mid-run VU conversion: cannot wait for the child:", err)
		return .Lost
	}
}

// Kill the child and wait for it to end; false when it cannot be waited
// for, and may still run.
@(private = "file")
midload_vu_stop :: proc(_: bool) -> bool {
	_ = os.process_kill(mv.child)
	if _, err := os.process_wait(mv.child); err != nil {
		fmt.eprintln("play: mid-run VU loading off: a conversion child cannot be waited for:", err)
		return false
	}
	return true
}

// Start the child converting the captures into a new temporary file.
@(private = "file")
midload_vu_start :: proc() -> Midload_Start {
	tmp, ok := midload_tmp(MIDLOAD_VU_TMP, ".bin", "VU conversion")
	if !ok {return .Not}
	mv.tmp = tmp
	caps: [2]string
	for &c, unit in caps {
		c = core.env(fmt.tprintf("VU%d_CAPTURE", unit))
		if !os.exists(c) {c = ""}
	}
	ppid := fmt.tprint(os.get_pid())
	err: os.Error
	mv.child, err = os.process_start({command = {mv.self, "--convert-vu", mv.image, mv.tmp, caps[0], caps[1], ppid}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintln("play: mid-run VU conversion: cannot start the child:", err)
		midload_vu_remove()
		return .Not
	}
	return .Started
}

// The child has ended in state: load its blob when it succeeded.
@(private = "file")
midload_vu_take :: proc(state: os.Process_State) -> Midload_Poll {
	when core.FLAT {
		return .Lost
	} else {
		defer midload_vu_remove()
		if !state.exited || state.exit_code != 0 {
			fmt.eprintfln("play: mid-run VU conversion failed (exit %d)", state.exit_code)
			return .Failed
		}
		added, known, skipped, ok := ps2.load_native_vus(mv.tmp)
		switch {
		case !ok:
		case skipped:
			if mv.skips == 0 {
				fmt.eprintln("play: mid-run VU load skipped: a new program reads status, which the stored blob's VU1 code may not keep; the next run's conversion has it")
			}
			mv.skips += 1
		case added > 0:
			mv.loads += 1
			mv.added += added
			fmt.eprintfln("play: mid-run VU load: %d microprograms (%d already loaded)", added, known)
		}
		return .Done
	}
}

@(private = "file")
midload_vu_remove :: proc() {
	midload_tmp_remove(&mv.tmp)
}

// The --convert-vu child's start, given its run's pid: on Linux it dies
// with the run, and false when the run has already ended. With COMMIT=test,
// MIDLOAD_FAIL=1 makes it fail (tests/play).
midload_child :: proc(parent: string) -> bool {
	when core.COMMIT == "test" {
		if core.env("MIDLOAD_FAIL") == "1" {
			fmt.eprintln("play: --convert-vu: failing for " + core.ENV_PREFIX + "MIDLOAD_FAIL=1")
			return false
		}
	}
	pid, ok := strconv.parse_int(parent, 10)
	if !ok {
		fmt.eprintln("play: --convert-vu: bad parent pid", parent)
		return false
	}
	if !midload_die_with(pid) {
		fmt.eprintln("play: --convert-vu: its run has ended")
		return false
	}
	return true
}
