#+build windows
package main

// Windows has no SIGTERM: test_quit does not run there.
sigterm :: proc(pid: int) -> bool {
	return false
}
