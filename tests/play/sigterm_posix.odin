#+build !windows
package main

import "core:os"
import "core:sys/posix"

// Send process pid SIGTERM; whether it was sent.
sigterm :: proc(pid: int) -> bool {
	return posix.kill(posix.pid_t(pid), .SIGTERM) == .OK
}

// How test_orphan stops a compat parent.
Stop :: enum {
	Sigterm,
	Sigkill,
}

STOPS :: [?]Stop{.Sigterm, .Sigkill}

// Stop process p as how says; whether the signal was sent.
stop :: proc(p: os.Process, how: Stop) -> bool {
	return posix.kill(posix.pid_t(p.pid), .SIGTERM if how == .Sigterm else .SIGKILL) == .OK
}

// Whether process pid exists (one not reaped yet included).
alive :: proc(pid: int) -> bool {
	return posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK
}
