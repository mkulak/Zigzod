#ifndef ZFONT_H
#define ZFONT_H



#include "qzod_dnseparate_global.h"
#include "zsdl.h"
#include <zod_zig.h>

// -- FONT -------------------------------------
#ifndef DEF_RC_FOLDER_FONT
    #define DEF_RC_FOLDER_FONT "assets/fonts"
#endif

#define MAX_CHARACTERS 255
enum font_type
{
    BIG_WHITE_FONT, SMALL_WHITE_FONT, GREEN_BUILDING_FONT,
    LOADING_WHITE_FONT, YELLOW_MENU_FONT,
    MAX_FONT_TYPES
};

const string font_type_string[MAX_FONT_TYPES] =
{
    "big_white", "small_white", "green_building", "loading_white",
    "yellow_menu"
};

// A bitmap font. Implemented in Zig (src/zfont.zig), which owns the glyph
// images; this class only remembers which font it is.
class QZOD_DNSEPARATESHARED_EXPORT ZFont
{
	public:
		ZFont() : type(0) {}

		void Init() { zod_font_load(type); }
		void SetType(int type_) { type = type_; }
		// New surface with the rendered text (caller frees it), or nullptr.
		SDL_Surface *Render(const char *message) { return zod_font_render(type, message); }

	private:
		int type;
};

#endif
