package ps2_iop

import "core:fmt"
import cpu "../cpu"
import mem "../mem"

// CRI ADX's IOP driver (CRI_ADX_Driver, RPC 0x90000200). There is no ADX
// output yet: the driver plays every stream silently, consuming its PCM at
// the stream's sample rate so the EE's playback clock (ADXT time, which
// Sofdec movies sync to) advances as on hardware.
//
// Function numbers: 2/3 create/destroy a DTX (the EE<->IOP transfer channel,
// {id, EE work, IOP work, size} -> handle); 0x400 + n are remote calls
// through one EE stub, among them 0x400 SJX create ({EE SJ, IOP SJ, lane,
// EE SJX} -> handle), 0x408 PS2RNA create ({channels, 0, IOP SJ per channel}
// -> handle), and their destroys 0x401 and 0x409. 0x420-0x42a are a remote
// stream joint over IOP memory: 0x420-0x422 create one and 0x423 destroys
// it; the rest move chunks, which the silent driver never needs.
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
		for &r in adx.rna {
			if r.handle != 0 {continue}
			r = {handle = adx.handles, channels = min(w[0], 2), sj = {w[2], w[3]}}
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
			for &r in adx.rna {if r.handle == w[0] {adx_rna_stop(&r); r = {}}}
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
		for &r in adx.rna {
			if r.handle != handle || handle == 0 {continue}
			switch cmd {
			case ADX_RNA_PLAY:
				if arg == 0 {adx_rna_stop(&r)}
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
	for &r in adx.rna {
		if r.handle == 0 || !r.playing || r.rate == 0 {continue}
		// Count from the later of the last round trip and the play start,
		// so a stream started in between is not credited the whole gap.
		r.clock += (now - max(adx.cycles, r.since)) * u64(r.rate)
		samples := u32(r.clock / cpu.EE_CLOCK)
		r.clock %= cpu.EE_CLOCK
		for sj in r.sj[:r.channels] {
			s := adx_sjx_of(sj)
			if s == nil {continue}
			bytes := samples * 2 // 16-bit PCM
			for bytes > 0 && s.count > 0 && out < ADX_ENTRIES {
				c := &s.held[0]
				n := min(bytes, c.size)
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

// Stopping hands back what the RNA held unplayed: the EE keeps its stream
// joints, so a chunk never returned is buffer space lost to the next stream.
@(private)
adx_rna_stop :: proc(r: ^Adx_Rna) {
	for sj in r.sj[:r.channels] {
		if s := adx_sjx_of(sj); s != nil {s.flush = true}
	}
	r.clock = 0
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
