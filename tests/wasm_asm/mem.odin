// Guest memory accesses through the wasm32 encoder: load, store,
// load_state, store_state and unaligned over three RAM layouts (a mirror
// and a window, a masked window and none), so every shared slow routine is
// emitted and run: case 0 makes each of them at least once, the rest are
// random. Each access lands in RAM in place, in RAM through the mirror, in
// the window, or in a runtime call, which the host logs; mem_model works
// out the memory each module must leave, as the bus and mem.LWL and the
// rest would. tests/wasm_asm/run.mjs runs them and compares.
//
// <dir>/mem.txt lists each case: its module, its imports in slot order,
// the guard byte and the page bytes (one bit each); <dir>/<k>.mem is the
// memory from M_LO to M_HI the module must end with. Both sides start the
// memory from the same formula (mem_init).
package wasm_asm

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "ps:recomp/native"

// The memory the modules see, by wasm address.
M_LO :: 1024
M_STATE :: 1024 // REGS registers of 16 bytes
M_LOG :: 1280 // the host's log: a count, then LOG_MAX entries of 3 words
M_VU :: 2048 // two 16-byte fields, through import t.vu
M_GUARD :: 2560
M_PAGES :: 2576 // M_RAM_SIZE >> M_PAGE_SHIFT bytes
M_WIN :: 4096
M_RAM :: 8192
M_HI :: M_RAM + M_RAM_SIZE

REGS :: 8
LOG_MAX :: 60
M_RAM_SIZE :: 16 << 10
M_PAGE_SHIFT :: 10
M_WIN_SIZE :: 1024
M_WIN_AT :: 0x1f800000
// What the host's t.load returns for an address.
LOAD_MUL :: 0x9e3779b1
LOAD_ADD :: 0x1234

// The log entry kinds, one per runtime procedure.
LOG_LOAD :: 1
LOG_STORE :: 2
LOG_WIDE :: 3
LOG_UNAL :: 4

MEM_SIGS := [?]native.Sig{{"t.load", 1, true}, {"t.store", 2, false}, {"t.wide", 2, false}, {"t.unal", 2, false}}

@(rodata)
MEM_GUARDS := [?]native.Guard{{"t.guard", 0x81}}

// The three layouts: as the EE's (a mirror at 0x20000000, the window at
// 0x70000000), as the IOP's (the window masked to 31 bits), and RAM only.
mem_ram :: proc(layout: int) -> native.Ram {
	r := native.Ram {
		base       = "t.ram",
		size       = M_RAM_SIZE,
		pages      = "t.pages",
		page_shift = M_PAGE_SHIFT,
		guards     = MEM_GUARDS[:],
	}
	switch layout {
	case 0:
		r.outside = 0xfe000000
		r.mirror_mask = 0xee000000
		r.mirror_bits = 0x20000000
		r.window = "t.win"
		r.window_at = 0x70000000
		r.window_size = M_WIN_SIZE
	case 1:
		r.outside = 0x1f800000
		r.window = "t.win"
		r.window_mask = 0x7fffffff
		r.window_at = M_WIN_AT
		r.window_size = M_WIN_SIZE
	case:
		r.outside = 0xfe000000
		r.guards = nil
	}
	return r
}

Mem_Kind :: enum u8 {
	Load, // cell n = the narrow value at addr
	Store, // the narrow value v at addr
	Load_Wide, // register n (or vu field n) = the w-wide value at addr
	Store_Wide, // the w-wide register n (or zero) at addr
	Unal, // op merges register n with addr
}

Mem_Op :: struct {
	kind:   Mem_Kind,
	w:      native.Width,
	signed: bool,
	zero:   bool,
	vu:     bool, // Load_Wide B128 into field n of t.vu
	unal:   native.Unal,
	n:      u32,
	addr:   u32,
	v:      u32,
}

Mem_Case :: struct {
	layout: int,
	guard:  u8,
	pages:  u16,
	ops:    [dynamic]Mem_Op,
}

// Byte i of the memory a case starts with, from M_LO; the guard and page
// bytes are the case's.
mem_init :: proc(c: Mem_Case) -> []u8 {
	m := make([]u8, M_HI - M_LO)
	for &b, i in m {b = u8((i * 131 + 7) >> 1)}
	for &b in m[M_LOG - M_LO:][:4 + 12 * LOG_MAX] {b = 0}
	m[M_GUARD - M_LO] = c.guard
	for k in 0 ..< u32(M_RAM_SIZE >> M_PAGE_SHIFT) {m[M_PAGES - M_LO + k] = u8(c.pages >> k & 1)}
	return m
}

// An address of the access: in RAM (with alias bits the mask drops), in
// the mirror, in the window (near its end too, where a wide access runs
// past it), or nowhere.
mem_addr :: proc(r: ^rand.Generator, layout: int, align: u32) -> u32 {
	off := rand.uint32(r^) % M_RAM_SIZE &~ (align - 1)
	woff := rand.uint32(r^) % M_WIN_SIZE &~ (align - 1)
	if rand.uint32(r^) % 3 == 0 {woff = (M_WIN_SIZE - 16 + rand.uint32(r^) % 16) &~ (align - 1)}
	switch rand.uint32(r^) % 5 {
	case 0, 1:
		alias := u32(0x00010000 if layout != 1 else 0x00040000)
		return off | (alias * (rand.uint32(r^) % 4))
	case 2:
		if layout == 0 {return 0x20000000 | off}
		if layout == 1 {return 0x80000000 | off}
		return off
	case 3:
		if layout == 0 {return 0x70000000 + woff}
		if layout == 1 {return (0x80000000 if rand.uint32(r^) & 1 == 0 else 0) | (M_WIN_AT + woff)}
		return 0x70000000 + woff
	}
	return 0x10000000 | off
}

mem_gen :: proc(r: ^rand.Generator, k: int) -> Mem_Case {
	c := Mem_Case{layout = k % 3, guard = u8(0x81 if rand.uint32(r^) % 6 == 0 else 0), pages = u16(rand.uint32(r^) & rand.uint32(r^))}
	if k == 0 {
		// Every slow routine at least once, in RAM in place.
		c.layout, c.guard, c.pages = 0, 0, 0
		for w in native.Width.B8 ..= native.Width.B32 {
			for s in 0 ..< 2 {append(&c.ops, Mem_Op{kind = .Load, w = w, signed = s == 1, n = 1, addr = 0x20000040})}
			append(&c.ops, Mem_Op{kind = .Store, w = w, addr = 0x100, v = 0xa1b2c3d4})
		}
		for w in native.Width.B64 ..= native.Width.B128 {
			append(&c.ops, Mem_Op{kind = .Load_Wide, w = w, n = 2, addr = 0x20000080})
			for z in 0 ..< 2 {append(&c.ops, Mem_Op{kind = .Store_Wide, w = w, n = 3, zero = z == 1, addr = 0x200})}
		}
		append(&c.ops, Mem_Op{kind = .Load_Wide, w = .B128, vu = true, n = 1, addr = 0x20000090})
		for u in native.Unal.LWL ..= native.Unal.SDR {
			for b in u32(0) ..< 2 {append(&c.ops, Mem_Op{kind = .Unal, unal = u, n = 4, addr = 0x300 + 3 * b + u32(u)})}
		}
		return c
	}
	for _ in 0 ..< 1 + rand.uint32(r^) % 16 {
		o: Mem_Op
		o.kind = Mem_Kind(rand.uint32(r^) % len(Mem_Kind))
		o.n = rand.uint32(r^) % REGS
		o.v = rand.uint32(r^)
		switch o.kind {
		case .Load, .Store:
			o.w = native.Width(rand.uint32(r^) % 3)
			o.signed = rand.uint32(r^) & 1 == 1
			o.addr = mem_addr(r, c.layout, 1 << u32(o.w))
		case .Load_Wide, .Store_Wide:
			o.w = native.Width(3 + rand.uint32(r^) % 2)
			o.zero = rand.uint32(r^) % 4 == 0
			o.vu = o.kind == .Load_Wide && o.w == .B128 && rand.uint32(r^) % 3 == 0
			if o.vu {o.n %= 2}
			o.addr = mem_addr(r, c.layout, 1 << u32(o.w))
		case .Unal:
			o.unal = native.Unal(1 + rand.uint32(r^) % 8)
			o.addr = mem_addr(r, c.layout, 1)
		}
		append(&c.ops, o)
	}
	return c
}

mem_emit :: proc(c: Mem_Case) -> (code: []u8, imports: []string) {
	a := new(native.Asm)
	a^ = native.make_asm(.Wasm32, mem_ram(c.layout))
	a.sigs = MEM_SIGS[:]
	native.func_begin(a, "t.state")
	for o in c.ops {
		native.mov_imm(a, .A, o.addr)
		switch o.kind {
		case .Load:
			native.load(a, o.w, o.signed, "t.load")
			native.state_store(a, 16 * o.n, .A)
		case .Store:
			native.mov_imm(a, .B, o.v)
			native.store(a, o.w, "t.store")
		case .Load_Wide:
			if o.vu {
				native.load_state(a, o.w, 16 * o.n, o.n, "t.wide", "t.vu")
			} else {
				native.load_state(a, o.w, 16 * o.n, o.n, "t.wide")
			}
		case .Store_Wide:
			native.store_state(a, o.w, 16 * o.n, o.n, "t.wide", o.zero)
		case .Unal:
			native.unaligned(a, o.unal, 16 * o.n, o.n, "t.unal")
		}
	}
	native.func_end(a)
	code, _ = native.finish(a)
	return code, a.imports[:]
}

// Where an access of bytes bytes at addr lands: the memory offset from
// M_LO, or -1 for a runtime call with address call. store: as a store,
// which a guard byte or a set page byte sends to the runtime. align: an
// unaligned access, on the word or doubleword its address rounds down to
// (and a window access that passes the window's end less 8 calls, as the
// routine checks 8 bytes). Through the mirror, a call is passed the RAM
// address.
mem_where :: proc(c: Mem_Case, m: []u8, addr: u32, bytes: u32, store: bool, align: u32 = 0) -> (at: int, call: u32) {
	r := mem_ram(c.layout)
	low := align == 0 ? 0 : align - 1
	if store && len(r.guards) > 0 && m[M_GUARD - M_LO] & r.guards[0].mask != 0 {return -1, addr}
	call = addr
	in_ram := addr & r.outside == 0
	if !in_ram && r.mirror_mask != 0 && addr & r.mirror_mask == r.mirror_bits {
		call = addr & (r.size - 1)
		in_ram = true
	}
	if in_ram {
		off := call & (r.size - 1) &~ low
		if store && m[M_PAGES - M_LO + int(off >> M_PAGE_SHIFT)] != 0 {return -1, call}
		return int(M_RAM - M_LO + off), call
	}
	if r.window != "" {
		w := addr & (r.window_mask if r.window_mask != 0 else max(u32))
		span := bytes if align == 0 else 8
		if w - r.window_at < r.window_size - span + 1 {
			return int(M_WIN - M_LO + (w - r.window_at) &~ low), call
		}
	}
	return -1, call
}

mem_log :: proc(m: []u8, kind, a, b: u32) {
	at := M_LOG - M_LO
	n := rd(m, at, u32)
	assert(n < LOG_MAX)
	wr(m, at, n + 1)
	wr(m, at + 4 + 12 * int(n), kind)
	wr(m, at + 8 + 12 * int(n), a)
	wr(m, at + 12 + 12 * int(n), b)
}

rd :: proc(m: []u8, at: int, $T: typeid) -> T {return (^T)(&m[at])^}
wr :: proc(m: []u8, at: int, v: $T) {(^T)(&m[at])^ = v}

// The memory case c must end with.
mem_model :: proc(c: Mem_Case) -> []u8 {
	m := mem_init(c)
	for o in c.ops {
		reg := M_STATE - M_LO + 16 * int(o.n)
		switch o.kind {
		case .Load:
			at, call := mem_where(c, m, o.addr, 1 << u32(o.w), false)
			v: u32
			if at < 0 {
				mem_log(m, LOG_LOAD, call, 0)
				v = call * LOAD_MUL + LOAD_ADD
			} else {
				#partial switch o.w {
				case .B8: v = o.signed ? u32(i32(rd(m, at, i8))) : u32(rd(m, at, u8))
				case .B16: v = o.signed ? u32(i32(rd(m, at, i16))) : u32(rd(m, at, u16))
				case .B32: v = rd(m, at, u32)
				}
			}
			wr(m, reg, v)
		case .Store:
			at, call := mem_where(c, m, o.addr, 1 << u32(o.w), true)
			if at < 0 {
				mem_log(m, LOG_STORE, call, o.v)
				continue
			}
			#partial switch o.w {
			case .B8: wr(m, at, u8(o.v))
			case .B16: wr(m, at, u16(o.v))
			case .B32: wr(m, at, o.v)
			}
		case .Load_Wide, .Store_Wide:
			n := 8 if o.w == .B64 else 16
			at, call := mem_where(c, m, o.addr, u32(n), o.kind == .Store_Wide)
			if at < 0 {
				mem_log(m, LOG_WIDE, call, o.n)
			} else if o.kind == .Load_Wide {
				field := M_VU - M_LO + 16 * int(o.n) if o.vu else reg
				copy(m[field:][:n], m[at:][:n])
			} else if o.zero {
				for &b in m[at:][:n] {b = 0}
			} else {
				copy(m[at:][:n], m[reg:][:n])
			}
		case .Unal:
			op := o.unal
			wide := op == .LDL || op == .LDR || op == .SDL || op == .SDR
			store := op >= .SWL
			at, call := mem_where(c, m, o.addr, 8, store, 8 if wide else 4)
			if at < 0 {
				mem_log(m, LOG_UNAL, call, o.n)
				continue
			}
			rt := rd(m, reg, u64)
			mw := rd(m, at, u32)
			md := rd(m, at, u64)
			s := o.addr & 3
			d := u64(o.addr & 7)
			#partial switch op {
			case .LWL:
				wr(m, reg, u64(i64(i32((u32(rt) & (0x00ffffff >> (s * 8))) | (mw << (24 - s * 8))))))
			case .LWR:
				if s == 0 {
					wr(m, reg, u64(i64(i32(mw))))
				} else {
					wr(m, reg, (u32(rt) & (0xffffffff << (32 - s * 8))) | (mw >> (s * 8)))
				}
			case .SWL:
				mask := s == 3 ? 0 : u32(0xffffff00) << (s * 8)
				wr(m, at, (mw & mask) | (u32(rt) >> (24 - s * 8)))
			case .SWR:
				mask := s == 0 ? 0 : u32(0xffffffff) >> (32 - s * 8)
				wr(m, at, (mw & mask) | (u32(rt) << (s * 8)))
			case .LDL:
				wr(m, reg, (rt & (0x00ffffff_ffffffff >> (d * 8))) | (md << (56 - d * 8)))
			case .LDR:
				mask := d == 0 ? 0 : u64(0xffffffff_ffffffff) << (64 - d * 8)
				wr(m, reg, (rt & mask) | (md >> (d * 8)))
			case .SDL:
				mask := d == 7 ? 0 : u64(0xffffffff_ffffff00) << (d * 8)
				wr(m, at, (md & mask) | (rt >> (56 - d * 8)))
			case .SDR:
				mask := d == 0 ? 0 : u64(0xffffffff_ffffffff) >> (64 - d * 8)
				wr(m, at, (md & mask) | (rt << (d * 8)))
			}
		}
	}
	return m
}

mem_cases :: proc(dir: string, n_cases: int) {
	r := rand.create(2)
	gen_r := rand.default_random_generator(&r)
	list := strings.builder_make()
	for k in 0 ..< n_cases {
		c := mem_gen(&gen_r, k)
		code, imports := mem_emit(c)
		name := fmt.tprintf("m%d.wasm", k)
		if err := os.write_entire_file(fmt.tprintf("%s/%s", dir, name), code); err != nil {
			fmt.eprintfln("%s: %v", name, err)
			os.exit(1)
		}
		if err := os.write_entire_file(fmt.tprintf("%s/m%d.mem", dir, k), mem_model(c)); err != nil {
			fmt.eprintfln("m%d.mem: %v", k, err)
			os.exit(1)
		}
		fmt.sbprintf(&list, "%s %s %d %d\n", name, strings.join(imports, ",", context.temp_allocator), c.guard, c.pages)
		free_all(context.temp_allocator)
	}
	if err := os.write_entire_file(fmt.tprintf("%s/mem.txt", dir), list.buf[:]); err != nil {
		fmt.eprintfln("mem.txt: %v", err)
		os.exit(1)
	}
	fmt.printfln("wasm_asm: %d memory cases in %s", n_cases, dir)
}
