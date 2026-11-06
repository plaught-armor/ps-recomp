// A replacement that runs the function it replaces, past its hooks, on its
// own argument plus one: mod_call_original is long_call too.
#include "mod_api.h"

static unsigned replace(unsigned a) { return ((unsigned (*)(unsigned))mod_call_original)(a + 1) * 2; }

MOD_REPLACE(start, replace);
