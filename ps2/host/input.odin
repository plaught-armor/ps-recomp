package ps2_host

import "core:fmt"
import "core:math"
import "ps:core"
import iop "../iop"

// Called on each player's input every vblank, before netplay sends it, so a
// game can remap: say, d-pad presses that also push the stick.
pad_hook: proc(p: ^core.Net_Input) = proc(p: ^core.Net_Input) {}

// PLAYERS=n: players 1..n count as plugged in without a controller, so
// headless runs can exercise the multitap.
@(private)
forced_players: int

// Controllers, keyboard and PRESS (core input.odin) to the emulated pads:
// a controller per player, keeping its slot until unplugged; the keyboard
// feeds player 1. Motors follow the game's SetActDirect levels.
@(private)
input_poll :: proc() {
	ps := core.input_poll(u64(frame))
	inputs: [iop.MAX_PLAYERS]core.Net_Input
	for &in_, i in inputs {
		p := ps[i]
		in_.buttons = p.buttons
		for f, j in ([4]f32{p.right.x, p.right.y, p.left.x, p.left.y}) {
			in_.axes[j] = u8((i32(math.round(f * 32767)) + 32768) >> 8)
		}
		pad_hook(&in_)
	}
	// Netplay: this host's player 1 plays the session slot NET_PLAYER;
	// every pad takes the session's inputs.
	if net_on {
		got, ok := core.net_frame(vblank, inputs[0])
		if !ok {
			// Headless, the peer leaves once its last shot is taken.
			if quit_at > 0 {quit(0)}
			fmt.eprintln("net: session over")
			quit(1)
		}
		copy(inputs[:], got[:iop.MAX_PLAYERS])
	}
	for &pad, i in iop.pads {
		pad.connected = net_on ? i < NET_PLAYERS : ps[i].connected || i < forced_players
		pad.buttons = inputs[i].buttons
		pad.axes = inputs[i].axes
		core.input_rumble(i, pad.small != 0, pad.large)
	}
}
