// C headers used by the Zig code; build.zig translates this file into the
// `c` module (import with `const c = @import("c");`).
#include <SDL3/SDL.h>

#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
