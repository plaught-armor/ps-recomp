// The signatures wasm32 native code calls the runtime with (r5900.EE_SIGS)
// against the procedures' types (ps2.native_imports): every procedure has
// one, with as many arguments, each an integer of at most 32 bits, and a
// result exactly when the signature has one, under the Odin calling
// convention, which passes the context last.
package wasm_sigs

import "base:runtime"
import "core:fmt"
import "core:os"
import "ps:ps2"
import "ps:recomp/r5900"

failed := false

fail :: proc(format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
	failed = true
}

// Whether t is passed in one i32 on wasm32. The test runs on the host, so
// int, uint and uintptr, which are 32 bits on wasm32, are allowed by name.
narrow :: proc(t: ^runtime.Type_Info) -> bool {
	switch t.id {
	case int, uint, uintptr:
		return true
	}
	#partial switch v in runtime.type_info_base(t).variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Boolean, runtime.Type_Info_Rune:
		return t.size <= 4
	case runtime.Type_Info_Enum:
		return t.size <= 4
	}
	return false
}

main :: proc() {
	types: map[string]typeid
	_ = ps2.native_imports(&types)
	seen: map[string]bool
	for s in r5900.EE_SIGS {
		if s.name in seen {fail("%s: two signatures", s.name)}
		seen[s.name] = true
		id, ok := types[s.name]
		if !ok {
			fail("%s: a signature but no imported procedure", s.name)
			continue
		}
		p, is_proc := runtime.type_info_base(type_info_of(id)).variant.(runtime.Type_Info_Procedure)
		if !is_proc {
			fail("%s: not a procedure", s.name)
			continue
		}
		if p.convention != .Odin {fail("%s: calling convention %v", s.name, p.convention)}
		n := 0
		if p.params != nil {
			ps := p.params.variant.(runtime.Type_Info_Parameters)
			n = len(ps.types)
			for t, k in ps.types {
				if !narrow(t) {fail("%s: argument %d is %v, not one i32", s.name, k, t.id)}
			}
		}
		if n != int(s.args) {fail("%s: %d arguments; its signature has %d", s.name, n, s.args)}
		r := 0
		if p.results != nil {
			rs := p.results.variant.(runtime.Type_Info_Parameters)
			r = len(rs.types)
			for t in rs.types {
				if !narrow(t) {fail("%s: result %v, not one i32", s.name, t.id)}
			}
		}
		if r != (1 if s.result else 0) {fail("%s: %d results; its signature has result %v", s.name, r, s.result)}
	}
	for name in types {
		if !(name in seen) {fail("%s: imported procedure with no signature", name)}
	}
	if failed {os.exit(1)}
	fmt.printfln("wasm_sigs: %d signatures agree", len(r5900.EE_SIGS))
}
