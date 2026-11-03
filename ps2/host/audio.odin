// Host audio (ps:core audio.odin): the FMOD, SPU2 and ADX mixers fill one
// vblank of sound, 800 or 801 samples (iop.vblank_samples), which core
// queues on the SDL device. WAV=<file> also records the mix, for headless
// checks; core keeps the file valid at every second, since a timed-out run
// never exits cleanly.
package ps2_host

import "ps:core"
import cpu "../cpu"
import iop "../iop"

@(private)
LATENCY_MS :: 50

@(private)
audio_init :: proc(headless: bool) {
	wav, _ := core.env_lookup("WAV")
	// Headless runs are unpaced: a device queue would drop the mix.
	core.audio_init(iop.MIX_RATE, wav, !headless)
	if !headless {core.audio_apply(LATENCY_MS)}
}

// Mix exactly vblank v (from 1): the game polls voice positions, so how far
// the voices advance must not depend on the host. Its length follows the
// input clock, 800.8 samples a vblank on average, so the mix does not fall
// behind the voices the IOP's clock reads. Core pads or drops on the device
// side instead. A netplay rerun mixes without pushing.
@(private)
audio_frame :: proc(v: int, push: bool) {
	n := iop.vblank_samples(u64(v))
	buf := make([][2]i16, n, context.temp_allocator)
	t := cpu.prof_start()
	mix_frame(([^]i16)(raw_data(buf))[:n * 2])
	cpu.prof_end(.MIX, t)
	if push {core.audio_push(buf)}
}

// The sources add into one wide buffer, saturated once into out, so a source
// that cancels another does not leave a clipped residue.
mix_frame :: proc(out: []i16) {
	acc := make([]i32, len(out), context.temp_allocator)
	iop.fmod_mix(acc)
	iop.spu_mix(acc) // CRI ADX streams play through an SPU2 core
	for x, i in acc {out[i] = i16(clamp(x, -32768, 32767))}
}
