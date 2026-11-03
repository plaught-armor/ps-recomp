// core.audio_step against a modelled queue: emulated time 0.305% fast (a
// 59.817 Hz console locked to a 60 Hz display) is learnt as drift, with
// the queue back at its target and the step never past AUDIO_RATE_MAX.
// Drift holds over a stall that empties the queue and the second after it,
// with the queue under a quarter of its target, while settle runs (set here
// by hand, as audio_settle and a slow host set it), off speed 1, and while
// the step is saturated, so it does not overshoot once the error is gone.
package main

import "core:fmt"
import "core:os"
import "ps:core"

@(private = "file")
RATE :: 44100
@(private = "file")
TARGET :: 1693
@(private = "file")
BATCH :: 32

// The queue at the end of each modelled vblank: `mixed` frames pushed in
// batches, `played` taken by the device.
@(private = "file")
Model :: struct {
	queued: f64,
	ctl:    core.Audio_Rate,
	frac:   f64, // mixed frames owed to the next vblank
	worst:  f64, // largest |step - 1| seen
}

@(private = "file")
model_vblank :: proc(m: ^Model, mixed, played: f64, speed: f64) {
	m.frac += mixed
	left := int(m.frac)
	m.frac -= f64(left)
	for left > 0 {
		n := min(BATCH, left)
		left -= n
		step := core.audio_step(&m.ctl, int(m.queued), TARGET, n, RATE, speed)
		m.worst = max(m.worst, abs(step / min(speed, 1) - 1))
		m.queued += f64(n) / step
	}
	m.queued = max(m.queued - played, 0)
}

@(private = "file")
audio_fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL audio_step: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

test_audio_step :: proc() {
	// 59.817 Hz fields shown at 60 Hz: each real 1/60 s mixes a field.
	mixed := f64(RATE) / 59.817
	played := f64(RATE) / 60
	// The playback speed-up that holds the queue: mixed over played.
	want := mixed / played - 1
	m := Model{queued = TARGET}
	for _ in 0 ..< 120 * 60 {
		model_vblank(&m, mixed, played, 1)
	}
	if abs(m.ctl.drift - want) > 0.0001 {
		audio_fail("drift %.5f after 120 s, want %.5f", m.ctl.drift, want)
	}
	// The batches see the queue between empty of this vblank's sound and
	// full of it: half a vblank's sound over the queue after play.
	if abs(m.queued + mixed / 2 - TARGET) > TARGET / 10 {
		audio_fail("queue %.0f mid-vblank after 120 s, want about %d", m.queued + mixed / 2, TARGET)
	}
	if m.worst > core.AUDIO_RATE_MAX + 1e-12 {
		audio_fail("step %.5f off 1, past AUDIO_RATE_MAX", m.worst)
	}
	settled := m.ctl.drift
	// A 5 s stall: the queue runs dry each vblank (each vblank's sound
	// finds it empty). It comes back half full: the settle second after it
	// ran dry holds drift.
	for _ in 0 ..< 5 * 60 {
		m.queued = 0
		model_vblank(&m, mixed, 0, 1)
	}
	m.queued = TARGET / 2
	for _ in 0 ..< 50 {
		model_vblank(&m, mixed, played, 1)
	}
	if m.ctl.drift != settled {
		audio_fail("drift %.5f after a stall, want %.5f held", m.ctl.drift, settled)
	}
	// Under a quarter of the target, settled: the queue is too near empty to
	// say anything about the clocks.
	m.ctl.settle = 0
	for _ in 0 ..< RATE / BATCH {
		core.audio_step(&m.ctl, TARGET / 5, TARGET, BATCH, RATE, 1)
	}
	if m.ctl.drift != settled {
		audio_fail("drift %.5f with the queue under a quarter, want %.5f held", m.ctl.drift, settled)
	}
	// A slow host, settling each vblank as the host does past 1.25 vblanks
	// of work, with the queue above a quarter of its target and draining.
	m.queued = TARGET / 2
	for _ in 0 ..< 5 * 60 {
		m.ctl.settle = RATE
		model_vblank(&m, mixed, played * 1.1, 1)
		m.queued = max(m.queued, TARGET / 3)
	}
	if m.ctl.drift != settled {
		audio_fail("drift %.5f on a slow host, want %.5f held", m.ctl.drift, settled)
	}
	// Settled by hand (audio_settle), and off speed 1 either way, with the
	// queue far off target.
	for speed in ([3]f64{1, 2, 0.5}) {
		m.ctl.settle = RATE if speed == 1 else 0
		m.queued = 2 * TARGET
		model_vblank(&m, mixed, played, speed)
		if m.ctl.drift != settled {
			audio_fail("drift %.5f moved at speed %v, want %.5f held", m.ctl.drift, speed, settled)
		}
	}
	// Saturated: the queue held at twice its target for 10 s puts the step
	// at AUDIO_RATE_MAX; back at the target, drift has not wound up past
	// where it was.
	m.ctl.settle = 0
	for _ in 0 ..< 10 * 60 {
		m.queued = 2 * TARGET
		model_vblank(&m, mixed, played, 1)
	}
	// One vblank back at the target learns at most its own error's worth,
	// AUDIO_RATE_MAX times a vblank over AUDIO_DRIFT_S: under 1e-5.
	m.queued = TARGET
	model_vblank(&m, mixed, played, 1)
	if m.ctl.drift > settled + 1e-5 {
		audio_fail("drift %.5f after saturating, wound up past %.5f", m.ctl.drift, settled)
	}
	// Back at the target, it still holds the queue there.
	m.queued = TARGET
	for _ in 0 ..< 60 * 60 {
		model_vblank(&m, mixed, played, 1)
	}
	if abs(m.ctl.drift - want) > 0.0001 || abs(m.queued + mixed / 2 - TARGET) > TARGET / 10 {
		audio_fail("drift %.5f, queue %.0f mid-vblank after the stall, want %.5f, about %d", m.ctl.drift, m.queued + mixed / 2, want, TARGET)
	}
	fmt.printfln("ok audio_step: drift %.4f%%, want %.4f%%", m.ctl.drift * 100, want * 100)
}
