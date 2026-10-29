// Host audio: the console's mixed sound queued to an SDL device, and an
// optional WAV copy of it.
//
// The console mixes at its own fixed rate, in step with emulated time
// (exactly one frame's worth per frame, or one batch per batch event), and
// hands every batch to audio_push. How far its voices advance must never
// depend on the host: everything here sits after the mix and feeds nothing
// back. On the way to the device:
// - the queue is kept at a target set by the latency setting; up to
//   AUDIO_RATE_MAX faster or slower playback (cubic resampling) absorbs
//   drift between the emulated clock and the sound card's;
// - below speed 1 the sound is stretched to fill real time, playing lower
//   and slower in step with the picture;
// - a queue past the target plus two frames of slack drops the batch, and
//   one that ran dry is refilled with silence to the target at once, or the
//   rate correction would take seconds and every frame would click.
package core

import "core:fmt"
import "core:os"
import sdl "vendor:sdl2"

// Range of the output latency setting, in ms: queued sound plus the device's
// own buffer.
AUDIO_LATENCY_MIN :: 20
AUDIO_LATENCY_MAX :: 250

// Largest playback rate correction that keeps the queue at its target: 0.5%,
// about 9 cents of pitch.
AUDIO_RATE_MAX :: 0.005

// Slowest emulated speed audio_push stretches for.
AUDIO_MIN_SPEED :: 0.25

// Batches are resampled this many input frames at a time.
@(private = "file")
AUDIO_CHUNK :: 256

// One chunk stretched for the slowest speed, plus one frame for the rate
// correction and one for the fractional frame a stretch carries over.
@(private = "file")
AUDIO_STRETCH_MAX :: int(AUDIO_CHUNK / AUDIO_MIN_SPEED) + 2

Audio_Pace :: enum {
	// Real time: keep the queue at its target.
	Paced,
	// Fast-forward: drop batches from the target on, so the queue is not
	// left long when pacing resumes.
	Fast,
	// Unpaced or skipping: queue nothing (it would only be dropped).
	Off,
}

// Counted since the last audio_take_stats, for the game's .Perf report.
Audio_Stats :: struct {
	// Frames mixed: over the emulated time run, they should come to the mix
	// rate, which the host can only correct AUDIO_RATE_MAX off.
	mixed:   int,
	// Times the queue ran dry, and batches dropped for a queue over target.
	dry:     int,
	dropped: int,
	// The lowest the queue was when a batch came, in ms (0 with none).
	low_ms:  f64,
}

audio: struct {
	rate:         int,
	dev:          sdl.AudioDeviceID,
	// The audio subsystem started; audio_apply opens the device.
	ok:           bool,
	// Frames to keep in the queue, from the latency setting.
	target:       int,
	stats:        Audio_Stats,
	low:          int,
	// Resampling state: output position within the chunk being read (in
	// input frames), and the last three input frames of the previous chunk,
	// oldest first.
	stretch_pos:  f64,
	stretch_prev: [3][2]i16,
	stretch_buf:  [AUDIO_STRETCH_MAX][2]i16,
	silence:      [1024][2]i16,
	dump:         ^os.File,
	dump_bytes:   int,
}

// Start audio at the console's mix rate. With `device` false (headless
// runs) no device is opened. `dump` names a WAV file that receives
// everything mixed, valid at every second of sound so a killed run still
// leaves a readable file; one that cannot be created is an error. A missing
// device only leaves the game silent.
audio_init :: proc(rate: int, dump := "", device := true) -> bool {
	audio.rate = rate
	audio.low = max(int)
	if dump != "" {
		f, err := os.create(dump)
		if err != nil {
			fmt.eprintln("audio dump: cannot create", dump, err)
			return false
		}
		audio.dump = f
		audio_wav_header()
	}
	if !device {
		return true
	}
	if sdl.InitSubSystem({.AUDIO}) != 0 {
		fmt.eprintln("audio disabled: SDL_InitSubSystem:", sdl.GetError())
		return true
	}
	audio.ok = true
	return true
}

// Open the output device for about `latency_ms` from a sound being mixed to
// it reaching the speakers (plus whatever the OS mixer adds). The device
// buffer takes about a quarter of it, as a power of two of 256 frames or
// more; the queue is kept at the rest.
audio_apply :: proc(latency_ms: int) {
	assert(latency_ms >= AUDIO_LATENCY_MIN && latency_ms <= AUDIO_LATENCY_MAX)
	total := audio.rate * latency_ms / 1000
	samples := 256
	for samples * 2 <= total / 4 && samples < 4096 {
		samples *= 2
	}
	audio.target = total - samples
	if !audio.ok {
		return
	}
	if audio.dev != 0 {
		sdl.CloseAudioDevice(audio.dev)
	}
	want := sdl.AudioSpec {
		freq     = i32(audio.rate),
		format   = sdl.AUDIO_S16LSB,
		channels = 2,
		samples  = u16(samples),
	}
	audio.dev = sdl.OpenAudioDevice(nil, false, &want, nil, {})
	if audio.dev == 0 {
		fmt.eprintln("audio disabled: SDL_OpenAudioDevice:", sdl.GetError())
		return
	}
	sdl.PauseAudioDevice(audio.dev, false)
}

// A batch of mixed sound, at emulated speed `speed`.
audio_push :: proc(frames: [][2]i16, speed: f64 = 1, pace: Audio_Pace = .Paced) {
	audio.stats.mixed += len(frames)
	audio_dump(frames)
	if audio.dev == 0 || pace == .Off {
		return
	}
	queued := int(sdl.GetQueuedAudioSize(audio.dev)) / size_of([2]i16)
	audio.low = min(audio.low, queued)
	// Queue beyond the target before batches are dropped: two frames of
	// sound at 60 Hz. Paced emulation makes a frame's sound in one burst, so
	// the queue swings by one frame; it outgrows this only while emulation
	// runs ahead.
	slack := pace == .Fast ? 0 : audio.rate * 2 / 60
	if queued > audio.target + slack {
		if pace != .Fast {
			audio.stats.dropped += 1
		}
		return
	}
	if queued == 0 {
		audio.stats.dry += 1
		if .Perf in trace.active {
			tracef(.Perf, "audio ran dry")
		}
		for n := audio.target; n > 0; n -= len(audio.silence) {
			audio_queue(audio.silence[:min(n, len(audio.silence))])
		}
	}
	// Input frames per output frame.
	error := f64(queued - audio.target) / f64(max(audio.target, 1))
	step := min(speed, 1) * (1 + AUDIO_RATE_MAX * clamp(error, -1, 1))
	for i := 0; i < len(frames); i += AUDIO_CHUNK {
		audio_queue(audio_resample(frames[i:][:min(AUDIO_CHUNK, len(frames) - i)], step))
	}
}

// Sound waiting in the queue.
audio_queued_ms :: proc() -> f64 {
	if audio.dev == 0 {
		return 0
	}
	return f64(sdl.GetQueuedAudioSize(audio.dev) / size_of([2]i16)) * 1000 / f64(audio.rate)
}

// The counts since the last call, which starts them again.
audio_take_stats :: proc() -> Audio_Stats {
	s := audio.stats
	s.low_ms = audio.low == max(int) ? 0 : f64(audio.low) * 1000 / f64(audio.rate)
	audio.stats = {}
	audio.low = max(int)
	return s
}

// Finish the dump.
audio_close :: proc() {
	if audio.dump != nil {
		audio_wav_header()
		os.close(audio.dump)
		audio.dump = nil
	}
}

@(private = "file")
audio_queue :: proc(frames: [][2]i16) {
	bytes := len(frames) * size_of([2]i16)
	if sdl.QueueAudio(audio.dev, raw_data(frames), u32(bytes)) != 0 {
		fmt.eprintln("audio disabled: SDL_QueueAudio:", sdl.GetError())
		sdl.CloseAudioDevice(audio.dev)
		audio.dev = 0
	}
}

// Resample up to AUDIO_CHUNK frames to 1/step times their length by cubic
// (Catmull-Rom) interpolation, one frame behind so the frame after each
// interpolated pair is always at hand. Linear interpolation is a lowpass
// wherever the fraction sits near one half, and at a step this close to 1 it
// sits there for seconds: about 3 dB down at 12 kHz, 6 dB at 16 kHz. The
// previous chunk's last three frames join the two.
@(private = "file")
audio_resample :: proc(frames: [][2]i16, step: f64) -> [][2]i16 {
	assert(len(frames) <= AUDIO_CHUNK && step >= AUDIO_MIN_SPEED * (1 - AUDIO_RATE_MAX))
	// Frame k of the chunk, or of the previous one for k in -3 ..< 0.
	at :: proc(frames: [][2]i16, k: int) -> [2]i16 {
		return k < 0 ? audio.stretch_prev[3 + k] : frames[k]
	}
	n := 0
	for audio.stretch_pos < f64(len(frames)) && n < AUDIO_STRETCH_MAX {
		i := int(audio.stretch_pos)
		t := audio.stretch_pos - f64(i)
		f0, f1, f2, f3 := at(frames, i - 3), at(frames, i - 2), at(frames, i - 1), frames[i]
		for c in 0 ..< 2 {
			p0, p1, p2, p3 := f64(f0[c]), f64(f1[c]), f64(f2[c]), f64(f3[c])
			y := p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
			audio.stretch_buf[n][c] = i16(clamp(y, -32768, 32767))
		}
		n += 1
		audio.stretch_pos += step
	}
	audio.stretch_pos -= f64(len(frames))
	for k in 0 ..< 3 {
		audio.stretch_prev[k] = at(frames, len(frames) - 3 + k)
	}
	return audio.stretch_buf[:n]
}

@(private = "file")
audio_dump :: proc(frames: [][2]i16) {
	if audio.dump == nil {
		return
	}
	bytes := len(frames) * size_of([2]i16)
	if _, err := os.write_at(audio.dump, ([^]u8)(raw_data(frames))[:bytes], i64(44 + audio.dump_bytes)); err != nil {
		fmt.eprintln("audio dump: write failed:", err)
		os.close(audio.dump)
		audio.dump = nil
		return
	}
	second := audio.rate * size_of([2]i16)
	before := audio.dump_bytes / second
	audio.dump_bytes += bytes
	if audio.dump_bytes / second != before {
		audio_wav_header()
	}
}

// The 44-byte header for the sound written so far: 16-bit PCM stereo.
@(private = "file")
audio_wav_header :: proc() {
	data := u32(audio.dump_bytes)
	hdr := [11]u32 {
		0x46464952, // "RIFF"
		36 + data,
		0x45564157, // "WAVE"
		0x20746d66, // "fmt "
		16,
		1 | 2 << 16, // PCM, stereo
		u32(audio.rate),
		u32(audio.rate) * 4,
		4 | 16 << 16, // block align, bits per sample
		0x61746164, // "data"
		data,
	}
	if _, err := os.write_at(audio.dump, ([^]u8)(&hdr)[:44], 0); err != nil {
		fmt.eprintln("audio dump: header write failed:", err)
	}
}
