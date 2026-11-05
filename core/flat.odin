// FLAT: every console thread runs on the flat interpreters, which keep the
// guest pc and a shadow return stack per thread in emulated memory instead
// of host call frames. A thread switch is then a swap of that state, so no
// coroutine (host stack) is needed. No recompiled or learned code runs, and
// LEARN records nothing.
//
// On by default on wasi, where host stacks cannot be switched or copied. A
// native build with -define:PS_FLAT=true is the test build: its runs must
// match a default build's NATIVE=0 runs.
package core

FLAT :: #config(PS_FLAT, ODIN_OS == .WASI)
