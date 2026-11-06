// Mod data test (core/mod.odin): a mod.tsv parses, and bad ones are refused
// with an error naming the problem; mods load dependencies first, keep
// before/after hints and otherwise the user's order; a missing or too old
// dependency, a cycle, two mods with one id and a wrong api are load
// errors; hook chains run befores in load order, afters in reverse, and two
// replacements of one function are an error naming both mods.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL mod: %s (line %d)", what, loc.line)
		failed += 1
	}
}

// A manifest with id, version 1.0.0 and this runtime's api.
@(private = "file")
mod :: proc(id: string, deps: []core.Mod_Dep = nil, before: []string = nil, after: []string = nil) -> core.Mod_Manifest {
	return {id = id, version = {1, 0, 0}, api = core.MOD_API, deps = deps, before = before, after = after}
}

// The ids of mods in order, joined by spaces.
@(private = "file")
ids :: proc(mods: []core.Mod_Manifest, order: []int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k, n in order {
		if n != 0 {strings.write_byte(&b, ' ')}
		strings.write_string(&b, mods[k].id)
	}
	return strings.to_string(b)
}

test_manifest :: proc() {
	text := "# a comment\r\nid\tmore-hp\nversion\t1.2.3\napi\t1\nname\tMore HP\ngame\tSLUS-00001\n\ndeps\tbase, util>=0.4.10\nbefore\tlate\nafter\tearly,mid\nfiles\tmod.elf\n"
	m, err := core.mod_manifest_parse(text, context.temp_allocator)
	check(err == "", err)
	check(m.id == "more-hp" && m.version == core.Mod_Version{1, 2, 3} && m.api == 1, "id, version, api")
	check(m.name == "More HP" && m.game == "SLUS-00001" && m.disc == "" && m.files == "mod.elf", "strings")
	check(len(m.deps) == 2 && m.deps[0].id == "base" && m.deps[0].min == core.Mod_Version{} && m.deps[1].id == "util" && m.deps[1].min == core.Mod_Version{0, 4, 10}, "deps")
	check(len(m.before) == 1 && m.before[0] == "late" && len(m.after) == 2 && m.after[1] == "mid", "before, after")

	Bad :: struct {
		text, err: string,
	}
	bad := []Bad {
		{"id\tx\nversion\t1.0.0\n", "mod.tsv: no api"},
		{"version\t1.0.0\napi\t1\n", "mod.tsv: no id"},
		{"id\tx\nid\ty\n", "mod.tsv: id twice"},
		{"id\tx\nsize\t3\n", "mod.tsv: bad line \"size\\t3\""},
		{"id x\n", "mod.tsv: bad line \"id x\""},
		{"id\tBig\n", "mod.tsv: bad id \"Big\""},
		{"id\t.x\n", "mod.tsv: bad id \".x\""},
		{"version\t1.2\n", "mod.tsv: bad version \"1.2\""},
		{"version\t1.2.x\n", "mod.tsv: bad version \"1.2.x\""},
		{"version\t1.2.4294967296\n", "mod.tsv: bad version \"1.2.4294967296\""},
		{"api\t1.0\n", "mod.tsv: bad api \"1.0\""},
		{"deps\ta,,b\n", "mod.tsv: bad deps \"a,,b\""},
		{"deps\ta>=1\n", "mod.tsv: bad deps \"a>=1\""},
		{"after\t\n", "mod.tsv: bad after \"\""},
	}
	for b in bad {
		_, e := core.mod_manifest_parse(b.text, context.temp_allocator)
		check(e == b.err, fmt.tprintf("%q: got %q, want %q", b.text, e, b.err))
	}
	check(core.mod_id_ok(strings.repeat("a", core.MOD_ID_MAX, context.temp_allocator)), "longest id")
	check(!core.mod_id_ok(strings.repeat("a", core.MOD_ID_MAX + 1, context.temp_allocator)), "id too long")
}

test_order :: proc() {
	// c needs a, a loads after b by hint, d before b by hint; the user
	// lists c first, so the free choices follow the user, then ids.
	mods := []core.Mod_Manifest {
		mod("a", after = {"b"}),
		mod("b"),
		mod("c", deps = {{id = "a"}}),
		mod("d", before = {"b", "absent"}),
		mod("e"),
	}
	order, err := core.mod_order(mods, {"c", "e"}, context.temp_allocator)
	check(err == "", err)
	got := ids(mods, order)
	check(got == "e d b a c", got)

	// No dependencies or hints: exactly the user's order, then the rest by id.
	free := []core.Mod_Manifest{mod("z"), mod("y"), mod("x"), mod("w")}
	order, err = core.mod_order(free, {"y", "w"}, context.temp_allocator)
	check(err == "", err)
	got = ids(free, order)
	check(got == "y w x z", got)

	Bad :: struct {
		mods: []core.Mod_Manifest,
		err:  string,
	}
	old := mod("base")
	old.version = {0, 9, 2}
	wrong_api := mod("next")
	wrong_api.api = core.MOD_API + 1
	bad := []Bad {
		{{mod("a", deps = {{id = "base"}})}, "mod a needs base, which is not loaded"},
		{{mod("a", deps = {{id = "base", min = {1, 0, 0}}}), old}, "mod a needs base 1.0.0, loaded is 0.9.2"},
		{{mod("a"), mod("a")}, "mod: two mods are a"},
		{{mod("a"), wrong_api}, fmt.tprintf("mod next: api %d, this runtime has %d", core.MOD_API + 1, core.MOD_API)},
		{{mod("a", deps = {{id = "b"}}), mod("b", deps = {{id = "a"}}), mod("c")}, "mod: a, b wait on each other (dependency or before/after cycle)"},
		{{mod("a", before = {"b"}), mod("b", before = {"a"})}, "mod: a, b wait on each other (dependency or before/after cycle)"},
		{{mod("a", deps = {{id = "a"}})}, "mod: a wait on each other (dependency or before/after cycle)"},
	}
	for b in bad {
		o, e := core.mod_order(b.mods, nil, context.temp_allocator)
		check(o == nil, "no order on error")
		check(e == b.err, fmt.tprintf("got %q, want %q", e, b.err))
	}
}

test_chains :: proc() {
	mods := []core.Mod_Manifest{mod("a"), mod("b"), mod("c")}
	order := []int{2, 0, 1} // c, a, b
	f := core.Mod_Key{addr = 0x800f8844, sig = {0x27bdffe0, 0xafbf0018, 0, 0}}
	g := core.Mod_Key{slot = 0x801cc800, id = 0x27bdffd8, addr = 0x801dc798, sig = {0x27bdffd8, 0xafb00010, 0, 0}}
	hooks := []core.Mod_Hook {
		{f, .After, 0, 0x1f400010},
		{f, .Before, 1, 0x1f410000},
		{g, .Replace, 1, 0x1f410020},
		{f, .Before, 0, 0x1f400000},
		{f, .After, 2, 0x1f420010},
		{f, .Before, 2, 0x1f420000},
		{f, .After, 1, 0x1f410010},
	}
	chains, err := core.mod_chains(mods, order, hooks)
	check(err == "", err)
	defer core.mod_chains_delete(chains)
	check(len(chains) == 2, "two chains")
	if len(chains) != 2 {return}
	cf, cg := chains[0], chains[1]
	check(cf.key == f && cg.key == g, "chains by key")
	check(len(cf.before) == 3 && cf.before[0] == core.Mod_Fn{2, 0x1f420000} && cf.before[1] == core.Mod_Fn{0, 0x1f400000} && cf.before[2] == core.Mod_Fn{1, 0x1f410000}, "befores in load order")
	check(len(cf.after) == 3 && cf.after[0] == core.Mod_Fn{1, 0x1f410010} && cf.after[1] == core.Mod_Fn{0, 0x1f400010} && cf.after[2] == core.Mod_Fn{2, 0x1f420010}, "afters in reverse load order")
	_, has := cf.replace.?
	check(!has, "f not replaced")
	r, ok := cg.replace.?
	check(ok && r == core.Mod_Fn{1, 0x1f410020} && len(cg.before) == 0 && len(cg.after) == 0, "g replaced by b")

	// The same address in another overlay, or with other code, is another
	// function.
	h := g
	h.id = 0x27bdffe0
	k := g
	k.sig[3] = 1
	two := []core.Mod_Hook{{g, .Replace, 0, 0x1f400000}, {h, .Replace, 1, 0x1f410000}, {k, .Replace, 2, 0x1f420000}}
	chains2, err2 := core.mod_chains(mods, order, two)
	check(err2 == "" && len(chains2) == 3, "one replace per overlay and code")
	core.mod_chains_delete(chains2)

	double := []core.Mod_Hook{{g, .Before, 2, 0x1f420000}, {g, .Replace, 1, 0x1f410020}, {g, .Replace, 0, 0x1f400020}}
	c3, e3 := core.mod_chains(mods, order, double)
	check(c3 == nil, "no chains on error")
	want := "mod: a (1f400020) and b (1f410020) both replace 801dc798 (slot 801cc800 id 27bdffd8)"
	check(e3 == want, fmt.tprintf("got %q, want %q", e3, want))

	stray := []core.Mod_Hook{{f, .Before, 3, 0x1f430000}}
	c4, e4 := core.mod_chains(mods, order, stray)
	check(c4 == nil && e4 == "mod: a hook on 800f8844 is from no loaded mod", e4)
	c5, e5 := core.mod_chains(mods, []int{0, 1}, {{f, .Before, 2, 0x1f420000}})
	check(c5 == nil && e5 == "mod: a hook on 800f8844 is from no loaded mod", e5)

	none, e6 := core.mod_chains(mods, order, nil)
	check(e6 == "" && len(none) == 0, "no hooks, no chains")
	core.mod_chains_delete(none)
}

main :: proc() {
	test_manifest()
	test_order()
	test_chains()
	free_all(context.temp_allocator)
	if failed != 0 {os.exit(1)}
	fmt.println("ok mod")
}
