// The VU programs a conversion compiles, and what is known of their pairs,
// for every backend that emits them (vu.odin: Odin source).
//
// Programs are VU1 .vutext programs and the extents of captured micro
// images (vu.odin's header). Each is classified pair by pair: branches, the
// order of its halves against the interpreter's vu_pair, which flag values
// a later read or an exit can see, and the pairs a run can enter at other
// than by falling through.
//
// A micro-mode flag read sees the flags after the pair four back (the
// runtime's vu/vu.odin): Vu keeps each flag's three older values, and the
// interpreter shifts them after every pair. Compiled code shifts only the
// ones demand_flags finds a later read or an exit can see, which gives the
// reads what the interpreter's full shift gives them.
//
// Q lands VU_Q_DIV pairs after a DIV or SQRT and VU_Q_RSQRT after an RSQRT
// (the runtime's VU_Q_DIV), unless a WAITQ or another of them lands it
// first. Vu keeps the pending Q and how many pairs are left; compiled code
// counts them down only on the pairs demand_q finds one can be pending at.
package vu

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strings"
import "../mips"

// Which VU a program runs on.
Unit :: enum u8 {VU0, VU1}

// Each unit's micro memory as a pair address mask.
@(private, rodata)
MASK := [Unit]u32 {
	.VU0 = 0xff8,
	.VU1 = 0x3ff8,
}

@(private)
Branch :: enum u8 {None, Uncond, Cond, Reg}

@(private)
Pair :: struct {
	lw, uw:     u32,
	ibit, ebit: bool,
	branch:     Branch,
	mode:       Mode,
	reads:      [Flag]u8, // the depths of each flag the pair reads (Depths)
	kills:      bit_set[Flag], // the flags the pair sets whole
	out:        [Flag]u8, // the depths of each flag after the pair that can be seen
	waits:      Waits, // the Q and P waits the pair can start with, when not run as a delay slot (demand_waits)
	stall:      bool, // the pair can stall before it runs (stall_waits)
}

// The flags a micro-mode read sees late.
@(private)
Flag :: enum u8 {Mac, Status, Clip}

// A demand on a flag's values, as bits: DEPTH_NOW the newest, then Vu's
// old_<flag>[0], [1] and [2], the value a read sees (DEPTH_READ).
@(private)
DEPTH_NOW, DEPTH_READ, DEPTH_ALL :: u8(1), u8(8), u8(15)

// A pair compiled code leaves at for the interpreter: a branch or E bit
// in a delay slot, or code running past the program.
@(private)
leave_pair :: proc(pairs: []Pair, i: int) -> bool {
	plain :: proc(p: Pair) -> bool {return !p.ebit && (p.ibit || p.branch == .None)}
	p := pairs[i]
	branch := !p.ibit && p.branch != .None
	if !branch && !p.ebit {return false}
	return i + 1 >= len(pairs) || !plain(pairs[i + 1]) || (branch && p.ebit)
}

// The branch VI delay's history entries, as the runtime's (VIH_PAIR and
// the rest in ps2/vu/vu.odin, which says what they hold).
@(private)
VIH_WRITE :: 1 << 20
@(private)
VIH_FLAGS :: 1 << 21
@(private)
VIH_PAIR :: 1 << 22

// Pair (uw, lw)'s VIH entry, without the old value. As the runtime's
// vih_entry.
@(private)
vih_entry :: proc(uw, lw: u32) -> u32 {
	if uw & (1 << 31) != 0 {return VIH_PAIR}
	it, is := (lw >> 16) & 15, (lw >> 11) & 15
	n, flags := u32(0), false
	switch lw >> 25 {
	case 0x04, 0x08, 0x09: n = it // ILW, IADDIU, ISUBIU
	case 0x10, 0x12, 0x13: n, flags = 1, true // FCEQ, FCAND, FCOR
	case 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c: n, flags = it, true // FS*, FM*, FCGET
	case 0x40:
		switch lw & 63 {
		case 0x30, 0x31, 0x34, 0x35: n = (lw >> 6) & 31 // IADD, ISUB, IAND, IOR: fd
		case 0x32: n = (lw >> 16) & 31 // IADDI
		case 0x3c ..= 0x3f:
			switch ((lw >> 4) & 0x7c) | (lw & 3) {
			case 0x34, 0x36: n = is // LQI, LQD
			case 0x35, 0x37, 0x3c, 0x3e: n = it // SQI, SQD, MTIR, ILWR
			}
		}
	}
	if n == 0 {return VIH_PAIR}
	return VIH_PAIR | VIH_WRITE | (n & 15) << 16 | (flags ? VIH_FLAGS : 0)
}

// The branch VI delay in compiled code (the runtime's vi_branch): delayed
// marks the conditional branches that read their VIs through vu.vi_branch,
// those where the pair before can write one; enter marks the pairs that
// enter themselves into Vu.vih before they run, the four before each of
// those. A branch compiled code leaves to the interpreter (leave_pair)
// counts as delayed, so the interpreter finds the pairs before it, and so
// does a pair compiled code leaves out after one that writes a VI. Any
// other branch stops at the pair before it, which wrote no VI it reads, or
// was run by the interpreter, which enters every pair. A jump to a pair either marks clears Vu.vih, as the
// interpreter's jumps do, and so does every JR and JALR. Both are in the
// temp allocator.
@(private)
delay_pairs :: proc(pairs: []Pair, ext: []bool) -> (delayed, enter: []bool) {
	n := len(pairs)
	delayed = make([]bool, n, context.temp_allocator)
	enter = make([]bool, n, context.temp_allocator)
	for p, i in pairs {
		before := (i + n - 1) % n
		e := vih_entry(pairs[before].uw, pairs[before].lw)
		if ext != nil && !ext[i] {
			// The interpreter runs a pair compiled code leaves out, whatever
			// words it holds by then, and can branch looking back into it.
			if ext[before] && e & VIH_WRITE != 0 {
				for k in 1 ..= 4 {enter[(i + n - k) % n] = true}
			}
			continue
		}
		if p.ibit || p.branch != .Cond {continue}
		it, is := (p.lw >> 16) & 15, (p.lw >> 11) & 15
		if p.lw >> 25 >= 0x2c {it = 0} // IBLTZ and on read only is
		r := (e >> 16) & 15
		writes := e & VIH_WRITE != 0 && r != 0 && (r == it || r == is)
		// A pair compiled code leaves out can hold other words at run time.
		if ext != nil && !ext[before] {writes = true}
		if !writes && !leave_pair(pairs, i) {continue}
		delayed[i] = true
		for k in 1 ..= 4 {enter[(i + n - k) % n] = true}
	}
	return
}

// How a pair's halves are ordered against the interpreter's vu_pair.
@(private)
Mode :: enum u8 {
	Serial, // upper then lower: neither sees the other's writes
	Lower_First, // the lower reads flags the upper writes, and writes only VI
	Hazard, // the lower reads or writes the VF register the upper writes
	Slow, // vu.vu0_pair, vu.vu1_pair
}

@(private)
Prog :: struct {
	words: [dynamic]u32, // lw, uw from micro address 0
	ext:     []bool, // the pairs compiled, for a captured image; nil: all
	entries: []u32, // every captured entry pc of the unit, for a captured image; {0} for a .vutext program
}

// A .vutext program is entered at pc 0, after an E-bit pair (the next
// program of a bundle) or at a branch target; dispatch_targets adds the
// last two. An MSCAL anywhere else reaches the interpreter until a label.
@(private)
VUTEXT_ENTRIES := [1]u32{0}

@(private)
find_programs :: proc(img: mips.Image) -> (progs: [dynamic]Prog, ok: bool) {
	sec := mips.find_section(img, ".vutext")
	if sec == nil {return progs, true}
	n := sec.size / 4
	w := ([^]u32)(raw_data(sec.data))[:n]
	end: u32 = 0
	for i: u32 = 0; i < n; {
		code := w[i]
		if (code >> 24) & 0x7f != 0x4a {
			i += 1
			continue
		}
		num := (code >> 16) & 0xff
		if num == 0 {num = 256}
		addr := (code & 0xffff) * 8
		if i + 1 + num * 2 > n {
			fmt.eprintfln("vu: MPG at %08x runs past .vutext", sec.addr + i * 4)
			return progs, false
		}
		if addr == 0 {
			append(&progs, Prog{entries = VUTEXT_ENTRIES[:]})
			end = 0
		}
		if len(progs) == 0 || addr != end {
			fmt.eprintfln("vu: MPG at %08x loads %04x, expected %04x", sec.addr + i * 4, addr, end)
			return progs, false
		}
		append(&progs[len(progs) - 1].words, ..w[i + 1:][:num * 2])
		end = addr + num * 8
		i += 1 + num * 2
	}
	return progs, true
}

@(private)
upper_writes_mac :: proc(uw: u32) -> bool {
	if uw & 63 < 0x3c {
		switch uw & 63 {
		case 0x10 ..= 0x17, 0x1d, 0x1f, 0x2b, 0x2f: return false // MAX, MINI
		}
		return true
	}
	switch ((uw >> 4) & 0x7c) | (uw & 3) {
	case 0x10 ..= 0x17, 0x1d, 0x1f, 0x2f: return false // ITOF, FTOI, ABS, CLIP, NOP
	}
	return true
}

// The VF register the upper op writes (0 for ACC-only or none), as
// vu_upper_dest.
@(private)
upper_dest :: proc(uw: u32) -> u32 {
	if uw & 63 < 0x3c {return (uw >> 6) & 31}
	switch ((uw >> 4) & 0x7c) | (uw & 3) {
	case 0x10 ..= 0x17, 0x1d: return (uw >> 16) & 31
	}
	return 0
}

@(private)
classify :: proc(lw, uw: u32) -> Pair {
	p := Pair{lw = lw, uw = uw, ibit = uw & (1 << 31) != 0, ebit = uw & (1 << 30) != 0}
	if upper_writes_mac(uw) {p.kills += {.Mac}}
	if uw & 0x7ff == 0x1ff {p.reads[.Clip] = DEPTH_NOW} // CLIP shifts the newest clip
	if p.ibit {return p}
	switch lw >> 25 {
	case 0x20, 0x21: p.branch = .Uncond
	case 0x24, 0x25: p.branch = .Reg
	case 0x28, 0x29, 0x2c ..= 0x2f: p.branch = .Cond
	}
	// As vu_pair_info, plus flag readers that can run first.
	ud := upper_dest(uw)
	ft, fs := (lw >> 16) & 31, (lw >> 11) & 31
	touches := ud != 0 && (ft == ud || fs == ud)
	p.mode = .Slow
	switch lw >> 25 {
	case 0x00: p.mode = ud == 0 || ft != ud ? .Serial : .Hazard
	case 0x01: p.mode = ud == 0 || fs != ud ? .Serial : .Hazard
	case 0x04, 0x05, 0x08, 0x09, 0x20, 0x21, 0x24, 0x25, 0x28, 0x29, 0x2c ..= 0x2f:
		p.mode = .Serial
	case 0x11: // FCSET: unless CLIP also writes the clip flags
		if uw & 0x7ff != 0x1ff {
			p.mode = .Serial
			p.kills += {.Clip}
		}
	case 0x10, 0x12, 0x13, 0x1c: // FCEQ/FCAND/FCOR/FCGET
		p.mode = .Lower_First
		p.reads[.Clip] |= DEPTH_READ
	case 0x18, 0x1a, 0x1b: // FMEQ/FMAND/FMOR
		p.mode = .Lower_First
		p.reads[.Mac] |= DEPTH_READ
	case 0x40:
		if lw & 63 < 0x3c {
			p.mode = .Serial
			break
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x3b, 0x3e, 0x3f, 0x68, 0x69, 0x6c, 0x7b: p.mode = .Serial
		// DIV, SQRT and RSQRT hold their status bits in q_flags until
		// the pair that sets them (emit_wait_pair)
		case: p.mode = touches ? .Hazard : .Serial
		}
	}
	if p.mode == .Slow { // vu_pair reads any flag, newest or late
		for &r in p.reads {r = DEPTH_NOW | DEPTH_READ}
		p.kills = {}
	}
	return p
}

// Backward dataflow: the depths of each flag after pair n (out) that a
// later read or an exit can see. A pair's shift moves depth k to depth k+1
// (the newest into old[0]); the newest passes through unless the pair sets
// that flag whole, and a stall before the pair shifts it more (stall).
// Leaving for the interpreter needs every depth, which it
// shifts and reads itself; an E bit only the newest, which the EE can read
// and the next program starts from. Status counts only with status set
// (reads_status): no upper op sets it whole, as its sticky bits keep every
// earlier write, so a demand on it reaches every upper op before.
@(private)
demand_flags :: proc(pairs: []Pair, ext: []bool, mask: u32, status: bool) {
	n := len(pairs)
	din := make([][Flag]u8, n, context.temp_allocator)
	ALL :: [Flag]u8{.Mac = DEPTH_ALL, .Status = DEPTH_ALL, .Clip = DEPTH_ALL}
	at :: proc(din: [][Flag]u8, ext: []bool, pc: int) -> [Flag]u8 {
		i := pc / 8
		return i >= len(din) || (ext != nil && !ext[i]) ? ALL : din[i]
	}
	for changed := true; changed; {
		changed = false
		for i := n - 1; i >= 0; i -= 1 {
			p := &pairs[i]
			out := at(din, ext, (i + 1) * 8)
			if i > 0 && !pairs[i - 1].ibit { // a delay slot also goes to the target
				prev := pairs[i - 1]
				switch prev.branch {
				case .None:
				case .Reg: out = ALL
				case .Uncond, .Cond: out |= at(din, ext, int(branch_target(prev.lw, u32(i - 1) * 8, mask)))
				}
			}
			if i > 0 && pairs[i - 1].ebit { // the E bit's delay slot
				for &o in out {o |= DEPTH_NOW}
			}
			if !status {out[.Status] = 0}
			inn := ALL
			if !leave_pair(pairs, i) {
				for f in Flag {
					inn[f] = p.reads[f] | out[f] >> 1 | (f in p.kills ? 0 : out[f] & DEPTH_NOW)
					// A stall's cycles each shift as the pair does, with
					// no flag set: up to three of them reach every depth.
					if p.stall {
						d := inn[f]
						for _ in 0 ..< 3 {
							d = d >> 1 | d & DEPTH_NOW
							inn[f] |= d
						}
					}
				}
			}
			if !status {inn[.Status] = 0}
			if out != p.out || inn != din[i] {changed = true}
			p.out, din[i] = out, inn
		}
	}
}

// As the runtime's VU_Q_DIV, VU_Q_RSQRT, VU_Q_FLAGS and VU_EFU_LATENCY.
@(private)
Q_DIV, Q_RSQRT, Q_FLAGS :: 7, 13, 4
@(private)
@(rodata)
EFU_LATENCY := [15]u32{11, 18, 18, 24, 54, 54, 12, 0, 12, 18, 12, 0, 29, 54, 44}

// The Q and P waits a pair can start or leave with, as sets: bit k for k
// pairs left until the value lands, bit 0 for none pending.
@(private)
Waits :: struct {
	q, p: u64,
}

// No wait pending.
@(private)
WAITS_NONE :: Waits{1, 1}

// The lower op key of p when it is a special op under no I bit, else 0.
@(private = "file")
special_key :: proc(p: Pair) -> u32 {
	if p.ibit || p.lw >> 25 != 0x40 || p.lw & 0x3c != 0x3c {return 0}
	return ((p.lw >> 4) & 0x7c) | (p.lw & 3)
}

// Whether pair p's lower waits for a pending Q (WAITQ, DIV, SQRT, RSQRT),
// as the runtime's vu_before.
@(private)
q_waits :: proc(p: Pair) -> bool {
	key := special_key(p)
	return key >= 0x38 && key <= 0x3b
}

// Whether pair p's lower waits for a pending P (WAITP, an EFU op), as the
// runtime's vu_before.
@(private)
p_waits :: proc(p: Pair) -> bool {
	key := special_key(p)
	return key >= 0x70 && key <= 0x7e && key != 0x77
}

// The pairs until Q lands that pair p's lower starts: Q_DIV, Q_RSQRT, or
// 0 for none.
@(private)
q_issue :: proc(p: Pair) -> u32 {
	switch special_key(p) {
	case 0x38, 0x39: return Q_DIV
	case 0x3a: return Q_RSQRT
	}
	return 0
}

// The pairs until P lands that pair p's EFU op starts, or 0 for none.
@(private)
p_issue :: proc(p: Pair) -> u32 {
	key := special_key(p)
	if key < 0x70 || key > 0x7e {return 0}
	return EFU_LATENCY[key - 0x70]
}

// Waits set s after n cycles: every wait less n, those at or below n none.
@(private)
waits_less :: proc(s: u64, n: u32) -> u64 {
	if n >= 63 {return 1}
	return s >> n | u64(s & (u64(2) << n - 1) != 0)
}

// The waits pair p runs its op with, from those it starts with, w, as the
// runtime's vu_before: a stall for a pending Q or P moves both on, then an
// EFU op lands a pending P. stalls holds bit s for each stall of s cycles
// the pair can make, bit 0 for none.
@(private)
stall_waits :: proc(p: Pair, w: Waits) -> (after: Waits, stalls: u64) {
	after = w
	switch {
	case q_waits(p):
		// q_wait cycles, landing Q.
		stalls = w.q
		after.q = 1
	case p_waits(p):
		// p_wait - 1 cycles, leaving at most 1.
		stalls = w.p >> 1 &~ 1 | u64(w.p & 3 != 0)
		after.p = w.p & 1 | u64(w.p &~ 1 != 0) << 1
		if p_issue(p) != 0 {after.p = 1} // lands the pending P
	case:
		return w, 1
	}
	if stalls == 1 {return}
	other := &after.p if q_waits(p) else &after.q
	moved: u64 = 0
	for s := u32(0); s < 64; s += 1 {
		if stalls & (u64(1) << s) != 0 {moved |= waits_less(other^, s)}
	}
	other^ = moved
	return
}

// The waits pair p's op leaves before the tick, from those it runs with:
// an issue starts its wait.
@(private)
issue_waits :: proc(p: Pair, w: Waits) -> Waits {
	w := w
	if l := q_issue(p); l != 0 {w.q = u64(1) << l}
	if l := p_issue(p); l != 0 {w.p = u64(1) << l}
	return w
}

// Whether pair p, starting with waits w, can find status I and D due from
// the FDIV unit (vu.vu_q_due) once its stall is done: the last tick left
// Q's wait at Q_FLAGS, or a stall can carry a longer wait down to it.
@(private)
q_due :: proc(p: Pair, w: Waits) -> bool {
	_, stalls := stall_waits(p, w)
	return w.q & (u64(1) << Q_FLAGS) != 0 || (stalls &~ 1 != 0 && w.q >> (Q_FLAGS + 1) != 0)
}

// The waits after pair p, from those it starts with, w: vu_before, the
// op, then vu_tick.
@(private)
waits_after :: proc(p: Pair, w: Waits) -> Waits {
	mid, _ := stall_waits(p, w)
	mid = issue_waits(p, mid)
	return {waits_less(mid.q, 1), waits_less(mid.p, 1)}
}

// Forward dataflow: the Q and P waits each pair can start with (waits),
// and whether it can stall (stall). Compiled code is entered only with
// none pending (the runtime's vu_interp hands over no sooner), so every
// pair can start with none. A pair also starts with what the pair before
// it leaves when that falls through, and a branch target with what the
// branch's delay slot leaves; the delay slot runs inline from what the
// branch leaves. A JR or JALR can land on any pair. A pair left for the
// interpreter runs nothing compiled.
@(private)
demand_waits :: proc(pairs: []Pair, ext: []bool, mask: u32) {
	for &p in pairs {p.waits = WAITS_NONE}
	add :: proc(pairs: []Pair, ext: []bool, j: int, s: Waits) -> bool {
		if j >= len(pairs) || (ext != nil && !ext[j]) {return false}
		w := &pairs[j].waits
		if w.q | s.q == w.q && w.p | s.p == w.p {return false}
		w.q |= s.q
		w.p |= s.p
		return true
	}
	jr := WAITS_NONE
	for changed := true; changed; {
		changed = false
		for p, i in pairs {
			if (ext != nil && !ext[i]) || leave_pair(pairs, i) {continue}
			s := waits_after(p, p.waits)
			branch := !p.ibit && p.branch != .None
			if !branch && !p.ebit {
				changed = add(pairs, ext, i + 1, s) || changed
				continue
			}
			if p.ebit {continue} // the program ends after the delay slot
			s = waits_after(pairs[i + 1], s) // leave_pair holds i + 1 in range
			switch p.branch {
			case .None:
			case .Uncond: changed = add(pairs, ext, int(branch_target(p.lw, u32(i) * 8, mask) / 8), s) || changed
			case .Cond:
				changed = add(pairs, ext, int(branch_target(p.lw, u32(i) * 8, mask) / 8), s) || changed
				changed = add(pairs, ext, int(((u32(i) * 8 + 16) & mask) / 8), s) || changed
			case .Reg: jr.q |= s.q; jr.p |= s.p
			}
		}
		for _, i in pairs {changed = add(pairs, ext, i, jr) || changed}
	}
	// A delay slot can also start with what its branch leaves.
	for &p, i in pairs {
		_, stalls := stall_waits(p, p.waits)
		p.stall = stalls &~ 1 != 0
		if i > 0 && !pairs[i - 1].ibit && pairs[i - 1].branch != .None {
			_, stalls = stall_waits(p, waits_after(pairs[i - 1], pairs[i - 1].waits))
			p.stall ||= stalls &~ 1 != 0
		}
	}
}

@(private)
branch_target :: proc(lw, pc, mask: u32) -> u32 {
	imm11 := i32(i16(u16(lw & 0x7ff) << 5) >> 5)
	return (pc + 8 + u32(imm11) * 8) & mask
}

// The pairs the switch can be entered at other than by falling through: the
// entries, every static branch target, and the pair after each branch's
// delay slot or E-bit pair (a branch's fall-through, a link register, the
// next program). Every other pc a run starts at, a computed jump's target
// among them, reaches the interpreter through the default case.
@(private)
dispatch_targets :: proc(pairs: []Pair, mask: u32, entries: []u32) -> []bool {
	target := make([]bool, len(pairs), context.temp_allocator)
	for pc in entries {
		if int(pc / 8) < len(pairs) {target[pc / 8] = true}
	}
	for p, i in pairs {
		branch := !p.ibit && p.branch != .None
		if !branch && !p.ebit {continue}
		target[(i + 2) % len(pairs)] = true
		if branch && p.branch != .Reg {
			t := int(branch_target(p.lw, u32(i) * 8, mask) / 8)
			if t < len(pairs) {target[t] = true}
		}
	}
	return target
}

// The runs of pairs in an extent, as [first, end) pair indices.
@(private)
ranges :: proc(ext: []bool) -> [dynamic][2]int {
	rs := make([dynamic][2]int, context.temp_allocator)
	for i := 0; i < len(ext); {
		if !ext[i] {
			i += 1
			continue
		}
		j := i
		for j < len(ext) && ext[j] {j += 1}
		append(&rs, [2]int{i, j})
		i = j
	}
	return rs
}

// A capture file's records (ps2/vu/capture.odin), deduped: the images by
// hash, each the offset of its micro memory in the file's data, and the
// entries by {hash, pc}, kept only for an image the file holds. The file
// is appended to and never rewritten, so a run stopped mid-write leaves its
// last record cut short: the file ends there. False, after a message, for a
// record of no kind the format has.
@(private)
Capture :: struct {
	images:  map[u64]int,
	entries: map[u64][dynamic]u32, // each image's pcs, in file order
	seen:    map[[2]u64]bool,
}

@(private)
capture_read :: proc(data: []u8, path: string, unit: Unit) -> (c: Capture, ok: bool) {
	mask := MASK[unit]
	image := int(mask) + 8
	pending: [dynamic][2]u64
	pending.allocator = context.temp_allocator
	loop: for pos := 0; pos < len(data); {
		size := 9
		switch data[pos] {
		case 'I': size += image
		case 'E': size += 4
		case:
			fmt.eprintfln("vu: %s: bad record %02x at %d", path, data[pos], pos)
			return {}, false
		}
		if pos + size > len(data) {
			fmt.eprintfln("vu: %s: last record at %d cut short; the file ends there", path, pos)
			break loop
		}
		hash := u64(endian_u64(data[pos + 1:]))
		if data[pos] == 'I' {
			if hash not_in c.images {c.images[hash] = pos + 9}
		} else {
			append(&pending, [2]u64{hash, u64(endian_u32(data[pos + 9:]) & mask)})
		}
		pos += size
	}
	for key in pending {
		if key[0] not_in c.images || key in c.seen {continue}
		c.seen[key] = true
		if key[0] not_in c.entries {c.entries[key[0]] = {}}
		append(&c.entries[key[0]], u32(key[1]))
	}
	return c, true
}

// What a unit's VU0_CAPTURE or VU1_CAPTURE file gives the recompiler: the
// XXH3-64 of its entries ({hash, pc}, the image's hash naming its micro
// memory), sorted. Records repeated by later runs leave it as it was; a new
// entry, into a new image or an old one, changes it. False for a file that
// adds no programs: missing, with no entry, or one load_capture rejects
// (after a message).
capture_fingerprint :: proc(path: string, unit: Unit) -> (fp: u64, ok: bool) {
	context.allocator = context.temp_allocator
	data, err := os.read_entire_file(path, context.allocator)
	if err == os.General_Error.Not_Exist {return 0, false}
	if err != nil {
		fmt.eprintln("vu: cannot read", path, err)
		return 0, false
	}
	c := capture_read(data, path, unit) or_return
	if len(c.seen) == 0 {return 0, false}
	keys := make([dynamic][2]u64, 0, len(c.seen))
	for key in c.seen {append(&keys, key)}
	slice.sort_by(keys[:], proc(a, b: [2]u64) -> bool {return a[0] < b[0] || a[0] == b[0] && a[1] < b[1]})
	return u64(xxhash.XXH3_64_default(slice.to_bytes(keys[:]))), true
}

// Programs from a unit's VU0_CAPTURE or VU1_CAPTURE file
// (ps2/vu/capture.odin, as capture_read reads it): for each entry into
// each captured image, the pairs reachable from it. A JR or JALR ends an
// extent; its targets were captured as entries of their own. Extents with
// the same pairs at the same addresses compile once. A missing file
// (ENOENT) adds no programs, so that microcode runs in the interpreter.
@(private)
load_capture :: proc(progs: ^[dynamic]Prog, path: string, unit: Unit) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err == os.General_Error.Not_Exist {
		fmt.eprintfln("vu: %s missing; VU%d microcode from data runs in the interpreter", path, int(unit))
		return true
	}
	if err != nil {
		fmt.eprintln("vu: cannot read", path, err)
		return false
	}
	mask := MASK[unit]
	image := int(mask) + 8
	c := capture_read(data, path, unit) or_return
	images: map[u64][]u32
	for h, at in c.images {
		w := make([]u32, image / 4)
		for &x, k in w {x = endian_u32(data[at + k * 4:])}
		images[h] = w
	}
	entries, seen := c.entries, c.seen
	hashes := make([dynamic]u64, context.temp_allocator)
	for h in images {append(&hashes, h)}
	slice.sort(hashes[:])
	// The runtime runs whichever program's ranges match the code at pc, so
	// any captured entry can enter any program.
	all: map[u32]bool
	for key in seen {all[u32(key[1])] = true}
	pcs_all := make([]u32, len(all))
	n := 0
	for pc in all {pcs_all[n] = pc; n += 1}
	slice.sort(pcs_all)
	keys: map[string]bool
	for h in hashes {
		pcs := entries[h][:]
		slice.sort(pcs)
		words := make([dynamic]u32, image / 4)
		copy(words[:], images[h])
		for pc in pcs {
			ext := extent(words[:], pc, mask)
			key := strings.builder_make()
			for r in ranges(ext) {
				fmt.sbprintf(&key, "%d:", r[0])
				for w in words[r[0] * 2:r[1] * 2] {fmt.sbprintf(&key, "%x,", w)}
			}
			if strings.to_string(key) in keys {
				strings.builder_destroy(&key)
				continue
			}
			keys[strings.to_string(key)] = true
			append(progs, Prog{words = words, ext = ext, entries = pcs_all})
		}
	}
	return true
}

@(private)
endian_u32 :: proc(b: []u8) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}
@(private)
endian_u64 :: proc(b: []u8) -> u64 {return u64(endian_u32(b)) | u64(endian_u32(b[4:])) << 32}

// The pairs control can reach from entry without leaving through a JR or
// JALR or an E bit: fallthrough, branch targets, and the return pair after
// BAL and JALR. A delay slot is included without following it.
@(private)
extent :: proc(words: []u32, entry, mask: u32) -> []bool {
	n := len(words) / 2
	ext := make([]bool, n)
	walked := make([]bool, n, context.temp_allocator)
	work := make([dynamic]int, context.temp_allocator)
	append(&work, int(entry / 8))
	for len(work) > 0 {
		i := pop(&work)
		if walked[i] {continue}
		walked[i], ext[i] = true, true
		p := classify(words[2 * i], words[2 * i + 1])
		next := (i + 1) % n
		branch := !p.ibit && p.branch != .None
		if !branch && !p.ebit {
			append(&work, next)
			continue
		}
		ext[next] = true // the delay slot
		if !branch || p.ebit {continue}
		after := (i + 2) % n
		op := p.lw >> 25
		switch p.branch {
		case .None:
		case .Uncond: append(&work, int(branch_target(p.lw, u32(i) * 8, mask) / 8))
		case .Cond: append(&work, int(branch_target(p.lw, u32(i) * 8, mask) / 8), after)
		case .Reg:
		}
		if op == 0x21 || op == 0x25 {append(&work, after)} // BAL, JALR return
	}
	return ext
}

// A unit's programs: on VU1 those of .vutext, then on either unit those of
// its capture file ("" for none).
@(private)
load_programs :: proc(img: mips.Image, capture: string, unit: Unit) -> (progs: [dynamic]Prog, ok: bool) {
	if unit == .VU1 {progs = find_programs(img) or_return}
	if capture != "" {load_capture(&progs, capture, unit) or_return}
	return progs, true
}

// Whether a unit's compiled code computes status: always on VU0, where the
// EE reads it with CFC2 and macro ops set it; on VU1 only when one of its
// programs, in any pair, compiled or not, reads it (FSEQ, FSAND, FSOR). VU1
// status is otherwise never read: the EE has no path to it, and VU0 reaches
// it only through its window onto VU1's registers (the runtime's
// vu0_window_load), at an address with bit 0x400 set that no captured VU0
// program uses; such a read sees the status VU1 last stored. Code no
// program covers runs in the interpreter, which computes status itself.
// Either read after compiled VU1 code ran without status is a compat row
// (the runtime's vu1_status_read).
@(private)
reads_status :: proc(progs: []Prog, unit: Unit) -> bool {
	if unit == .VU0 {return true}
	for p in progs {
		for i := 0; i + 1 < len(p.words); i += 2 {
			if p.words[i + 1] & (1 << 31) != 0 {continue} // an I-bit pair's lower is the I value
			switch p.words[i] >> 25 {
			case 0x14, 0x16, 0x17: return true
			}
		}
	}
	return false
}

// A program's pairs, classified, with flag and Q demand over the pairs ext
// compiles (nil: all), status demanded when status is set (reads_status),
// and the dispatch targets for its entries. Both are in the temp allocator.
@(private)
analyze :: proc(words: []u32, ext: []bool, entries: []u32, unit: Unit, status: bool) -> (pairs: []Pair, target: []bool) {
	mask := MASK[unit]
	pairs = make([]Pair, len(words) / 2, context.temp_allocator)
	for &p, i in pairs {p = classify(words[2 * i], words[2 * i + 1])}
	demand_waits(pairs, ext, mask)
	demand_flags(pairs, ext, mask, status)
	return pairs, dispatch_targets(pairs, mask, entries)
}
