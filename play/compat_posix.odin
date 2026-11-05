#+build !windows
package play

import "core:os"
import "core:sys/posix"
import "core:time"

// Return once pid is no longer this process's parent: an orphan is
// adopted by init or a subreaper, so its parent pid changes. pid comes from
// the environment, not a read at start, so a parent gone before the watch
// began is seen at the first check.
@(private)
parent_gone_wait :: proc(pid: int) {
	for os.get_ppid() == pid {
		time.sleep(PARENT_POLL)
	}
}

// End this process now with status, from any thread: _exit runs no exit
// handlers, which the main thread may still be using.
@(private)
parent_exit :: proc(status: int) -> ! {
	posix._exit(i32(status))
}
