//! Bitmap fonts: one PNG per character in assets/fonts/<name>/ (from
//! ZFont / ZFontEngine).

const std = @import("std");
const gfx = @import("gfx.zig");
const Assets = @import("assets.zig").Assets;

pub const Kind = enum {
    big_white,
    small_white,
    green_building,
    loading_white,
    yellow_menu,
};

const max_characters = 255;

pub const Font = struct {
    /// Most characters have no glyph.
    glyphs: [max_characters]?gfx.Image = @splat(null),

    pub fn load(a: *Assets, kind: Kind) Assets.Error!Font {
        var f: Font = .{};
        for (&f.glyphs, 0..) |*g, i| g.* = try a.find("fonts/{s}/char_{d:0>3}.png", .{ @tagName(kind), i });
        return f;
    }

    fn glyph(f: *const Font, ch: u8) ?gfx.Image {
        return if (ch < max_characters) f.glyphs[ch] else null;
    }

    pub fn width(f: *const Font, text: []const u8) i32 {
        var w: i32 = 0;
        for (text) |ch| if (f.glyph(ch)) |g| {
            w += g.width();
        };
        return w;
    }

    pub fn height(f: *const Font, text: []const u8) i32 {
        var h: i32 = 0;
        for (text) |ch| if (f.glyph(ch)) |g| {
            h = @max(h, g.height());
        };
        return h;
    }

    pub fn draw(f: *const Font, cv: gfx.Canvas, text: []const u8, x: i32, y: i32) void {
        var cx = x;
        for (text) |ch| if (f.glyph(ch)) |g| {
            cv.draw(g, cx, y);
            cx += g.width();
        };
    }

    /// Draw in a color (the fonts are white) and with transparency.
    pub fn drawTinted(f: *const Font, cv: gfx.Canvas, text: []const u8, x: i32, y: i32, color: gfx.Color, alpha: u8) void {
        var cx = x;
        for (text) |ch| if (f.glyph(ch)) |g| {
            cv.drawTinted(g, cx, y, color, alpha);
            cx += g.width();
        };
    }

    /// The text as an image (null if no character has a glyph).
    pub fn render(f: *const Font, gpa: std.mem.Allocator, text: []const u8) gfx.Image.Error!?gfx.Image {
        const w = f.width(text);
        const h = f.height(text);
        if (w == 0 or h == 0) return null;
        const img = try gfx.Image.create(gpa, w, h);
        var cx: i32 = 0;
        for (text) |ch| if (f.glyph(ch)) |g| {
            img.copy(g, cx, 0);
            cx += g.width();
        };
        return img;
    }
};

pub const Fonts = struct {
    fonts: [@typeInfo(Kind).@"enum".fields.len]Font,

    pub fn load(a: *Assets) Assets.Error!Fonts {
        var f: Fonts = undefined;
        for (&f.fonts, 0..) |*font, i| font.* = try .load(a, @enumFromInt(i));
        return f;
    }

    pub fn get(f: *const Fonts, kind: Kind) *const Font {
        return &f.fonts[@intFromEnum(kind)];
    }
};

test "render text" {
    const gpa = std.testing.allocator;
    const a = try Assets.init(gpa, "bin/assets");
    defer a.deinit();
    const fonts = try Fonts.load(a);
    const f = fonts.get(.green_building);
    try std.testing.expect(f.width("1:23") > 0);
    const img = (try f.render(gpa, "1:23")).?;
    defer img.deinit(gpa);
    try std.testing.expectEqual(f.width("1:23"), img.width());
    try std.testing.expect(try f.render(gpa, "") == null);
}
