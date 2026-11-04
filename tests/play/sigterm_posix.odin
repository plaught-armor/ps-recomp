#+build !windows
package main

import "core:sys/posix"

// Send process pid SIGTERM; whether it was sent.
sigterm :: proc(pid: int) -> bool {
	return posix.kill(posix.pid_t(pid), .SIGTERM) == .OK
}
