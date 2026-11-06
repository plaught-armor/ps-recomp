// A mod with one hook of each kind on the fixture's functions, by name and
// by alias, calling a game function and one of its own.
#include "mod_api.h"

unsigned calls;

__attribute__((noinline)) static unsigned twice(unsigned x) { return x * 2; }

static void before(void) { calls = twice(calls) + 1; }
static void after(void) { calls += ram_80010000(); }
// A tail call to the game: long_call makes it a jr, not a j out of the image.
static unsigned replace(unsigned a) { return ((unsigned (*)(unsigned))ram_80010008)(a + calls); }

MOD_BEFORE(start, before);
MOD_AFTER(ov_a_80100004, after);
MOD_REPLACE(b_fn, replace);
