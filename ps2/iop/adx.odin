package ps2_iop

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import mem "../mem"

// CRI ADX's IOP driver (CRI_ADX_Driver, RPC 0x90000200). The EE decodes ADX
// and sends the PCM; the driver consumes it at the stream's sample rate, so
// the EE's playback clock (ADXT time, which Sofdec movies sync to) advances
// as on hardware. What a round trip consumes is copied into the stream's
// ring before the chunk goes back, and adx_mix plays the rings into the
// host mix.
//
// Function numbers: 2/3 create/destroy a DTX (the EE<->IOP transfer channel,
// {id, EE work, IOP work, size} -> handle); 0x400 + n are remote calls
// through one EE stub, among them 0x400 SJX create ({EE SJ, IOP SJ, lane,
// EE SJX} -> handle), 0x408 PS2RNA create ({channels, 0, IOP SJ per channel}
// -> handle), and their destroys 0x401 and 0x409. 0x420-0x42a are a remote
// stream joint over IOP memory: 0x420-0x422 create one and 0x423 destroys
// it; the rest move chunks, which this driver never needs.
//
// A DTX round trip: the EE DMAs its work buffer to the IOP work buffer, a
// packet of {count, 12 bytes, count 16-byte entries} with a 64-byte trailer
// whose last word is the EE's sequence number. The IOP answers with a packet
// of its own written over the EE work buffer and the sequence number plus
// one. DTX 0 carries the SJXs: the EE sends each PCM chunk the PS2RNA
// filled ({0, lane, 0, IOP SJX, address, length}) and gets each chunk back
// once played ({0, free lane, 0, EE SJX, address, length}). DTX 1 carries
// PS2RNA commands {command, RNA, argument, argument}: 2 starts (1) or stops
// (0) playback, 4 sets the sample rate. Its replies are never read.
ADX_DTX :: 4
ADX_SJX :: 32
ADX_RNA :: 16
ADX_HELD :: 32 // chunks an SJX holds while they play
ADX_ENTRIES :: 0x80 // entries in one DTX packet, the EE's own limit
ADX_RING :: 4096 // samples per channel a stream holds for the mixer, a power of two

ADX_DTX_SJX :: 0
ADX_DTX_RNA :: 1
ADX_RNA_PLAY :: 2
ADX_RNA_RATE :: 4

Adx_Chunk :: struct {
	addr, size: u32,
}

Adx_Sjx :: struct {
	handle, ee_sjx, iop_sj: u32,
	held:                   [ADX_HELD]Adx_Chunk,
	count:                  u32,
	flush:                  bool, // its RNA stopped: hand every held chunk back
}

Adx_Rna :: struct {
	handle, rate, channels: u32,
	sj:                     [2]u32,
	playing:                bool,
	since:                  u64, // EE cycles when playback last started
	clock:                  u64, // sample count times EE_CLOCK not yet played
}

// The PCM an RNA consumed but has not yet mixed. Host output only, so not in
// snapshots: wr counts samples written per channel, pos is the mixer's read
// position in samples, 32.32 fixed point.
Adx_Out :: struct {
	ring:   [2][ADX_RING]i16,
	wr:     [2]u64,
	pos:    u64,
	primed: bool, // holds enough to play without running dry
}

Adx_Dtx :: struct {
	handle, id, ee_work, iop_work, size: u32,
}

@(private)
adx: struct {
	handles: u32,
	cycles:  u64, // when the SJX DTX last ran
	dtx:     [ADX_DTX]Adx_Dtx,
	sjx:     [ADX_SJX]Adx_Sjx,
	rna:     [ADX_RNA]Adx_Rna,
}

@(private)
adx_out: [ADX_RNA]Adx_Out // by RNA slot

// Emulated state, saved and restored by snapshots (snap.odin). A load
// drops the unmixed PCM: it belongs to the run before the load.
adx_snap :: proc() {
	core.snap_add(&adx)
	append(&core.snap_hooks, core.Snap_Hook{save = proc(id: int) {}, load = proc(id: int) {
		for &o in adx_out {o.wr, o.pos, o.primed = {}, 0, false}
	}})
}

@(private)
adx_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 2:
		adx.handles += 1
		for &t in adx.dtx {
			if t.handle != 0 {continue}
			t = {adx.handles, w[0], w[1], w[2] & (IOP_RAM_SIZE - 1), w[3]}
			break
		}
		w[0] = adx.handles
	case 0x400:
		adx.handles += 1
		for &s in adx.sjx {
			if s.handle != 0 {continue}
			s = {handle = adx.handles, ee_sjx = w[3], iop_sj = w[1]}
			break
		}
		w[0] = adx.handles
	case 0x408:
		adx.handles += 1
		for &r, i in adx.rna {
			if r.handle != 0 {continue}
			r = {handle = adx.handles, channels = min(w[0], 2), sj = {w[2], w[3]}}
			o := &adx_out[i]
			o.wr, o.pos, o.primed = {}, 0, false
			break
		}
		w[0] = adx.handles
	case 0x420, 0x421, 0x422:
		adx.handles += 1
		w[0] = adx.handles
	case:
		if cpu.debug >= 1 {fmt.eprintfln("adx: call %x send %d", fno, send_size)}
		switch fno {
		case 3:
			for &t in adx.dtx {if t.handle == w[0] {t = {}}}
		case 0x401:
			for &s in adx.sjx {if s.handle == w[0] {s = {}}}
		case 0x409:
			for &r, i in adx.rna {if r.handle == w[0] {adx_rna_stop(i); r = {}}}
		}
		for &b in buf[:16] {b = 0} // recv is at most 4 words
	}
	return true
}

// The EE DMA'd `size` bytes to IOP address `dest`: answer a DTX packet.
adx_dma :: proc(dest, size: u32) {
	for &t in adx.dtx {
		if t.handle == 0 || t.iop_work != dest || size < t.size {continue}
		seq := iop_u32(t.iop_work + t.size - 4)^
		out: u32
		switch t.id {
		case ADX_DTX_SJX: out = adx_sjx_packet(&t)
		case ADX_DTX_RNA: adx_rna_packet(&t)
		}
		mem.wr32(t.ee_work, out)
		mem.wr32(t.ee_work + t.size - 4, seq + 1)
	}
}

@(private)
adx_rna_packet :: proc(t: ^Adx_Dtx) {
	count := min(iop_u32(t.iop_work)^, ADX_ENTRIES)
	for n in 0 ..< count {
		e := t.iop_work + 16 + n * 16
		cmd, handle, arg := iop_u32(e)^ & 0xffff, iop_u32(e + 4)^, iop_u32(e + 8)^
		for &r, i in adx.rna {
			if r.handle != handle || handle == 0 {continue}
			switch cmd {
			case ADX_RNA_PLAY:
				if arg == 0 {adx_rna_stop(i)}
				if arg != 0 && !r.playing {r.since = cpu.state.cycles}
				r.playing = arg != 0
			case ADX_RNA_RATE:
				r.rate = arg
			}
		}
	}
}

// Take the chunks the EE sent, then return what played since the last
// round trip. Returns the reply's entry count. A chunk is never dropped:
// the receive loop returns at most one entry per entry received, so it
// cannot fill the reply, and the later returns stop at a full reply and
// keep what is left held for the next round trip.
@(private)
adx_sjx_packet :: proc(t: ^Adx_Dtx) -> u32 {
	out: u32
	count := min(iop_u32(t.iop_work)^, ADX_ENTRIES)
	for n in 0 ..< count {
		e := t.iop_work + 16 + n * 16
		s := adx_sjx(iop_u32(e + 4)^)
		if s == nil {continue}
		c := Adx_Chunk{iop_u32(e + 8)^, iop_u32(e + 12)^}
		last := &s.held[max(s.count, 1) - 1]
		switch {
		case s.count > 0 && last.addr + last.size == c.addr:
			last.size += c.size
		case s.count < ADX_HELD:
			s.held[s.count] = c
			s.count += 1
		case:
			adx_return(t, &out, s, c) // nowhere to hold it: played at once
		}
	}

	for &s in adx.sjx {
		if !s.flush {continue}
		// Oldest first, the order they would have played in.
		n: u32
		for n < s.count && out < ADX_ENTRIES {
			adx_return(t, &out, &s, s.held[n])
			n += 1
		}
		copy(s.held[:s.count - n], s.held[n:s.count])
		s.count -= n
		s.flush = s.count > 0
	}

	now := cpu.state.cycles
	defer adx.cycles = now
	for &r, i in adx.rna {
		if r.handle == 0 || !r.playing || r.rate == 0 {continue}
		// Count from the later of the last round trip and the play start,
		// so a stream started in between is not credited the whole gap.
		r.clock += (now - max(adx.cycles, r.since)) * u64(r.rate)
		samples := u32(r.clock / cpu.EE_CLOCK)
		r.clock %= cpu.EE_CLOCK
		for sj, ch in r.sj[:r.channels] {
			s := adx_sjx_of(sj)
			if s == nil {continue}
			bytes := samples * 2 // 16-bit PCM
			for bytes > 0 && s.count > 0 && out < ADX_ENTRIES {
				c := &s.held[0]
				n := min(bytes, c.size)
				adx_ring_put(&adx_out[i], ch, c.addr, n)
				adx_return(t, &out, s, {c.addr, n})
				bytes -= n
				c.addr += n
				c.size -= n
				if c.size > 0 {continue}
				copy(s.held[:s.count - 1], s.held[1:s.count])
				s.count -= 1
			}
		}
	}
	return out
}

// Write reply entry `out` handing chunk `c` back to the EE side of `s`.
@(private)
// Callers check the reply has room: a chunk written nowhere is buffer space
// the EE never gets back.
adx_return :: proc(t: ^Adx_Dtx, out: ^u32, s: ^Adx_Sjx, c: Adx_Chunk) {
	assert(out^ < ADX_ENTRIES)
	e := t.ee_work + 16 + out^ * 16
	mem.wr32(e, 0) // type 0, lane 0 (free)
	mem.wr32(e + 4, s.ee_sjx)
	mem.wr32(e + 8, c.addr)
	mem.wr32(e + 12, c.size)
	out^ += 1
}

// Stopping RNA slot `i` hands back what it held unplayed: the EE keeps its
// stream joints, so a chunk never returned is buffer space lost to the next
// stream. What it consumed but has not mixed is dropped.
@(private)
adx_rna_stop :: proc(i: int) {
	r := &adx.rna[i]
	for sj in r.sj[:r.channels] {
		if s := adx_sjx_of(sj); s != nil {s.flush = true}
	}
	r.clock = 0
	o := &adx_out[i]
	o.wr, o.pos, o.primed = {}, 0, false
}

// Copy `size` bytes of 16-bit PCM at IOP address `addr` into channel `ch`
// of `o`'s ring. The ring overwrites its oldest samples; adx_mix skips ahead
// when that happens.
@(private)
adx_ring_put :: proc(o: ^Adx_Out, ch: int, addr, size: u32) {
	for n in 0 ..< size / 2 {
		a := (addr + n * 2) & (IOP_RAM_SIZE - 2)
		o.ring[ch][o.wr[ch] & (ADX_RING - 1)] = i16(u16(iop_ram[a]) | u16(iop_ram[a + 1]) << 8)
		o.wr[ch] += 1
	}
}

// Add the playing streams to interleaved stereo at MIX_RATE, resampled from
// each stream's rate. A stream starts, and restarts after running dry, only
// once it holds two vblanks of PCM, since round trips deliver it in bursts.
adx_mix :: proc(out: []i16) {
	for &r, k in adx.rna {
		if r.handle == 0 || !r.playing || r.rate == 0 || r.channels == 0 {continue}
		o := &adx_out[k]
		last := r.channels - 1 // a mono stream plays on both sides
		have := min(o.wr[0], o.wr[last])
		if have - min(o.pos >> 32, have) > ADX_RING - 4 {
			o.pos = (have - ADX_RING / 2) << 32 // overrun: keep the newest half
		}
		if !o.primed && have - min(o.pos >> 32, have) < u64(r.rate) / 30 {continue}
		o.primed = true
		step := (u64(r.rate) << 32) / MIX_RATE
		for n := 0; n < len(out); n += 2 {
			i := o.pos >> 32
			if i + 3 > have {o.primed = false; break} // gauss reads i-1 .. i+2
			p := u32(o.pos >> 24)
			l := adx_gauss(o, 0, i, p)
			s := adx_gauss(o, int(last), i, p)
			out[n] = i16(clamp(i32(out[n]) + l, -32768, 32767))
			out[n + 1] = i16(clamp(i32(out[n + 1]) + s, -32768, 32767))
			o.pos += step
		}
	}
}

// Channel `ch` of `o` at sample `i` plus fraction `p` (8 bits), Gaussian
// interpolated over samples i-1 .. i+2 as SPU2 voices play.
@(private)
adx_gauss :: proc(o: ^Adx_Out, ch: int, i: u64, p: u32) -> i32 {
	m :: ADX_RING - 1
	q := &o.ring[ch]
	return gauss(i32(q[(i - 1) & m]), i32(q[i & m]), i32(q[(i + 1) & m]), i32(q[(i + 2) & m]), p)
}

@(private)
adx_sjx :: proc(handle: u32) -> ^Adx_Sjx {
	for &s in adx.sjx {if s.handle == handle && handle != 0 {return &s}}
	return nil
}

// The SJX feeding IOP stream joint `sj`.
@(private)
adx_sjx_of :: proc(sj: u32) -> ^Adx_Sjx {
	for &s in adx.sjx {if s.iop_sj == sj && s.handle != 0 {return &s}}
	return nil
}
