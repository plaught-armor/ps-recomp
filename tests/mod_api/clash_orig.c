// A mod that defines mod_call_original, the runtime's name in mod_api.h:
// build.sh must refuse it as it does a game function's.
#include "mod_api.h"

unsigned mod_call_original(void) { return 7; }
