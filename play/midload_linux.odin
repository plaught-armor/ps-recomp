#+build linux
package play

import "core:sys/linux"

// prctl's PR_SET_PDEATHSIG (linux/prctl.h): the signal sent to this
// process when its parent ends.
@(private = "file")
PR_SET_PDEATHSIG :: 1

// Have this process killed when its parent ends, then whether that parent
// is still pid: one gone before the signal was set has left this process
// adopted, with another parent.
@(private)
midload_die_with :: proc(pid: int) -> bool {
	_ = linux.prctl(PR_SET_PDEATHSIG, uint(linux.Signal.SIGKILL), 0, 0, 0)
	return int(linux.getppid()) == pid
}

// Whether no process has pid.
@(private)
midload_pid_gone :: proc(pid: int) -> bool {
	return linux.kill(linux.Pid(pid), linux.Signal(0)) == .ESRCH
}
