// A replacement that tail-calls the function it replaces, on its own
// argument plus one: `return mod_call_original(a + 1)` as a jr through a
// register, not $ra. clang does not tail call on this target, so it is
// written out, as hand-written code would.
#include "mod_api.h"

unsigned replace(unsigned a);

__asm__(".text\n"
	".globl replace\n"
	".type replace, @function\n"
	"replace:\n"
	".set noreorder\n"
	"	addiu $a0, $a0, 1\n"
	"	lui $t9, %hi(mod_call_original)\n"
	"	addiu $t9, $t9, %lo(mod_call_original)\n"
	"	jr $t9\n"
	"	nop\n"
	".set reorder\n"
	".size replace, . - replace\n");

MOD_REPLACE(start, replace);
