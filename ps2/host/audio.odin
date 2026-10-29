// Host audio (ps:core audio.odin): the FMOD and SPU2 voice mixers fill one
// vblank of sound, which core queues on the SDL device. WAV=<file> also
// records the mix, for headless checks; core keeps the file valid at every
// second, since a timed-out run never exits cleanly.
package ps2_host

import "ps:core"
import cpu "../cpu"
import iop "../iop"

@(private)
AUDIO_FRAME :: iop.MIX_RATE / 60 // stereo frames per vblank
@(private)
LATENCY_MS :: 50

@(private)
audio_init :: proc(headless: bool) {
	wav, _ := core.env_lookup("WAV")
	// Headless runs are unpaced: a device queue would drop the mix.
	core.audio_init(iop.MIX_RATE, wav, !headless)
	if !headless {core.audio_apply(LATENCY_MS)}
}

// Mix exactly one vblank: the game polls voice positions, so how far the
// voices advance must not depend on the host. Core pads or drops on the
// device side instead. A netplay rerun mixes without pushing.
@(private)
audio_frame :: proc(push: bool) {
	buf := make([][2]i16, AUDIO_FRAME, context.temp_allocator)
	t := cpu.prof_start()
	iop.fmod_mix(([^]i16)(raw_data(buf))[:AUDIO_FRAME * 2])
	iop.spu_mix(([^]i16)(raw_data(buf))[:AUDIO_FRAME * 2])
	cpu.prof_end(.MIX, t)
	if push {core.audio_push(buf)}
}
