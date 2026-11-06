// Loading the VU microprograms a PS2 run captures while it runs.
//
// With VU_CAPTURE=miss a run records the microprograms no compiled one runs
// (ps2/vu/capture.odin); the next run's conversion compiles them. Until then
// they run in the interpreter, for the whole of a first run. So while the
// game runs, once its captures have stopped growing for MIDLOAD_FRAMES
// vblanks, a child of this executable (`play --convert-vu <disc image> <out>
// <vu0> <vu1> <parent pid>`) compiles the VU microprograms of the captures
// as they are, and at a later vblank, the child done, the run loads the
// programs it has not (ps2.load_native_vus). Counting vblanks, not time,
// keeps when it starts a conversion the same from run to run; when the load
// comes depends on the child, except when the run waits for it at the
// vblank that starts it: with MIDLOAD_WAIT=1, and in a run whose output is
// compared with another's (DUMP, SHOT), so its dumps come out the same each
// time. Netplay and rollback runs (NET_PEER, SNAPTEST, RBTEST) never load
// mid-run: a peer's or a rewound frame must run the same VU code, and a
// wait mid-session would stall it. The mode is said once at the start.
//
// The child takes no capture lock and writes nothing to the disc directory:
// its blob goes to a temporary file (ps-vu-<run pid>-*.bin), removed once
// loaded, at exit and on a fatal error (core.fatal_cleanup). It compiles
// status for every program (gen.odin vu_status=all), so a program a later
// load brings never needs it kept by one of these. The startup blob may not
// keep status (ps2.load_native_vus), and a load that would bring a program
// reading status beside it is skipped, said once. A child still converting
// after MIDLOAD_DEADLINE is stopped, and a stopped or failed one counts as a
// failed load; one that cannot be waited for may still run, so none other
// starts. On Linux the child dies with the run (PR_SET_PDEATHSIG) and exits
// at once if the run is already gone, and a run removes the temporary files
// of runs that ended without removing theirs (killed, or a panic).
//
// On only for a PS2 disc with native code, capturing with VU_CAPTURE=miss
// (so never in a compat child or a FLAT build), unless VUNATIVE=0 or
// MIDLOAD=0.
package play

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"
import "ps:core"
@(require) import "ps:ps2" // used only without FLAT
@(require) import vu "ps:ps2/vu" // used only without FLAT

// The vblanks a capture stays as it is before its programs are converted.
MIDLOAD_FRAMES :: 300

// How long a conversion may take, as convert_store's would in a compat run
// (several minutes for the largest disc's whole conversion; a VU-only one
// takes seconds).
MIDLOAD_DEADLINE :: 5 * time.Minute

// The prefix of the child's temporary blob, before the run's pid.
@(private = "file")
MIDLOAD_TMP :: "ps-vu-"

@(private = "file")
Midload :: struct {
	image:   string,
	self:    string, // this executable
	wait:    bool, // MIDLOAD_WAIT=1
	child:   os.Process,
	running: bool,
	started: time.Tick, // when the child started
	stuck:   bool, // a child could not be waited for: none other starts
	tmp:     string, // the child's blob
	records: u64, // vu.vu_capture_records at the last vblank
	pending: bool, // records written since the last conversion started
	quiet:   int, // vblanks since the last record
	loads:   int, // blobs that brought programs
	added:   int, // programs they brought
	skips:   int, // loads skipped for status
	fails:   int, // conversions that failed or were stopped
}

@(private = "file")
ml: Midload

// Set up loading the captured programs mid-run for the disc image, given
// what play chose: the native blob ("" none) and VU_CAPTURE. False when it
// is off (the package comment), and the boot then hooks nothing.
midload_init :: proc(image, native, capture: string) -> bool {
	when core.FLAT {
		return false
	} else {
		if native == "" || capture != "miss" || compat_child() {return false}
		if core.env("VUNATIVE") == "0" || core.env("MIDLOAD") == "0" {return false}
		self, err := os.get_executable_path(context.allocator)
		if err != nil {
			fmt.eprintln("play: mid-run VU load off, cannot find this executable:", err)
			return false
		}
		for name in ([?]string{"NET_PEER", "SNAPTEST", "RBTEST"}) {
			if _, set := core.env_lookup(name); set {
				fmt.eprintfln("play: mid-run VU loading off (%s%s: netplay and rollback keep the VU code they start with)", core.ENV_PREFIX, name)
				return false
			}
		}
		why := ""
		for name in ([?]string{"MIDLOAD_WAIT", "DUMP", "SHOT"}) {
			v, set := core.env_lookup(name)
			if set && v != "" && (name != "MIDLOAD_WAIT" || v == "1") {
				why = name
				break
			}
		}
		ml = {image = image, self = self, wait = why != ""}
		if ml.wait {
			fmt.eprintfln("play: mid-run VU loading on, each conversion waited for (%s%s)", core.ENV_PREFIX, why)
		} else {
			fmt.eprintln("play: mid-run VU loading on, conversions in the background")
		}
		midload_sweep()
		core.fatal_cleanup = midload_cleanup
		return true
	}
}

// Boot.vblank: take a finished child's blob, then start a conversion once
// the captures have been quiet MIDLOAD_FRAMES vblanks.
midload_vblank :: proc() {
	when !core.FLAT {
		if ml.stuck {return}
		if ml.running {midload_poll(0)}
		if r := vu.vu_capture_records(); r != ml.records {
			ml.records = r
			ml.pending = true
			ml.quiet = 0
			return
		}
		ml.quiet += 1
		if !ml.pending || ml.running || ml.quiet < MIDLOAD_FRAMES {return}
		ml.pending = false
		midload_start()
		if ml.running && ml.wait {midload_poll(MIDLOAD_DEADLINE)}
	}
}

// Boot.quit: stop a child still converting, remove its blob, and say what
// was loaded.
midload_quit :: proc() {
	core.fatal_cleanup = nil
	midload_cleanup()
	fmt.eprintfln("play: mid-run VU loads: %d (%d microprograms), %d skipped for status, %d failed", ml.loads, ml.added, ml.skips, ml.fails)
}

// Stop a child still converting and remove its blob: at quit, and on a
// fatal error (core.fatal_cleanup).
@(private = "file")
midload_cleanup :: proc() {
	if ml.running {midload_stop()}
	midload_remove()
}

// Wait up to timeout for the child: take its blob when it has ended; stop
// it when it has run past MIDLOAD_DEADLINE or cannot be waited for, a
// failed load.
@(private = "file")
midload_poll :: proc(timeout: time.Duration) {
	when !core.FLAT {
		state, err := os.process_wait(ml.child, timeout)
		switch {
		case err == nil:
			midload_take(state)
			return
		case err == os.General_Error.Timeout:
			if time.tick_since(ml.started) < MIDLOAD_DEADLINE {return}
			fmt.eprintfln("play: mid-run VU conversion took over %.0f s, stopped", time.duration_seconds(MIDLOAD_DEADLINE))
		case:
			fmt.eprintln("play: mid-run VU conversion: cannot wait for the child:", err)
		}
		midload_stop()
		midload_remove()
		ml.fails += 1
	}
}

// Kill the child and wait for it to end. One that cannot be waited for may
// still run, so no other starts (stuck).
@(private = "file")
midload_stop :: proc() {
	ml.running = false
	_ = os.process_kill(ml.child)
	if _, err := os.process_wait(ml.child); err != nil {
		ml.stuck = true
		fmt.eprintln("play: mid-run VU loading off: a conversion child cannot be waited for:", err)
	}
}

// Start the child converting the captures into a new temporary file.
@(private = "file")
midload_start :: proc() {
	f, err := os.create_temp_file("", fmt.tprintf("%s%d-*.bin", MIDLOAD_TMP, os.get_pid()))
	if err != nil {
		fmt.eprintln("play: mid-run VU conversion: no temporary file:", err)
		return
	}
	ml.tmp = strings.clone(os.name(f))
	_ = os.close(f)
	caps: [2]string
	for &c, unit in caps {
		c = core.env(fmt.tprintf("VU%d_CAPTURE", unit))
		if !os.exists(c) {c = ""}
	}
	ppid := fmt.tprint(os.get_pid())
	ml.child, err = os.process_start({command = {ml.self, "--convert-vu", ml.image, ml.tmp, caps[0], caps[1], ppid}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintln("play: mid-run VU conversion: cannot start the child:", err)
		midload_remove()
		return
	}
	ml.running = true
	ml.started = time.tick_now()
}

// The child has ended in state: load its blob when it succeeded.
@(private = "file")
midload_take :: proc(state: os.Process_State) {
	when !core.FLAT {
		ml.running = false
		defer midload_remove()
		if !state.exited || state.exit_code != 0 {
			fmt.eprintfln("play: mid-run VU conversion failed (exit %d)", state.exit_code)
			ml.fails += 1
			return
		}
		added, known, skipped, ok := ps2.load_native_vus(ml.tmp)
		switch {
		case !ok:
		case skipped:
			if ml.skips == 0 {
				fmt.eprintln("play: mid-run VU load skipped: a new program reads status, which the stored blob's VU1 code may not keep; the next run's conversion has it")
			}
			ml.skips += 1
		case added > 0:
			ml.loads += 1
			ml.added += added
			fmt.eprintfln("play: mid-run VU load: %d microprograms (%d already loaded)", added, known)
		}
	}
}

@(private = "file")
midload_remove :: proc() {
	if ml.tmp == "" {return}
	_ = os.remove(ml.tmp)
	delete(ml.tmp)
	ml.tmp = ""
}

// Remove the temporary blobs of runs that have ended (killed, or a panic,
// before they removed theirs): those named for a pid no process has, last
// written before this run started.
@(private = "file")
midload_sweep :: proc() {
	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil {return}
	fis, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	start, self := time.now(), os.get_pid()
	for fi in fis {
		if !strings.has_prefix(fi.name, MIDLOAD_TMP) {continue}
		pid, _, _ := strings.partition(fi.name[len(MIDLOAD_TMP):], "-")
		n, ok := strconv.parse_int(pid, 10)
		if !ok || n == self || time.diff(fi.modification_time, start) <= 0 || !midload_pid_gone(n) {continue}
		_ = os.remove(fi.fullpath)
	}
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
