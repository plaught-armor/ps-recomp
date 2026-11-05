#+build windows
package main

import "core:os"

// Windows has no SIGTERM: test_quit does not run there.
sigterm :: proc(pid: int) -> bool {
	return false
}

// How test_orphan stops a compat parent: Windows has no signals.
Stop :: enum {
	Terminate,
}

STOPS :: [?]Stop{.Terminate}

// Stop process p (TerminateProcess); whether it was stopped.
stop :: proc(p: os.Process, how: Stop) -> bool {
	return os.process_kill(p) == nil
}

// Whether process pid is still running. core:os has no public close: a
// wait that sees the process ended closes the handle, one that times out
// leaves it open until the test exits.
alive :: proc(pid: int) -> bool {
	p, err := os.process_open(pid)
	if err != nil {
		return false
	}
	_, werr := os.process_wait(p, 0)
	return werr == os.General_Error.Timeout
}
