// The VU programs a conversion compiles, and what is known of their pairs,
// for every backend that emits them (vu.odin: Odin source).
//
// Programs are VU1 .vutext programs and the extents of captured micro
// images (vu.odin's header). Each is classified pair by pair: branches, the
// order of its halves against the interpreter's vu_pair, where MAC is live,
// and the pairs a run can enter at other than by falling through.
package vu

import "core:fmt"
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
	mac_rd:     bool, // reads MAC before writing it
	mac_wr:     bool, // the upper op sets MAC
	mac_live:   bool, // MAC after this pair can be read
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
	p.mac_wr = upper_writes_mac(uw)
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
		if uw & 0x7ff != 0x1ff {p.mode = .Serial}
	case 0x10, 0x12, 0x13, 0x1c, 0x18, 0x1a, 0x1b: // FCEQ/FCAND/FCOR/FCGET, FMEQ/FMAND/FMOR
		p.mode = .Lower_First
		p.mac_rd = lw >> 25 >= 0x18 && lw >> 25 <= 0x1b
	case 0x40:
		if lw & 63 < 0x3c {
			p.mode = .Serial
			break
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x3b, 0x3e, 0x3f, 0x68, 0x69, 0x6c, 0x7b: p.mode = .Serial
		// DIV, SQRT and RSQRT also share status: dead on VU1, merged as
		// vu_pair does by emit_pair on VU0
		case: p.mode = touches ? .Hazard : .Serial
		}
	}
	if p.mode == .Slow {p.mac_rd = true} // vu_pair merges against the old flags
	return p
}

// Backward dataflow: MAC after pair n is live when a successor reads it
// before setting it, or control can leave compiled code.
@(private)
mac_liveness :: proc(pairs: []Pair, ext: []bool, mask: u32) {
	n := len(pairs)
	live_in := make([]bool, n, context.temp_allocator)
	at :: proc(live_in, ext: []bool, pc: int) -> bool {
		i := pc / 8
		return i >= len(live_in) || (ext != nil && !ext[i]) ? true : live_in[i]
	}
	for changed := true; changed; {
		changed = false
		for i := n - 1; i >= 0; i -= 1 {
			p := &pairs[i]
			out := at(live_in, ext, (i + 1) * 8)
			if i > 0 && !pairs[i - 1].ibit { // a delay slot also goes to the target
				prev := pairs[i - 1]
				switch prev.branch {
				case .None:
				case .Reg: out = true
				case .Uncond, .Cond: out ||= at(live_in, ext, int(branch_target(prev.lw, u32(i - 1) * 8, mask)))
				}
				if prev.ebit {out = true}
			}
			if p.ebit && i + 1 < n {pairs[i + 1].mac_live = true}
			out ||= p.mac_live
			inn := p.mac_rd || (!p.mac_wr && out)
			if out != p.mac_live || inn != live_in[i] {changed = true}
			p.mac_live, live_in[i] = out, inn
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

// Programs from a unit's VU0_CAPTURE or VU1_CAPTURE file
// (ps2/vu/capture.odin): for each entry into each captured image, the pairs
// reachable from it. A JR or JALR ends an extent; its targets were captured
// as entries of their own. Extents with the same pairs at the same addresses
// compile once. A missing file (ENOENT) adds no programs, so that microcode
// runs in the interpreter.
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
	images: map[u64][]u32
	entries: map[u64][dynamic]u32
	seen: map[[2]u64]bool
	for pos := 0; pos < len(data); {
		if pos + 9 > len(data) {
			fmt.eprintfln("vu: %s: record at %d cut short", path, pos)
			return false
		}
		kind := data[pos]
		hash := u64(endian_u64(data[pos + 1:]))
		switch kind {
		case 'I':
			if pos + 9 + image > len(data) {
				fmt.eprintfln("vu: %s: image at %d cut short", path, pos)
				return false
			}
			if hash not_in images {
				w := make([]u32, image / 4)
				for &x, k in w {x = endian_u32(data[pos + 9 + k * 4:])}
				images[hash] = w
			}
			pos += 9 + image
		case 'E':
			if pos + 13 > len(data) {
				fmt.eprintfln("vu: %s: entry at %d cut short", path, pos)
				return false
			}
			pc := endian_u32(data[pos + 9:]) & mask
			key := [2]u64{hash, u64(pc)}
			if key not_in seen {
				seen[key] = true
				if hash not_in entries {entries[hash] = {}}
				append(&entries[hash], pc)
			}
			pos += 13
		case:
			fmt.eprintfln("vu: %s: bad record %02x at %d", path, kind, pos)
			return false
		}
	}
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

// A program's pairs, classified, with MAC liveness over the pairs ext
// compiles (nil: all), and the dispatch targets for its entries. Both are
// in the temp allocator.
@(private)
analyze :: proc(words: []u32, ext: []bool, entries: []u32, unit: Unit) -> (pairs: []Pair, target: []bool) {
	mask := MASK[unit]
	pairs = make([]Pair, len(words) / 2, context.temp_allocator)
	for &p, i in pairs {p = classify(words[2 * i], words[2 * i + 1])}
	mac_liveness(pairs, ext, mask)
	return pairs, dispatch_targets(pairs, mask, entries)
}
