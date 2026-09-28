//! Images and drawing for the client, on SDL 1.2 surfaces (from ZSDL_Surface
//! and ZTeam in the C++ engine; software rendering only).
//!
//! Every image is converted to one 32-bit ARGB format when loaded, so
//! recoloring and pixel effects can work on the pixels directly and blits
//! onto the screen need no conversion.

const std = @import("std");
const c = @import("c");
const k = @import("../game/constants.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }

    fn sdl(r: Rect) c.SDL_Rect {
        return .{ .x = @intCast(r.x), .y = @intCast(r.y), .w = @intCast(r.w), .h = @intCast(r.h) };
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn argb(col: Color) u32 {
        return @as(u32, col.a) << 24 | @as(u32, col.r) << 16 | @as(u32, col.g) << 8 | col.b;
    }

    fn fromArgb(p: u32) Color {
        return .{ .a = @truncate(p >> 24), .r = @truncate(p >> 16), .g = @truncate(p >> 8), .b = @truncate(p) };
    }
};

const rmask = 0x00FF0000;
const gmask = 0x0000FF00;
const bmask = 0x000000FF;
const amask = 0xFF000000;

/// An image (owns its SDL surface).
pub const Image = struct {
    surface: *c.SDL_Surface,

    pub fn width(img: Image) i32 {
        return img.surface.w;
    }

    pub fn height(img: Image) i32 {
        return img.surface.h;
    }

    pub fn deinit(img: Image) void {
        c.SDL_FreeSurface(img.surface);
    }

    /// Load an image file (bmp/png/...); null (and a message) if missing.
    pub fn load(path: [:0]const u8) ?Image {
        const raw: *c.SDL_Surface = c.IMG_Load(path.ptr) orelse {
            std.log.warn("could not load: {s}", .{path});
            return null;
        };
        defer c.SDL_FreeSurface(raw);
        return fromSurface(raw);
    }

    /// Like `load`, for files that may legitimately be missing.
    pub fn loadQuiet(path: [:0]const u8) ?Image {
        const raw: *c.SDL_Surface = c.IMG_Load(path.ptr) orelse return null;
        defer c.SDL_FreeSurface(raw);
        return fromSurface(raw);
    }

    /// A copy of `s` in the standard format.
    pub fn fromSurface(s: *c.SDL_Surface) ?Image {
        var format = std.mem.zeroes(c.SDL_PixelFormat);
        format.BitsPerPixel = 32;
        format.BytesPerPixel = 4;
        format.Rmask = rmask;
        format.Gmask = gmask;
        format.Bmask = bmask;
        format.Amask = amask;
        format.Rshift = 16;
        format.Gshift = 8;
        format.Bshift = 0;
        format.Ashift = 24;
        format.alpha = 255;
        const converted: *c.SDL_Surface = c.SDL_ConvertSurface(s, &format, c.SDL_SWSURFACE) orelse return null;
        // Images without an alpha channel come out fully transparent.
        if (s.format.*.Amask == 0) {
            const img: Image = .{ .surface = converted };
            if (s.flags & c.SDL_SRCCOLORKEY != 0) {
                // The color key becomes transparency.
                var kr: u8 = 0;
                var kg: u8 = 0;
                var kb: u8 = 0;
                c.SDL_GetRGB(s.format.*.colorkey, s.format, &kr, &kg, &kb);
                const key = Color.argb(.{ .r = kr, .g = kg, .b = kb, .a = 0 }) & 0xFFFFFF;
                var it = img.rows();
                while (it.next()) |r| for (r) |*p| {
                    p.* = if (p.* & 0xFFFFFF == key) 0 else p.* | amask;
                };
            } else {
                var it = img.rows();
                while (it.next()) |r| for (r) |*p| {
                    p.* |= amask;
                };
            }
        }
        _ = c.SDL_SetAlpha(converted, c.SDL_SRCALPHA, 255);
        return .{ .surface = converted };
    }

    pub fn create(w: i32, h: i32) ?Image {
        const s: *c.SDL_Surface = c.SDL_CreateRGBSurface(c.SDL_SWSURFACE, w, h, 32, rmask, gmask, bmask, amask) orelse return null;
        _ = c.SDL_SetAlpha(s, c.SDL_SRCALPHA, 255);
        return .{ .surface = s };
    }

    pub fn clone(img: Image) ?Image {
        return fromSurface(img.surface);
    }

    /// Pixel rows (ARGB), for direct manipulation.
    pub fn rows(img: Image) RowIterator {
        return .{ .img = img, .y = 0 };
    }

    pub const RowIterator = struct {
        img: Image,
        y: i32,

        pub fn next(it: *RowIterator) ?[]u32 {
            if (it.y >= it.img.height()) return null;
            defer it.y += 1;
            return it.img.row(it.y);
        }
    };

    pub fn row(img: Image, y: i32) []u32 {
        const s = img.surface;
        const base: [*]u8 = @ptrCast(s.pixels.?);
        const start: [*]u32 = @ptrCast(@alignCast(base + @as(usize, @intCast(y)) * s.pitch));
        return start[0..@intCast(s.w)];
    }

    pub fn pixel(img: Image, x: i32, y: i32) Color {
        return .fromArgb(img.row(y)[@intCast(x)]);
    }

    /// Draw `src` (or a part of it) onto this image at (x, y).
    pub fn draw(dst: Image, src: Image, part: ?Rect, x: i32, y: i32) void {
        var from = if (part) |p| p.sdl() else c.SDL_Rect{ .x = 0, .y = 0, .w = @intCast(src.width()), .h = @intCast(src.height()) };
        var to: c.SDL_Rect = .{ .x = @intCast(x), .y = @intCast(y), .w = 0, .h = 0 };
        _ = c.SDL_UpperBlit(src.surface, &from, dst.surface, &to);
    }

    /// Copy `src` onto this image at (x, y), alpha included (no blending).
    pub fn copy(dst: Image, src: Image, x: i32, y: i32) void {
        _ = c.SDL_SetAlpha(src.surface, 0, 255);
        defer _ = c.SDL_SetAlpha(src.surface, c.SDL_SRCALPHA, 255);
        dst.draw(src, null, x, y);
    }

    pub fn fill(img: Image, r: ?Rect, col: Color) void {
        var sr = if (r) |x| x.sdl() else undefined;
        _ = c.SDL_FillRect(img.surface, if (r != null) &sr else null, col.argb());
    }
};

/// The screen (or any target image) with a clip rectangle and an offset,
/// which is how the map area is drawn: map coordinates minus the view.
pub const Canvas = struct {
    target: Image,
    /// Drawing is limited to this area of the target.
    clip: Rect,
    /// Added to all coordinates.
    dx: i32 = 0,
    dy: i32 = 0,

    pub fn draw(cv: Canvas, img: Image, x: i32, y: i32) void {
        cv.drawPart(img, .{ .x = 0, .y = 0, .w = img.width(), .h = img.height() }, x, y);
    }

    pub fn drawCentered(cv: Canvas, img: Image, x: i32, y: i32) void {
        cv.draw(img, x - (img.width() >> 1), y - (img.height() >> 1));
    }

    pub fn drawPart(cv: Canvas, img: Image, part: Rect, x: i32, y: i32) void {
        const to = Rect{ .x = x + cv.dx, .y = y + cv.dy, .w = part.w, .h = part.h };
        const visible = to.intersect(cv.clip) orelse return;
        const from = Rect{ .x = part.x + visible.x - to.x, .y = part.y + visible.y - to.y, .w = visible.w, .h = visible.h };
        cv.target.draw(img, from, visible.x, visible.y);
    }

    /// Draw with extra transparency (0: invisible, 255: normal).
    pub fn drawAlpha(cv: Canvas, img: Image, x: i32, y: i32, alpha: u8) void {
        if (alpha == 255) return cv.draw(img, x, y);
        const to = Rect{ .x = x + cv.dx, .y = y + cv.dy, .w = img.width(), .h = img.height() };
        const visible = to.intersect(cv.clip) orelse return;
        const fmt = cv.target.surface.format.*;
        var j: i32 = 0;
        while (j < visible.h) : (j += 1) {
            const src = img.row(visible.y - to.y + j);
            const dst = cv.target.row(visible.y + j);
            var i: i32 = 0;
            while (i < visible.w) : (i += 1) {
                const s = src[@intCast(visible.x - to.x + i)];
                const a = ((s >> 24) * alpha) / 255;
                if (a == 0) continue;
                const d = &dst[@intCast(visible.x + i)];
                var r: u32 = (d.* & fmt.Rmask) >> @intCast(fmt.Rshift);
                var g: u32 = (d.* & fmt.Gmask) >> @intCast(fmt.Gshift);
                var b: u32 = (d.* & fmt.Bmask) >> @intCast(fmt.Bshift);
                r = (((s >> 16) & 0xFF) * a + r * (255 - a)) / 255;
                g = (((s >> 8) & 0xFF) * a + g * (255 - a)) / 255;
                b = ((s & 0xFF) * a + b * (255 - a)) / 255;
                d.* = (d.* & ~(fmt.Rmask | fmt.Gmask | fmt.Bmask)) | r << @intCast(fmt.Rshift) | g << @intCast(fmt.Gshift) | b << @intCast(fmt.Bshift);
            }
        }
    }

    /// The image as a white silhouette (units flash when hit).
    pub fn drawHit(cv: Canvas, img: Image, x: i32, y: i32) void {
        const to = Rect{ .x = x + cv.dx, .y = y + cv.dy, .w = img.width(), .h = img.height() };
        const visible = to.intersect(cv.clip) orelse return;
        var j: i32 = 0;
        while (j < visible.h) : (j += 1) {
            const src = img.row(visible.y - to.y + j);
            const dst = cv.target.row(visible.y + j);
            var i: i32 = 0;
            while (i < visible.w) : (i += 1) {
                if (src[@intCast(visible.x - to.x + i)] & amask != 0) dst[@intCast(visible.x + i)] = 0xFFFFFFFF;
            }
        }
    }

    pub fn fill(cv: Canvas, r: Rect, col: Color) void {
        const to = Rect{ .x = r.x + cv.dx, .y = r.y + cv.dy, .w = r.w, .h = r.h };
        const visible = to.intersect(cv.clip) orelse return;
        cv.target.fill(visible, col);
    }

    /// A 1 pixel rectangle outline.
    pub fn outline(cv: Canvas, r: Rect, col: Color) void {
        cv.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, col);
        cv.fill(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, col);
        cv.fill(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, col);
        cv.fill(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, col);
    }
};

// ---------------------------------------------------------------------------
// Team colors
// ---------------------------------------------------------------------------

/// Art is drawn for the red team; other teams' versions are made by
/// replacing its colors using assets/teams/<team>_palette.bmp (16 rows of
/// red color, team color).
pub const TeamPalettes = struct {
    const size = 16;
    base: [k.Team.count][size]u32 = @splat(@splat(0)),
    replace: [k.Team.count][size]u32 = @splat(@splat(0)),
    loaded: [k.Team.count]bool = @splat(false),

    pub fn load(assets: [:0]const u8) TeamPalettes {
        var p: TeamPalettes = .{};
        for (0..k.Team.count) |i| {
            const team: k.Team = @enumFromInt(i);
            if (team == .none or team == .red) continue;
            var buf: [256]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/teams/{s}_palette.bmp", .{ assets, team.name() }) catch continue;
            const img = Image.load(path) orelse continue;
            defer img.deinit();
            if (img.width() != 2) continue;
            var j: i32 = 0;
            while (j < @min(img.height(), size)) : (j += 1) {
                const r = img.row(j);
                p.base[i][@intCast(j)] = r[0] & 0xFFFFFF;
                p.replace[i][@intCast(j)] = r[1] & 0xFFFFFF;
            }
            p.loaded[i] = true;
        }
        return p;
    }

    /// The main color of a team (for the minimap, chat, ...).
    pub fn color(p: *const TeamPalettes, team: k.Team) Color {
        return switch (team) {
            .none => .{ .r = 115, .g = 115, .b = 115 },
            .red => .{ .r = 223, .g = 0, .b = 0 },
            else => .fromArgb(p.lookup(team, 0xDF0000) orelse 0xFF737373),
        };
    }

    fn lookup(p: *const TeamPalettes, team: k.Team, rgb: u32) ?u32 {
        const t = @intFromEnum(team);
        for (p.base[t], p.replace[t]) |b, r| if (b == rgb) return r | amask;
        return null;
    }

    /// `red_version` recolored for `team`.
    pub fn make(p: *const TeamPalettes, team: k.Team, red_version: Image) ?Image {
        const t = @intFromEnum(team);
        const img = red_version.clone() orelse return null;
        if (!p.loaded[t]) return img;
        var it = img.rows();
        while (it.next()) |r| for (r) |*px| {
            if (px.* & amask == 0) continue;
            if (p.lookup(team, px.* & 0xFFFFFF)) |new| px.* = (px.* & amask) | (new & 0xFFFFFF);
        };
        return img;
    }
};

/// One image per team: null and red are files (`fmt` with the team name),
/// the others are recolored from red.
pub const TeamImages = [k.Team.count]?Image;

pub fn loadTeamImages(palettes: *const TeamPalettes, comptime fmt: []const u8, args: anytype) TeamImages {
    var images: TeamImages = @splat(null);
    for (0..k.Team.count) |i| {
        const team: k.Team = @enumFromInt(i);
        if (team == .none or team == .red) {
            var buf: [512]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, fmt, args ++ .{team.name()}) catch continue;
            // Some things have no neutral version.
            images[i] = if (team == .none) Image.loadQuiet(path) else Image.load(path);
        }
    }
    if (images[@intFromEnum(k.Team.red)]) |red| {
        for (0..k.Team.count) |i| {
            if (images[i] == null) images[i] = palettes.make(@enumFromInt(i), red);
        }
    }
    return images;
}

pub fn freeTeamImages(images: *TeamImages) void {
    for (images) |*img| if (img.*) |i| {
        i.deinit();
        img.* = null;
    };
}

test "clipping" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = -5, .w = 10, .h = 10 };
    try std.testing.expectEqual(Rect{ .x = 5, .y = 0, .w = 5, .h = 5 }, a.intersect(b).?);
    try std.testing.expect(a.intersect(.{ .x = 10, .y = 0, .w = 1, .h = 1 }) == null);
}

test "images, recoloring and drawing" {
    const img = Image.create(4, 2).?;
    defer img.deinit();
    img.fill(null, .{ .r = 223, .g = 0, .b = 0 });
    img.fill(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    var p: TeamPalettes = .{};
    const blue = @intFromEnum(k.Team.blue);
    p.base[blue][0] = 0xDF0000;
    p.replace[blue][0] = 0x1337FB;
    p.loaded[blue] = true;
    const recolored = p.make(.blue, img).?;
    defer recolored.deinit();
    try std.testing.expectEqual(Color{ .r = 0x13, .g = 0x37, .b = 0xFB }, recolored.pixel(1, 0));
    // Transparent pixels stay.
    try std.testing.expectEqual(@as(u8, 0), recolored.pixel(0, 0).a);

    const screen = Image.create(8, 8).?;
    defer screen.deinit();
    screen.fill(null, .{ .r = 0, .g = 0, .b = 0 });
    const cv: Canvas = .{ .target = screen, .clip = .{ .x = 0, .y = 0, .w = 6, .h = 8 }, .dx = 2 };
    cv.drawHit(recolored, 3, 0);
    // Shifted by dx and clipped at x = 6.
    try std.testing.expectEqual(@as(u8, 255), screen.pixel(5, 1).g);
    try std.testing.expectEqual(@as(u8, 0), screen.pixel(6, 1).g);
    try std.testing.expectEqual(@as(u8, 0), screen.pixel(5, 0).g);
    cv.draw(recolored, -2, 4);
    // dx moves it to x = 0, where the transparent pixel is.
    try std.testing.expectEqual(@as(u8, 0), screen.pixel(0, 4).b);
    try std.testing.expectEqual(Color{ .r = 0x13, .g = 0x37, .b = 0xFB }, screen.pixel(1, 4));
}
