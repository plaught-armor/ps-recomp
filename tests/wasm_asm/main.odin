// Random control flow through the wasm32 encoder (recomp/native/wasm.odin):
// programs of state updates, branches to labels anywhere in the function
// (forward, backward, crossing) and calls, each emitted as a module and run
// by its own interpretation here for the state it must end with.
// tests/wasm_asm/run.mjs runs the modules under Node and compares.
//
//   odin run tests/wasm_asm -collection:ps=. -- <dir> [cases]
//   node tests/wasm_asm/run.mjs <dir>
//
// <dir>/cases.txt lists each case: its module, its imports in slot order,
// the state it starts with and the one it ends with. Every branch first
// takes one from the fuel field, and the function returns when it runs out,
// so every program ends.
package wasm_asm

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "ps:recomp/native"

CELLS :: 8
FUEL :: CELLS * 4 // state offset of the fuel
FUEL_START :: 300

Op_Kind :: enum u8 {
	Add, // cell c += v
	Mix, // cell c ^= cell d << 1
	Jmp, // to label l
	Br, // to label l when cell c < v
	Call, // cell c = host(cell c, cell d)
	Call_Func, // the second function: cell 7 += 7
	Ret,
}

Op :: struct {
	kind: Op_Kind,
	c, d: u32,
	v:    u32,
	l:    int,
}

// A program: ops with labels bound before some of them.
Prog :: struct {
	ops:   []Op,
	binds: []int, // label k binds before op binds[k]; len(ops): at the end
}

State :: struct {
	cells: [CELLS]u32,
	fuel:  u32,
}

host :: proc(x, y: u32) -> u32 {return x * 31 + y}

gen :: proc(r: ^rand.Generator) -> Prog {
	context.random_generator = r^
	n := 4 + rand.int_max(40)
	n_labels := 1 + rand.int_max(8)
	ops := make([]Op, n)
	binds := make([]int, n_labels)
	for &b in binds {b = rand.int_max(n + 1)}
	for &o in ops {
		k := rand.int_max(100)
		switch {
		case k < 30:
			o = {kind = .Add, c = u32(rand.int_max(CELLS)), v = rand.uint32() % 1000}
		case k < 45:
			o = {kind = .Mix, c = u32(rand.int_max(CELLS)), d = u32(rand.int_max(CELLS))}
		case k < 55:
			o = {kind = .Jmp, l = rand.int_max(n_labels)}
		case k < 85:
			o = {kind = .Br, c = u32(rand.int_max(CELLS)), v = rand.uint32() % 4000, l = rand.int_max(n_labels)}
		case k < 92:
			o = {kind = .Call, c = u32(rand.int_max(CELLS)), d = u32(rand.int_max(CELLS))}
		case k < 97:
			o = {kind = .Call_Func}
		case:
			o = {kind = .Ret}
		}
	}
	return {ops, binds}
}

// The program run on s.
interpret :: proc(p: Prog, s: ^State) {
	at := make([]int, len(p.binds), context.temp_allocator)
	copy(at, p.binds)
	pc := 0
	for pc < len(p.ops) {
		o := p.ops[pc]
		pc += 1
		switch o.kind {
		case .Add:
			s.cells[o.c] += o.v
		case .Mix:
			s.cells[o.c] ~= s.cells[o.d] << 1
		case .Call:
			s.cells[o.c] = host(s.cells[o.c], s.cells[o.d])
		case .Call_Func:
			s.cells[7] += 7
		case .Ret:
			return
		case .Jmp, .Br:
			s.fuel -= 1
			if s.fuel == 0 {return}
			if o.kind == .Jmp || s.cells[o.c] < o.v {pc = at[o.l]}
		}
	}
}

emit :: proc(a: ^native.Asm, p: Prog, second: native.Label) {
	labels := make([]native.Label, len(p.binds), context.temp_allocator)
	for &l in labels {l = native.new_label(a)}
	out := native.new_label(a)
	native.func_begin(a, "t.state")
	for pc in 0 ..= len(p.ops) {
		for b, k in p.binds {
			if b == pc {native.bind(a, labels[k])}
		}
		if pc == len(p.ops) {break}
		o := p.ops[pc]
		switch o.kind {
		case .Add:
			native.state_load(a, .A, 4 * o.c)
			native.alu_imm(a, .Add, .A, o.v)
			native.state_store(a, 4 * o.c, .A)
		case .Mix:
			native.state_load(a, .A, 4 * o.c)
			native.state_load(a, .B, 4 * o.d)
			native.alu_imm(a, .Shl, .B, 1)
			native.alu(a, .Xor, .A, .B)
			native.state_store(a, 4 * o.c, .A)
		case .Call:
			native.state_load(a, .A, 4 * o.c)
			native.state_load(a, .B, 4 * o.d)
			native.call(a, "t.host", .A, .B)
			native.state_store(a, 4 * o.c, .A)
		case .Call_Func:
			native.call_func(a, second)
		case .Ret:
			native.ret(a)
		case .Jmp, .Br:
			native.state_load(a, .T, FUEL)
			native.alu_imm(a, .Sub, .T, 1)
			native.state_store(a, FUEL, .T)
			native.br_zero(a, .T, out)
			if o.kind == .Jmp {
				native.jmp(a, labels[o.l])
			} else {
				native.state_load(a, .A, 4 * o.c)
				native.br_cmp_imm(a, .Ltu, .A, o.v, labels[o.l])
			}
		}
	}
	native.bind(a, out)
	native.func_end(a)
}

SIGS := [?]native.Sig{{"t.host", 2, true}}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: wasm_asm <dir> [cases]")
		os.exit(2)
	}
	dir := os.args[1]
	n_cases := 2000
	if len(os.args) > 2 {n_cases, _ = strconv.parse_int(os.args[2])}
	r := rand.create(1)
	gen_r := rand.default_random_generator(&r)
	list := strings.builder_make()
	for k in 0 ..< n_cases {
		p := gen(&gen_r)
		a := native.make_asm(.Wasm32)
		a.sigs = SIGS[:]
		second := native.new_label(&a)
		emit(&a, p, second)
		idx := native.func_begin(&a, "t.state")
		native.bind_at(&a, second, idx)
		native.state_load(&a, .A, 28)
		native.alu_imm(&a, .Add, .A, 7)
		native.state_store(&a, 28, .A)
		native.func_end(&a)
		m, _ := native.finish(&a)
		name := fmt.tprintf("%d.wasm", k)
		if err := os.write_entire_file(fmt.tprintf("%s/%s", dir, name), m); err != nil {
			fmt.eprintfln("%s: %v", name, err)
			os.exit(1)
		}
		s: State
		for &c, i in s.cells {c = u32(k * 977 + i * 131) % 3000}
		s.fuel = FUEL_START
		fmt.sbprintf(&list, "%s %s", name, strings.join(a.imports[:], ",", context.temp_allocator))
		for c in s.cells {fmt.sbprintf(&list, " %d", c)}
		fmt.sbprintf(&list, " %d", s.fuel)
		interpret(p, &s)
		for c in s.cells {fmt.sbprintf(&list, " %d", c)}
		fmt.sbprintf(&list, " %d\n", s.fuel)
		free_all(context.temp_allocator)
	}
	if err := os.write_entire_file(fmt.tprintf("%s/cases.txt", dir), list.buf[:]); err != nil {
		fmt.eprintfln("cases.txt: %v", err)
		os.exit(1)
	}
	fmt.printfln("wasm_asm: %d cases in %s", n_cases, dir)
}
