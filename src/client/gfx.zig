//! Images and drawing for the client (from ZSDL_Surface and ZTeam in the
//! C++ engine): software rendering into plain pixel buffers.
//!
//! Every image is 32-bit ARGB, converted when loaded, so recoloring and
//! pixel effects work on the pixels directly and drawing needs no
//! conversion. SDL is only used to read image files; the finished frame
//! is shown by display.zig.

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

const amask = 0xFF000000;

/// An image: ARGB pixels (0xAARRGGBB), row after row. Whoever creates
/// one decides which allocator owns it (loaded art lives in the assets'
/// arena, see assets.zig).
pub const Image = struct {
    w: i32,
    h: i32,
    pixels: [*]u32,

    pub const Error = std.mem.Allocator.Error;
    pub const LoadError = error{ImageUnreadable} || Error;

    pub fn width(img: Image) i32 {
        return img.w;
    }

    pub fn height(img: Image) i32 {
        return img.h;
    }

    fn len(img: Image) usize {
        return @intCast(img.w * img.h);
    }

    pub fn all(img: Image) []u32 {
        return img.pixels[0..img.len()];
    }

    pub fn deinit(img: Image, gpa: std.mem.Allocator) void {
        gpa.free(img.all());
    }

    /// A new, fully transparent image.
    pub fn create(gpa: std.mem.Allocator, w: i32, h: i32) Error!Image {
        std.debug.assert(w > 0 and h > 0);
        const pixels = try gpa.alloc(u32, @intCast(w * h));
        @memset(pixels, 0);
        return .{ .w = w, .h = h, .pixels = pixels.ptr };
    }

    /// Read a BMP or PNG file.
    pub fn load(gpa: std.mem.Allocator, path: [:0]const u8) LoadError!Image {
        const raw: *c.SDL_Surface = c.SDL_LoadSurface(path.ptr) orelse return error.ImageUnreadable;
        defer c.SDL_DestroySurface(raw);
        return fromSurface(gpa, raw);
    }

    /// A copy of an SDL surface (formats without alpha come out opaque).
    pub fn fromSurface(gpa: std.mem.Allocator, s: *c.SDL_Surface) LoadError!Image {
        const argb: *c.SDL_Surface = c.SDL_ConvertSurface(s, c.SDL_PIXELFORMAT_ARGB8888) orelse return error.ImageUnreadable;
        defer c.SDL_DestroySurface(argb);
        const img = try create(gpa, argb.w, argb.h);
        const base: [*]const u8 = @ptrCast(argb.pixels.?);
        var y: i32 = 0;
        while (y < img.h) : (y += 1) {
            const src: [*]const u32 = @ptrCast(@alignCast(base + @as(usize, @intCast(y)) * @as(usize, @intCast(argb.pitch))));
            const dst = img.row(y);
            @memcpy(dst, src[0..dst.len]);
        }
        return img;
    }

    /// The image as an SDL surface sharing its pixels (to save it).
    pub fn asSurface(img: Image) ?*c.SDL_Surface {
        return c.SDL_CreateSurfaceFrom(img.w, img.h, c.SDL_PIXELFORMAT_ARGB8888, img.pixels, img.w * 4);
    }

    pub fn clone(img: Image, gpa: std.mem.Allocator) Error!Image {
        const out = try create(gpa, img.w, img.h);
        @memcpy(out.all(), img.all());
        return out;
    }

    /// Pixel rows, for direct manipulation.
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
        return img.span(y, 0, img.w);
    }

    /// `n` pixels of row `y` from column `x` (all inside the image).
    pub fn span(img: Image, y: i32, x: i32, n: i32) []u32 {
        std.debug.assert(y >= 0 and y < img.h and x >= 0 and n >= 0 and x + n <= img.w);
        const start: usize = @intCast(y * img.w + x);
        return img.pixels[start..][0..@intCast(n)];
    }

    pub fn pixel(img: Image, x: i32, y: i32) Color {
        return .fromArgb(img.span(y, x, 1)[0]);
    }

    /// A new image of this one turned `angle` degrees counterclockwise and
    /// scaled by `zoom`, nearest pixel (SDL_gfx's rotozoomSurface without
    /// smoothing, whose fixed-point stepping this follows).
    pub fn rotozoom(img: Image, gpa: std.mem.Allocator, angle: f64, zoom_in: f64) Error!Image {
        const zoom = @max(@abs(zoom_in), 0.001);
        if (@abs(angle) <= 0.001) return img.zoomed(gpa, zoom);
        const rad = angle * (std.math.pi / 180.0);
        const sin = @sin(rad) * zoom;
        const cos = @cos(rad) * zoom;
        const hw: f64 = @floatFromInt(img.width() >> 1);
        const hh: f64 = @floatFromInt(img.height() >> 1);
        const half_w: i32 = @max(@as(i32, @intFromFloat(@ceil(@max(@abs(cos * hw + sin * hh), @abs(cos * hw - sin * hh))))), 1);
        const half_h: i32 = @max(@as(i32, @intFromFloat(@ceil(@max(@abs(sin * hw + cos * hh), @abs(sin * hw - cos * hh))))), 1);
        const out = try create(gpa, 2 * half_w, 2 * half_h);
        const w = img.width();
        const h = img.height();
        const zoominv = 65536.0 / (zoom * zoom);
        const isin: i32 = @intFromFloat(sin * zoominv);
        const icos: i32 = @intFromFloat(cos * zoominv);
        const cx = half_w;
        const cy = half_h;
        const xd = (w - out.width()) *% (1 << 15);
        const yd = (h - out.height()) *% (1 << 15);
        const ax = cx *% (1 << 16) -% icos *% cx;
        const ay = cy *% (1 << 16) -% isin *% cx;
        var y: i32 = 0;
        while (y < out.height()) : (y += 1) {
            const row_out = out.row(y);
            const dy = cy - y;
            var sx = ax +% isin *% dy +% xd;
            var sy = ay -% icos *% dy +% yd;
            for (row_out) |*p| {
                const px: i32 = @as(i16, @truncate(sx >> 16));
                const py: i32 = @as(i16, @truncate(sy >> 16));
                p.* = if (px >= 0 and py >= 0 and px < w and py < h) img.span(py, px, 1)[0] else 0;
                sx +%= icos;
                sy +%= isin;
            }
        }
        return out;
    }

    /// Scaled by `zoom`, nearest pixel.
    fn zoomed(img: Image, gpa: std.mem.Allocator, zoom: f64) Error!Image {
        const w = img.width();
        const h = img.height();
        const out = try create(gpa, @max(@as(i32, @intFromFloat(@as(f64, @floatFromInt(w)) * zoom)), 1), @max(@as(i32, @intFromFloat(@as(f64, @floatFromInt(h)) * zoom)), 1));
        var y: i32 = 0;
        while (y < out.height()) : (y += 1) {
            const src = img.row(@divTrunc(y * h, out.height()));
            var x: i32 = 0;
            for (out.row(y)) |*p| {
                p.* = src[@intCast(@divTrunc(x * w, out.width()))];
                x += 1;
            }
        }
        return out;
    }

    fn bounds(img: Image) Rect {
        return .{ .x = 0, .y = 0, .w = img.width(), .h = img.height() };
    }

    /// Draw `src` (or a part of it) onto this image at (x, y): blended by
    /// its alpha, this image's alpha left as it is.
    pub fn draw(dst: Image, src: Image, part: ?Rect, x: i32, y: i32) void {
        dst.blit(src, part, x, y, false);
    }

    /// Copy `src` onto this image at (x, y), alpha included (no blending).
    pub fn copy(dst: Image, src: Image, x: i32, y: i32) void {
        dst.blit(src, null, x, y, true);
    }

    fn blit(dst: Image, src: Image, part: ?Rect, x: i32, y: i32, raw: bool) void {
        const want = part orelse src.bounds();
        const from = want.intersect(src.bounds()) orelse return;
        const at_x = x + from.x - want.x;
        const at_y = y + from.y - want.y;
        const to = (Rect{ .x = at_x, .y = at_y, .w = from.w, .h = from.h }).intersect(dst.bounds()) orelse return;
        const sx = from.x + to.x - at_x;
        const sy = from.y + to.y - at_y;
        var j: i32 = 0;
        while (j < to.h) : (j += 1) {
            const s = src.span(sy + j, sx, to.w);
            const d = dst.span(to.y + j, to.x, to.w);
            if (raw) @memcpy(d, s) else blendRow(d, s);
        }
    }

    fn blendRow(d: []u32, s: []const u32) void {
        for (d, s) |*dp, sp| {
            const a = sp >> 24;
            if (a == 0) continue;
            if (a == 255) {
                dp.* = (dp.* & amask) | (sp & 0xFFFFFF);
                continue;
            }
            const inv = 255 - a;
            const rb = (((sp & 0xFF00FF) * a + (dp.* & 0xFF00FF) * inv) >> 8) & 0xFF00FF;
            const g = (((sp & 0xFF00) * a + (dp.* & 0xFF00) * inv) >> 8) & 0xFF00;
            dp.* = (dp.* & amask) | rb | g;
        }
    }

    pub fn fill(img: Image, r: ?Rect, col: Color) void {
        const area = (r orelse img.bounds()).intersect(img.bounds()) orelse return;
        var y = area.y;
        while (y < area.y + area.h) : (y += 1) @memset(img.span(y, area.x, area.w), col.argb());
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
        var j: i32 = 0;
        while (j < visible.h) : (j += 1) {
            const src = img.span(visible.y - to.y + j, visible.x - to.x, visible.w);
            const dst = cv.target.span(visible.y + j, visible.x, visible.w);
            for (src, dst) |s, *d| {
                const a = ((s >> 24) * alpha) / 255;
                if (a == 0) continue;
                var r: u32 = (d.* >> 16) & 0xFF;
                var g: u32 = (d.* >> 8) & 0xFF;
                var b: u32 = d.* & 0xFF;
                r = (((s >> 16) & 0xFF) * a + r * (255 - a)) / 255;
                g = (((s >> 8) & 0xFF) * a + g * (255 - a)) / 255;
                b = ((s & 0xFF) * a + b * (255 - a)) / 255;
                d.* = (d.* & amask) | r << 16 | g << 8 | b;
            }
        }
    }

    /// Draw with each pixel's color scaled by `tint` (white art takes the
    /// tint's color) and extra transparency.
    pub fn drawTinted(cv: Canvas, img: Image, x: i32, y: i32, tint: Color, alpha: u8) void {
        const to = Rect{ .x = x + cv.dx, .y = y + cv.dy, .w = img.width(), .h = img.height() };
        const visible = to.intersect(cv.clip) orelse return;
        var j: i32 = 0;
        while (j < visible.h) : (j += 1) {
            const src = img.span(visible.y - to.y + j, visible.x - to.x, visible.w);
            const dst = cv.target.span(visible.y + j, visible.x, visible.w);
            for (src, dst) |s, *d| {
                const a = ((s >> 24) * alpha) / 255;
                if (a == 0) continue;
                const sr = (((s >> 16) & 0xFF) * tint.r) / 255;
                const sg = (((s >> 8) & 0xFF) * tint.g) / 255;
                const sb = ((s & 0xFF) * tint.b) / 255;
                var r: u32 = (d.* >> 16) & 0xFF;
                var g: u32 = (d.* >> 8) & 0xFF;
                var b: u32 = d.* & 0xFF;
                r = (sr * a + r * (255 - a)) / 255;
                g = (sg * a + g * (255 - a)) / 255;
                b = (sb * a + b * (255 - a)) / 255;
                d.* = (d.* & amask) | r << 16 | g << 8 | b;
            }
        }
    }

    /// The image as a white silhouette (units flash when hit).
    pub fn drawHit(cv: Canvas, img: Image, x: i32, y: i32) void {
        const to = Rect{ .x = x + cv.dx, .y = y + cv.dy, .w = img.width(), .h = img.height() };
        const visible = to.intersect(cv.clip) orelse return;
        var j: i32 = 0;
        while (j < visible.h) : (j += 1) {
            const src = img.span(visible.y - to.y + j, visible.x - to.x, visible.w);
            const dst = cv.target.span(visible.y + j, visible.x, visible.w);
            for (src, dst) |s, *d| {
                if (s & amask != 0) d.* = 0xFFFFFFFF;
            }
        }
    }

    /// The same canvas limited to `r` (in canvas coordinates).
    pub fn sub(cv: Canvas, r: Rect) Canvas {
        var out = cv;
        const to = Rect{ .x = r.x + cv.dx, .y = r.y + cv.dy, .w = r.w, .h = r.h };
        out.clip = to.intersect(cv.clip) orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return out;
    }

    /// Cover `r` with copies of `img`, cut at the right and bottom.
    pub fn tile(cv: Canvas, img: Image, r: Rect) void {
        const w = img.width();
        const h = img.height();
        if (w <= 0 or h <= 0 or r.w <= 0 or r.h <= 0) return;
        const inside = cv.sub(r);
        var y = r.y;
        while (y < r.y + r.h) : (y += h) {
            var x = r.x;
            while (x < r.x + r.w) : (x += w) inside.draw(img, x, y);
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

    pub fn load(gpa: std.mem.Allocator, assets: []const u8) TeamPalettes {
        var p: TeamPalettes = .{};
        for (0..k.Team.count) |i| {
            const team: k.Team = @enumFromInt(i);
            if (team == .none or team == .red) continue;
            var buf: [256]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/teams/{s}_palette.bmp", .{ assets, team.name() }) catch {
                std.log.warn("palette path too long: {s}", .{assets});
                continue;
            };
            const img = Image.load(gpa, path) catch |err| {
                std.log.warn("could not load {s}: {t}", .{ path, err });
                continue;
            };
            defer img.deinit(gpa);
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
    pub fn make(p: *const TeamPalettes, gpa: std.mem.Allocator, team: k.Team, red_version: Image) Image.Error!Image {
        const t = @intFromEnum(team);
        const img = try red_version.clone(gpa);
        if (!p.loaded[t]) return img;
        var it = img.rows();
        while (it.next()) |r| for (r) |*px| {
            if (px.* & amask == 0) continue;
            if (p.lookup(team, px.* & 0xFFFFFF)) |new| px.* = (px.* & amask) | (new & 0xFFFFFF);
        };
        return img;
    }
};

test "clipping" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = -5, .w = 10, .h = 10 };
    try std.testing.expectEqual(Rect{ .x = 5, .y = 0, .w = 5, .h = 5 }, a.intersect(b).?);
    try std.testing.expect(a.intersect(.{ .x = 10, .y = 0, .w = 1, .h = 1 }) == null);
}

test "images, recoloring and drawing" {
    const gpa = std.testing.allocator;
    const img = try Image.create(gpa, 4, 2);
    defer img.deinit(gpa);
    img.fill(null, .{ .r = 223, .g = 0, .b = 0 });
    img.fill(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    var p: TeamPalettes = .{};
    const blue = @intFromEnum(k.Team.blue);
    p.base[blue][0] = 0xDF0000;
    p.replace[blue][0] = 0x1337FB;
    p.loaded[blue] = true;
    const recolored = try p.make(gpa, .blue, img);
    defer recolored.deinit(gpa);
    try std.testing.expectEqual(Color{ .r = 0x13, .g = 0x37, .b = 0xFB }, recolored.pixel(1, 0));
    // Transparent pixels stay.
    try std.testing.expectEqual(@as(u8, 0), recolored.pixel(0, 0).a);

    const screen = try Image.create(gpa, 8, 8);
    defer screen.deinit(gpa);
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

test "rotating and scaling" {
    // A 4x2 image: left half red, right half blue.
    const gpa = std.testing.allocator;
    const img = try Image.create(gpa, 4, 2);
    defer img.deinit(gpa);
    for (0..2) |y| for (img.row(@intCast(y)), 0..) |*p, x| {
        p.* = if (x < 2) 0xFFFF0000 else 0xFF0000FF;
    };
    const big = try img.rotozoom(gpa, 0, 2);
    defer big.deinit(gpa);
    try std.testing.expectEqual(8, big.width());
    try std.testing.expectEqual(4, big.height());
    try std.testing.expectEqual(0xFFFF0000, big.row(3)[3]);
    try std.testing.expectEqual(0xFF0000FF, big.row(3)[4]);
    // A quarter turn counterclockwise: the right half ends up on top.
    const turned = try img.rotozoom(gpa, 90, 1);
    defer turned.deinit(gpa);
    try std.testing.expectEqual(4, turned.width());
    try std.testing.expectEqual(4, turned.height());
    try std.testing.expectEqual(0xFF0000FF, turned.row(1)[1]);
    try std.testing.expectEqual(0xFFFF0000, turned.row(3)[2]);
    // Outside the turned image is transparent.
    try std.testing.expectEqual(0, turned.row(0)[0]);
}
