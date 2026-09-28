//! Bitmap fonts: one PNG per character in assets/fonts/<name>/ (from
//! ZFont / ZFontEngine).

const std = @import("std");
const gfx = @import("gfx.zig");

pub const Kind = enum {
    big_white,
    small_white,
    green_building,
    loading_white,
    yellow_menu,
};

const max_characters = 255;

pub const Font = struct {
    glyphs: [max_characters]?gfx.Image = @splat(null),

    pub fn load(assets: []const u8, kind: Kind) Font {
        var f: Font = .{};
        for (&f.glyphs, 0..) |*g, i| {
            var buf: [256]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/fonts/{s}/char_{d:0>3}.png", .{ assets, @tagName(kind), i }) catch continue;
            // Most characters have no glyph; don't complain about them.
            g.* = gfx.Image.loadQuiet(path);
        }
        return f;
    }

    pub fn deinit(f: *Font) void {
        for (&f.glyphs) |*g| if (g.*) |img| {
            img.deinit();
            g.* = null;
        };
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
    pub fn render(f: *const Font, text: []const u8) ?gfx.Image {
        const w = f.width(text);
        const h = f.height(text);
        if (w == 0 or h == 0) return null;
        const img = gfx.Image.create(w, h) orelse return null;
        img.fill(null, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
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

    pub fn load(assets: []const u8) Fonts {
        var f: Fonts = undefined;
        for (&f.fonts, 0..) |*font, i| font.* = .load(assets, @enumFromInt(i));
        return f;
    }

    pub fn deinit(f: *Fonts) void {
        for (&f.fonts) |*font| font.deinit();
    }

    pub fn get(f: *const Fonts, kind: Kind) *const Font {
        return &f.fonts[@intFromEnum(kind)];
    }
};

test "render text" {
    var fonts = Fonts.load("bin/assets");
    defer fonts.deinit();
    const f = fonts.get(.green_building);
    try std.testing.expect(f.width("1:23") > 0);
    const img = f.render("1:23").?;
    defer img.deinit();
    try std.testing.expectEqual(f.width("1:23"), img.width());
    try std.testing.expect(f.render("") == null);
}
