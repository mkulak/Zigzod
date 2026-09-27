//! Zig port of ZodEgine_Libs/QZod_DnSeparate/zfont.cpp and zfont_engine.cpp:
//! the bitmap fonts (one PNG per character in assets/fonts/<name>/).
//!
//! The C++ classes ZFont / ZFontEngine remain as thin wrappers (zfont.h,
//! zfont_engine.h) so that callers keep using
//! `ZFontEngine::GetFont(type).Render(text)`.

const std = @import("std");
const c = @import("c");
const nonNull = @import("cutil.zig").nonNull;

/// Must match `enum font_type` in zfont.h.
pub const FontType = enum(c_int) {
    big_white,
    small_white,
    green_building,
    loading_white,
    yellow_menu,
};

/// Glyphs exist for characters 0..254 (MAX_CHARACTERS in zfont.h).
const max_characters = 255;

const Font = struct {
    loaded: bool = false,
    glyphs: [max_characters]?*c.SDL_Surface = @splat(null),
};

var fonts: [@typeInfo(FontType).@"enum".fields.len]Font = @splat(.{});

fn fontFor(font_type: c_int) ?*Font {
    if (font_type < 0 or font_type >= fonts.len) return null;
    return &fonts[@intCast(font_type)];
}

/// Load the glyphs of one font (missing files are simply skipped).
pub export fn zod_font_load(font_type: c_int) void {
    const font = fontFor(font_type) orelse return;
    const name = @tagName(@as(FontType, @enumFromInt(font_type)));
    for (&font.glyphs, 0..) |*glyph, i| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "assets/fonts/{s}/char_{d:0>3}.png", .{ name, i }) catch unreachable;
        glyph.* = nonNull(c.IMG_Load(path.ptr));
    }
    font.loaded = true;
}

/// Load all fonts (ZFontEngine::Init).
pub export fn zod_font_load_all() void {
    for (0..fonts.len) |i| zod_font_load(@intCast(i));
}

fn glyphFor(font: *const Font, ch: u8) ?*c.SDL_Surface {
    return if (ch < max_characters) font.glyphs[ch] else null;
}

/// Render `message` into a new 32-bit surface, or null if the font isn't
/// loaded or none of the characters has a glyph. The caller owns the result.
pub export fn zod_font_render(font_type: c_int, message: [*:0]const u8) ?*c.SDL_Surface {
    const font = fontFor(font_type) orelse return null;
    if (!font.loaded) return null;
    const text = std.mem.span(message);

    var total_width: c_int = 0;
    var max_height: c_int = 0;
    for (text) |ch| {
        const glyph = glyphFor(font, ch) orelse continue;
        total_width += glyph.w;
        max_height = @max(max_height, glyph.h);
    }
    if (total_width == 0 or max_height == 0) return null;

    const surface = nonNull(c.SDL_CreateRGBSurface(
        c.SDL_HWSURFACE | c.SDL_SRCALPHA,
        total_width,
        max_height,
        32,
        0xFF000000,
        0x0000FF00,
        0x00FF0000,
        0x000000FF,
    )) orelse return null;

    var to_rect: c.SDL_Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    for (text) |ch| {
        const glyph = glyphFor(font, ch) orelse continue;
        _ = c.SDL_UpperBlit(glyph, null, surface, &to_rect);
        to_rect.x += @intCast(glyph.w);
    }
    return surface;
}

test "font names match the asset folders" {
    try std.testing.expectEqualStrings("big_white", @tagName(FontType.big_white));
    try std.testing.expectEqualStrings("yellow_menu", @tagName(FontType.yellow_menu));
    try std.testing.expectEqual(@as(usize, 5), fonts.len);
}

test "rendering needs a loaded font" {
    try std.testing.expect(zod_font_render(0, "abc") == null);
    try std.testing.expect(zod_font_render(99, "abc") == null);
}
