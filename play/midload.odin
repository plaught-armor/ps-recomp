// Loading code a run makes while it runs: one job per run, the PS2's VU
// microprograms on a native build (midload_vu.odin) or a PS1 game's learned
// functions (midload_learned.odin). This file is the policy both
// share; each job has only its own start and done steps.
//
// Once what the job loads from (the VU captures, the LEARN records) has
// stopped growing for MIDLOAD_FRAMES vblanks, the job starts making code
// from it as it is, and at a later vblank, the job done, the run loads what
// it made. Counting vblanks, not time, keeps when a job starts the same from
// run to run; when the load comes depends on the job, except when the run
// waits for it at the vblank that starts it: with MIDLOAD_WAIT=1, and in a
// run whose output is compared with another's (DUMP, SHOT), so its dumps
// come out the same each time. Netplay and rollback runs (NET_PEER,
// SNAPTEST, RBTEST) never load mid-run: a peer's or a rewound frame must run
// the same code, and a wait mid-session would stall it. MIDLOAD=0 turns it
// off. The mode is said once at the start.
//
// One job is in flight at most. One still running after MIDLOAD_DEADLINE
// is stopped, and a stopped or failed one counts as a failed load; one that
// cannot be stopped or waited for may still run, so none other starts.
package play

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "ps:core"

// The vblanks what a job loads from stays as it is before it starts.
MIDLOAD_FRAMES :: 300

// How long a job may take, as convert_store's would in a compat run
// (several minutes for the largest disc's whole conversion; a VU-only one
// takes seconds).
MIDLOAD_DEADLINE :: 5 * time.Minute

// How a job's start went.
@(private)
Midload_Start :: enum {
	Started,
	Not, // nothing to do, or a failure it said; a later vblank may start
	Off, // it never can (said); none other starts
}

// How a job stands at a poll.
@(private)
Midload_Poll :: enum {
	Running,
	Done, // ended, and what it made taken (loaded or not)
	Failed, // ended without code to load (said)
	Lost, // cannot be waited for (said)
}

// A job: what it is called in the messages ("VU" and its "conversion"), and
// its steps. grown: a count that grows with what it loads from. poll: wait
// up to timeout for the job, taking what it made when it has ended. stop:
// end a running job (false: it may still run, said unless quit). cleanup:
// what it leaves (at quit, on a fatal error, after a stop). report: the
// quit line, given the failed loads.
@(private)
Midload_Job :: struct {
	what, noun: string,
	grown:      proc() -> u64,
	start:      proc() -> Midload_Start,
	poll:       proc(timeout: time.Duration) -> Midload_Poll,
	stop:       proc(quit: bool) -> bool,
	cleanup:    proc(),
	report:     proc(fails: int),
}

@(private = "file")
Midload :: struct {
	job:     Midload_Job,
	wait:    bool, // MIDLOAD_WAIT=1, DUMP or SHOT
	running: bool,
	started: time.Tick, // when the job started
	stuck:   bool, // a job could not be stopped or waited for, or none can start: none other starts
	count:   u64, // job.grown() at the last vblank
	pending: bool, // grown since the last job started
	quiet:   int, // vblanks since it last grew
	fails:   int, // jobs that failed or were stopped
	vblanks: u64, // vblanks since boot, for the log
}

@(private = "file")
ml: Midload

// Whether MIDLOAD=0 turns mid-run loading off.
@(private)
midload_off :: proc() -> bool {
	return core.env("MIDLOAD") == "0"
}

// Take on job for the run, unless netplay or rollback runs: false then,
// after a message, and the boot hooks nothing. Says the mode.
@(private)
midload_begin :: proc(job: Midload_Job) -> bool {
	for name in ([?]string{"NET_PEER", "SNAPTEST", "RBTEST"}) {
		if _, set := core.env_lookup(name); set {
			fmt.eprintfln("play: mid-run %s loading off (%s%s: netplay and rollback keep the %s code they start with)", job.what, core.ENV_PREFIX, name, job.what)
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
	ml = {job = job, wait = why != ""}
	if ml.wait {
		fmt.eprintfln("play: mid-run %s loading on, each %s waited for (%s%s)", job.what, job.noun, core.ENV_PREFIX, why)
	} else {
		fmt.eprintfln("play: mid-run %s loading on, %ss in the background", job.what, job.noun)
	}
	core.fatal_cleanup = midload_cleanup
	return true
}

// Boot.vblank: take a finished job's code, then start a job once what it
// loads from has been quiet MIDLOAD_FRAMES vblanks.
midload_vblank :: proc() {
	ml.vblanks += 1
	if ml.stuck {return}
	if ml.running {midload_poll(0)}
	if n := ml.job.grown(); n != ml.count {
		ml.count = n
		ml.pending = true
		ml.quiet = 0
		return
	}
	ml.quiet += 1
	if !ml.pending || ml.running || ml.quiet < MIDLOAD_FRAMES {return}
	ml.pending = false
	switch ml.job.start() {
	case .Started:
		ml.running = true
		ml.started = time.tick_now()
		if ml.wait {midload_poll(MIDLOAD_DEADLINE)}
	case .Not:
	case .Off:
		ml.stuck = true
	}
}

// Boot.quit: stop a job still running, clean up after it, and say what was
// loaded.
midload_quit :: proc() {
	core.fatal_cleanup = nil
	midload_end(true)
	ml.job.report(ml.fails)
}

// midload_end at a fatal error (core.fatal_cleanup).
@(private = "file")
midload_cleanup :: proc() {
	midload_end(true)
}

@(private = "file")
midload_end :: proc(quit: bool) {
	if ml.running {midload_stop(quit)}
	ml.job.cleanup()
}

// Poll the job for up to timeout; stop it when it has run past
// MIDLOAD_DEADLINE or cannot be waited for, a failed load.
@(private = "file")
midload_poll :: proc(timeout: time.Duration) {
	switch ml.job.poll(timeout) {
	case .Running:
		if time.tick_since(ml.started) < MIDLOAD_DEADLINE {return}
		fmt.eprintfln("play: mid-run %s %s took over %.0f s, stopped", ml.job.what, ml.job.noun, time.duration_seconds(MIDLOAD_DEADLINE))
	case .Done:
		ml.running = false
		fmt.eprintfln("play: mid-run %s %s done at vblank %d", ml.job.what, ml.job.noun, ml.vblanks)
		return
	case .Failed:
		ml.running = false
		ml.fails += 1
		return
	case .Lost:
	}
	midload_end(false)
	ml.fails += 1
}

// End the running job. One that may still run lets no other start (stuck).
@(private = "file")
midload_stop :: proc(quit: bool) {
	ml.running = false
	if !ml.job.stop(quit) {ml.stuck = true}
}

// A job's temporary file in the temporary directory, named for its prefix
// (one per job, such as "ps-vu-") and this run's pid, with the extension
// ext: <prefix><pid>-<random><ext>. Allocated; false after a message, which
// names the job's step. midload_tmp_sweep removes the ones a run that ended
// left.
@(private)
midload_tmp :: proc(prefix, ext, step: string) -> (string, bool) {
	f, err := os.create_temp_file("", fmt.tprintf("%s%d-*%s", prefix, os.get_pid(), ext))
	if err != nil {
		fmt.eprintfln("play: mid-run %s: no temporary file: %v", step, err)
		return "", false
	}
	path := strings.clone(os.name(f))
	_ = os.close(f)
	return path, true
}

// Remove the temporary file at path^ (midload_tmp), if any, and forget it.
@(private)
midload_tmp_remove :: proc(path: ^string) {
	if path^ == "" {return}
	_ = os.remove(path^)
	delete(path^)
	path^ = ""
}

// Remove the temporary files with prefix of runs that have ended (killed,
// or a panic, before they removed theirs): those named for a pid no
// process has, last written before this run started.
@(private)
midload_tmp_sweep :: proc(prefix: string) {
	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil {return}
	fis, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	start, self := time.now(), os.get_pid()
	for fi in fis {
		if !strings.has_prefix(fi.name, prefix) {continue}
		pid, _, _ := strings.partition(fi.name[len(prefix):], "-")
		n, ok := strconv.parse_int(pid, 10)
		if !ok || n == self || time.diff(fi.modification_time, start) <= 0 || !midload_pid_gone(n) {continue}
		_ = os.remove(fi.fullpath)
	}
}

// How a job's child that failed ended, for its message: "exit N", or
// "killed" when it did not exit. On Linux core:os reports a child killed by
// a signal as exited, with the signal's number as N.
@(private)
midload_ended :: proc(state: os.Process_State) -> string {
	if !state.exited {return "killed"}
	return fmt.tprintf("exit %d", state.exit_code)
}

// The start of a job's child (mode, such as "--convert-vu"), given its
// run's pid: on Linux it dies with the run, and false when the run has
// already ended. With COMMIT=test, MIDLOAD_FAIL=1 makes it fail (tests/play).
midload_child :: proc(mode, parent: string) -> bool {
	when core.COMMIT == "test" {
		if core.env("MIDLOAD_FAIL") == "1" {
			fmt.eprintfln("play: %s: failing for %sMIDLOAD_FAIL=1", mode, core.ENV_PREFIX)
			return false
		}
	}
	pid, ok := strconv.parse_int(parent, 10)
	if !ok {
		fmt.eprintfln("play: %s: bad parent pid %s", mode, parent)
		return false
	}
	if !midload_die_with(pid) {
		fmt.eprintfln("play: %s: its run has ended", mode)
		return false
	}
	return true
}
