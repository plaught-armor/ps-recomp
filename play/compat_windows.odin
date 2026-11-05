#+build windows
package play

import "core:os"
import win32 "core:sys/windows"

// Return once process pid has ended. Windows does not change an orphan's
// parent pid, so this waits on a handle to the parent instead. A pid that
// cannot be opened is a parent gone. The pid could have been reused by an
// unrelated process if the parent ended before the open; that small risk
// is accepted.
@(private)
parent_gone_wait :: proc(pid: int) {
	p, err := os.process_open(pid)
	if err != nil {
		return
	}
	_, _ = os.process_wait(p)
}

// End this process now with status, from any thread, running no exit
// handlers the main thread may still be using.
@(private)
parent_exit :: proc(status: int) -> ! {
	win32.TerminateProcess(win32.GetCurrentProcess(), u32(status))
	for {}
}
