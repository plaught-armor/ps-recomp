// A mod that defines a name mod_api.h gives a game function: mod.ld would
// send the mod's own calls to the game, so build.sh must refuse it.
#include "mod_api.h"

unsigned start(void) { return 7; }

unsigned use(void) { return start(); }
