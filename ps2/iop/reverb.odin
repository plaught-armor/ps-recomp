// SPU2 reverb, for FMOD's FSOUND_Reverb_SetProperties.
//
// FMOD.IRX hands the environment to libsd as the core effect mode
// (sceSdSetEffectAttr) and the room level to EVOL; channels whose reverb
// room is not -10000 join the VMIXE mask. Each mode loads one of libsd's
// register presets, which are the PSX SPU reverb tables (offsets in 8-byte
// units), and the core runs the PSX algorithm at half the output rate.
// Echo and delay take their preset as is: the delay and feedback FMOD sends
// are not applied.
package ps2_iop

// The 32 reverb registers in SPU order, per mode 1 (room) .. 9 (pipe), from
// LIBSD.IRX.
@(private = "file")
REVERB_PRESETS := [9][32]u16 {
	{0x007d, 0x005b, 0x6d80, 0x54b8, 0xbed0, 0x0000, 0x0000, 0xba80, 0x5800, 0x5300, 0x04d6, 0x0333, 0x03f0, 0x0227, 0x0374, 0x01ef, 0x0336, 0x01b7, 0x0335, 0x01b6, 0x0334, 0x01b5, 0x0334, 0x01b5, 0x0334, 0x01b5, 0x01b4, 0x0136, 0x00b8, 0x005c, 0x8000, 0x8000},
	{0x0033, 0x0025, 0x70f0, 0x4fa8, 0xbce0, 0x4410, 0xc0f0, 0x9c00, 0x5280, 0x4ec0, 0x03e4, 0x031b, 0x03a4, 0x02af, 0x0372, 0x0266, 0x031c, 0x025d, 0x025c, 0x018e, 0x022f, 0x0135, 0x01d2, 0x00b7, 0x018f, 0x00b5, 0x00b4, 0x0080, 0x004c, 0x0026, 0x8000, 0x8000},
	{0x00b1, 0x007f, 0x70f0, 0x4fa8, 0xbce0, 0x4510, 0xbef0, 0xb4c0, 0x5280, 0x4ec0, 0x0904, 0x076b, 0x0824, 0x065f, 0x07a2, 0x0616, 0x076c, 0x05ed, 0x05ec, 0x042e, 0x050f, 0x0305, 0x0462, 0x02b7, 0x042f, 0x0265, 0x0264, 0x01b2, 0x0100, 0x0080, 0x8000, 0x8000},
	{0x00e3, 0x00a9, 0x6f60, 0x4fa8, 0xbce0, 0x4510, 0xbef0, 0xa680, 0x5680, 0x52c0, 0x0dfb, 0x0b58, 0x0d09, 0x0a3c, 0x0bd9, 0x0973, 0x0b59, 0x08da, 0x08d9, 0x05e9, 0x07ec, 0x04b0, 0x06ef, 0x03d2, 0x05ea, 0x031d, 0x031c, 0x0238, 0x0154, 0x00aa, 0x8000, 0x8000},
	{0x01a5, 0x0139, 0x6000, 0x5000, 0x4c00, 0xb800, 0xbc00, 0xc000, 0x6000, 0x5c00, 0x15ba, 0x11bb, 0x14c2, 0x10bd, 0x11bc, 0x0dc1, 0x11c0, 0x0dc3, 0x0dc0, 0x09c1, 0x0bc4, 0x07c1, 0x0a00, 0x06cd, 0x09c2, 0x05c1, 0x05c0, 0x041a, 0x0274, 0x013a, 0x8000, 0x8000},
	{0x033d, 0x0231, 0x7e00, 0x5000, 0xb400, 0xb000, 0x4c00, 0xb000, 0x6000, 0x5400, 0x1ed6, 0x1a31, 0x1d14, 0x183b, 0x1bc2, 0x16b2, 0x1a32, 0x15ef, 0x15ee, 0x1055, 0x1334, 0x0f2d, 0x11f6, 0x0c5d, 0x1056, 0x0ae1, 0x0ae0, 0x07a2, 0x0464, 0x0232, 0x8000, 0x8000},
	{0x0003, 0x0003, 0x7fff, 0x7fff, 0x0000, 0x0000, 0x0000, 0x8100, 0x0000, 0x0000, 0x1ffd, 0x0ffd, 0x1009, 0x0009, 0x0000, 0x0000, 0x1009, 0x0009, 0x1fff, 0x1fff, 0x1ffe, 0x1ffe, 0x1ffe, 0x1ffe, 0x1ffe, 0x1ffe, 0x1008, 0x1004, 0x0008, 0x0004, 0x8000, 0x8000},
	{0x0003, 0x0003, 0x7fff, 0x7fff, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1ffd, 0x0ffd, 0x1009, 0x0009, 0x0000, 0x0000, 0x1009, 0x0009, 0x1fff, 0x1fff, 0x1ffe, 0x1ffe, 0x1ffe, 0x1ffe, 0x1ffe, 0x1ffe, 0x1008, 0x1004, 0x0008, 0x0004, 0x8000, 0x8000},
	{0x0017, 0x0013, 0x70f0, 0x4fa8, 0xbce0, 0x4510, 0xbef0, 0x8500, 0x5f80, 0x54c0, 0x0371, 0x02af, 0x02e5, 0x01df, 0x02b0, 0x01d7, 0x0358, 0x026a, 0x01d6, 0x011e, 0x012d, 0x00b1, 0x011f, 0x0059, 0x01a0, 0x00e3, 0x0058, 0x0040, 0x0028, 0x0014, 0x8000, 0x8000},
}

// Work area per mode, in samples (the PSX sizes).
@(private = "file")
REVERB_WORK := [9]u32{0x1360, 0xfa0, 0x2420, 0x37f0, 0x56f0, 0x7b60, 0xc020, 0xc020, 0x1e00}

@(private = "file")
REVERB_MAX :: 0xc020

@(private)
Reverb :: struct {
	mode: u32, // 0 off, else 1 .. 9
	evol: i32, // return volume, 0 .. 0x3fff
	pos:  u32, // work area position
	last: [2]i32, // previous half-rate output, for the upsample
	work: [REVERB_MAX]i16,
}

@(private)
reverb: Reverb

// Select a mode and return volume; a new mode starts on a cleared work area.
reverb_set :: proc(mode: u32, evol: i32) {
	m := mode <= 9 ? mode : 0
	if m != reverb.mode {
		reverb.work = {}
		reverb.pos, reverb.last = 0, {}
	}
	reverb.mode, reverb.evol = m, clamp(evol, 0, 0x3fff)
}

// Run the reverb over the interleaved stereo send and add its return to acc.
reverb_mix :: proc(send, acc: []i32) {
	if reverb.mode == 0 {return}
	r := &REVERB_PRESETS[reverb.mode - 1]
	size := REVERB_WORK[reverb.mode - 1]
	vol :: #force_inline proc(r: ^[32]u16, i: int) -> i32 {return i32(i16(r[i]))}
	// Work area sample at register i (8-byte units) plus d samples.
	at :: #force_inline proc(r: ^[32]u16, i: int, d: i32, size: u32) -> ^i16 {
		return &reverb.work[(i32(reverb.pos) + i32(r[i]) * 4 + d) %% i32(size)]
	}
	sat :: #force_inline proc(x: i32) -> i16 {return i16(clamp(x, -32768, 32767))}
	rd :: #force_inline proc(p: ^i16) -> i32 {return i32(p^)}
	viir, vwall := vol(r, 2), vol(r, 7)
	vapf1, vapf2 := vol(r, 8), vol(r, 9)
	dapf1, dapf2 := i32(r[0]) * 4, i32(r[1]) * 4
	for n := 0; n + 3 < len(send); n += 4 {
		lin := i32(sat((send[n] + send[n + 2]) / 2)) * vol(r, 30) >> 15
		rin := i32(sat((send[n + 1] + send[n + 3]) / 2)) * vol(r, 31) >> 15
		// Same side and cross reflections: mLSAME, mRSAME, mLDIFF, mRDIFF.
		refl :: #force_inline proc(r: ^[32]u16, m, d: int, x, viir, vwall: i32, size: u32) -> i16 {
			prev := rd(at(r, m, -1, size))
			return sat(((x + rd(at(r, d, 0, size)) * vwall >> 15) - prev) * viir >> 15 + prev)
		}
		at(r, 10, 0, size)^ = refl(r, 10, 16, lin, viir, vwall, size)
		at(r, 11, 0, size)^ = refl(r, 11, 17, rin, viir, vwall, size)
		at(r, 18, 0, size)^ = refl(r, 18, 25, lin, viir, vwall, size)
		at(r, 19, 0, size)^ = refl(r, 19, 24, rin, viir, vwall, size)
		// Comb taps mLCOMB1..4 / mRCOMB1..4.
		lout := (vol(r, 3) * rd(at(r, 12, 0, size)) + vol(r, 4) * rd(at(r, 14, 0, size)) +
			vol(r, 5) * rd(at(r, 20, 0, size)) + vol(r, 6) * rd(at(r, 22, 0, size))) >> 15
		rout := (vol(r, 3) * rd(at(r, 13, 0, size)) + vol(r, 4) * rd(at(r, 15, 0, size)) +
			vol(r, 5) * rd(at(r, 21, 0, size)) + vol(r, 6) * rd(at(r, 23, 0, size))) >> 15
		// Two all-pass stages: mLAPF1/mRAPF1, then mLAPF2/mRAPF2.
		apf :: #force_inline proc(r: ^[32]u16, m: int, x, d, v: i32, size: u32) -> i32 {
			t := rd(at(r, m, -d, size))
			y := sat(x - (v * t >> 15))
			at(r, m, 0, size)^ = y
			return i32(y) * v >> 15 + t
		}
		lout = apf(r, 26, lout, dapf1, vapf1, size)
		rout = apf(r, 27, rout, dapf1, vapf1, size)
		lout = apf(r, 28, lout, dapf2, vapf2, size)
		rout = apf(r, 29, rout, dapf2, vapf2, size)
		lout = i32(sat(lout)) * reverb.evol >> 15
		rout = i32(sat(rout)) * reverb.evol >> 15
		reverb.pos = (reverb.pos + 1) % size
		// Back to the output rate: the midpoint, then the new sample.
		acc[n] += (reverb.last[0] + lout) / 2
		acc[n + 1] += (reverb.last[1] + rout) / 2
		acc[n + 2] += lout
		acc[n + 3] += rout
		reverb.last = {lout, rout}
	}
}
