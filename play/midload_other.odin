#+build !linux
package play

// Outside Linux a child is not tied to its run's life: it ends with its
// conversion, or when the run stops it (midload.odin).
@(private)
midload_die_with :: proc(pid: int) -> bool {
	return true
}

// Unknown outside Linux, so no temporary file of another run is removed.
@(private)
midload_pid_gone :: proc(pid: int) -> bool {
	return false
}
