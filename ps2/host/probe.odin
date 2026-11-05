// Probes of input under COMPAT (core/compat.odin, PS_COMPAT_PROBE): at a
// quiet sample the probe saves state, then runs a branch per
// core.COMPAT_PROBE_BUTTONS entry from it, each core.COMPAT_PROBE_RUN
// vblanks long with player 1 pressing its button for the first
// core.COMPAT_PROBE_HOLD, loading the state back after each; the last load
// puts the run back where it was, and it goes on as if no branch ran.
//
// A branch is emulated as usual but leaves no trace outside the state it
// loads back: it presents, dumps, shoots, samples and paces nothing, and
// pushes no sound; compat counts nothing, learn notes nothing and card
// writes stay in memory (core.compat_probe_begin); the GS display tracking,
// host state, is set back after each. Off with SNAPTEST, RBTEST or netplay, which use
// snapshots of their own.
package ps2_host

import "ps:core"
import gs "../gs"
import iop "../iop"
import mem "../mem"

// Below core.RB_HOOK_ID, apart from SNAPTEST's 0: the GS keeps a GPU copy
// per id.
@(private = "file")
PROBE_SNAP_ID :: 2

@(private = "file")
BUTTONS :: core.COMPAT_PROBE_BUTTONS

@(private = "file")
probe: struct {
	snap:    core.Snapshot,
	// The branch running (-1: none), the sample vblank the probe began at,
	// main RAM at the end of the branch that pressed nothing, and each other
	// branch's bytes of RAM different from it.
	branch:  int,
	at:      int,
	none:    []u8,
	changed: [len(BUTTONS) - 1]int,
	display: gs.Display_Track,
	ending:  bool, // the last load puts the run back
}

@(private)
probe_init :: proc() {
	probe.branch = -1
	probe.snap.id = PROBE_SNAP_ID
	append(&core.snap_hooks, core.Snap_Hook{probe_saved, probe_loaded})
}

// After compat_sample at vblank: start a probe when one is due.
@(private)
probe_maybe :: proc() {
	if snaptest != {} || rbtest[1] > 0 || net_on || core.snap_op != .None {return}
	if !core.compat_probe_due(u64(vblank)) {return}
	probe.branch, probe.at = 0, vblank
	core.snap_op, core.snap_target = .Save, &probe.snap
}

// Whether a branch runs this vblank.
@(private)
probe_running :: proc() -> bool {
	return probe.branch >= 0
}

@(private = "file")
probe_saved :: proc(id: int) {
	if id != PROBE_SNAP_ID {return}
	core.compat_probe_begin()
	probe.display = gs.display_track_get()
}

@(private = "file")
probe_loaded :: proc(id: int) {
	if id != PROBE_SNAP_ID {return}
	gs.display_track_set(probe.display)
	if probe.ending {
		probe.ending = false
		core.compat_probe_end(u64(probe.at), probe.changed[:])
	}
}

// Every pad: nothing pressed, sticks centred; player 1 holds the branch's
// button for its first COMPAT_PROBE_HOLD vblanks.
@(private)
probe_input :: proc() {
	for &pad in iop.pads {
		pad.buttons, pad.axes = {}, {128, 128, 128, 128}
	}
	buttons := BUTTONS
	if vblank - probe.at <= core.COMPAT_PROBE_HOLD {iop.pads[0].buttons = buttons[probe.branch]}
}

// A branch's vblank, its picture w x h: at its last, compare main RAM and
// load the saved state back for the next branch, or to go on.
@(private)
probe_frame :: proc(w, h: int) {
	if w > 0 && h > 0 {frame += 1}
	core.compat_probe_beat()
	if vblank - probe.at < core.COMPAT_PROBE_RUN {return}
	if probe.branch == 0 {
		if probe.none == nil {probe.none = make([]u8, len(mem.ram), core.host_allocator)}
		copy(probe.none, mem.ram)
	} else {
		probe.changed[probe.branch - 1] = core.compat_bytes_differ(probe.none, mem.ram)
	}
	probe.branch += 1
	if probe.branch == len(BUTTONS) {
		probe.branch, probe.ending = -1, true
	}
	core.snap_op, core.snap_target = .Load, &probe.snap
}
