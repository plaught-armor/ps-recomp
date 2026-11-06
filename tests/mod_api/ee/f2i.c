// (int)f, which compiles to trunc.w.s, an operation the R5900 FPU does not
// have: the build fails.
#include "mod_api.h"

int half;

static void before(int a0) {
	half = (int)((float)a0 * 0.5f);
}

MOD_BEFORE(ram_00100000, before);
