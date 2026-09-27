#ifndef ZFONT_ENGINE_H
#define ZFONT_ENGINE_H

#include "qzod_dnseparate_global.h"
#include "zfont.h"

// The game's fonts (implemented in Zig: src/zfont.zig).
class QZOD_DNSEPARATESHARED_EXPORT ZFontEngine
{
	public:
		// Load all fonts.
		static void Init() { zod_font_load_all(); }
		static ZFont &GetFont(int font_type)
		{
			static ZFont *zfont = MakeFonts();
			return zfont[font_type];
		}

	private:
		static ZFont *MakeFonts()
		{
			static ZFont fonts[MAX_FONT_TYPES];
			for(int i=0;i<MAX_FONT_TYPES;i++) fonts[i].SetType(i);
			return fonts;
		}
};

#endif
