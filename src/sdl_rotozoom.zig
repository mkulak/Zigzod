//! Zig port of ZodEgine_Libs/QZod_DnSeparate/SDL_rotozoom.cpp, the
//! rotozoomer from SDL_gfx.
//!
//!   SDL_rotozoom - rotozoomer for 32bit or 8bit surfaces
//!   LGPL (c) A. Schiffler
//!
//! This port is a derivative of that code and is under the same license
//! (LGPL). Only the functions the engine uses are kept: rotozoomSurface(),
//! rotozoomSurfaceXY() and the size helpers.
//!
//! Behaviour matches the original, except that bilinear smoothing no
//! longer reads past the last row/column of the source image (the
//! original read out of bounds there); those neighbours are clamped to the
//! edge instead.

const std = @import("std");
const c = @import("c");

const Surface = c.SDL_Surface;

const nonNull = @import("cutil.zig").nonNull;

/// Below this, a zoom factor or angle counts as zero (VALUE_LIMIT).
const value_limit = 0.001;

/// A 32-bit pixel; the channel order doesn't matter, all four are treated alike.
const Rgba = extern struct { r: u8, g: u8, b: u8, a: u8 };

/// Pixel access to a locked surface.
fn View(comptime Pixel: type) type {
    return struct {
        pixels: [*]u8,
        pitch: usize,
        w: i32,
        h: i32,

        const Self = @This();

        fn init(s: *Surface) Self {
            return .{
                .pixels = @ptrCast(s.pixels.?),
                .pitch = s.pitch,
                .w = s.w,
                .h = s.h,
            };
        }

        /// Pointer to pixel (x, y); coordinates are clamped to the image.
        fn at(self: Self, x: i32, y: i32) *align(1) Pixel {
            const cx: usize = @intCast(std.math.clamp(x, 0, self.w - 1));
            const cy: usize = @intCast(std.math.clamp(y, 0, self.h - 1));
            return @ptrCast(self.pixels + cy * self.pitch + cx * @sizeOf(Pixel));
        }
    };
}

/// Bilinear interpolation of one channel, in 16.16 fixed point exactly as
/// the original computed it.
fn lerpChannel(c00: u8, c01: u8, c10: u8, c11: u8, ex: i32, ey: i32) u8 {
    const t1 = ((((@as(i32, c01) - c00) * ex) >> 16) + c00) & 0xff;
    const t2 = ((((@as(i32, c11) - c10) * ex) >> 16) + c10) & 0xff;
    return @truncate(@as(u32, @bitCast((((t2 - t1) * ey) >> 16) + t1)));
}

fn lerpPixel(p00: Rgba, p01: Rgba, p10: Rgba, p11: Rgba, ex: i32, ey: i32) Rgba {
    return .{
        .r = lerpChannel(p00.r, p01.r, p10.r, p11.r, ex, ey),
        .g = lerpChannel(p00.g, p01.g, p10.g, p11.g, ex, ey),
        .b = lerpChannel(p00.b, p01.b, p10.b, p11.b, ex, ey),
        .a = lerpChannel(p00.a, p01.a, p10.a, p11.a, ex, ey),
    };
}

/// The four neighbours of (x, y) for smoothing, swapped as the original
/// did when flipping.
fn neighbours(src: View(Rgba), x: i32, y: i32, flipx: bool, flipy: bool) [4]Rgba {
    var p00 = src.at(x, y).*;
    var p01 = src.at(x + 1, y).*;
    var p10 = src.at(x, y + 1).*;
    var p11 = src.at(x + 1, y + 1).*;
    if (flipx) {
        std.mem.swap(Rgba, &p00, &p01);
        std.mem.swap(Rgba, &p10, &p11);
    }
    if (flipy) {
        std.mem.swap(Rgba, &p00, &p10);
        std.mem.swap(Rgba, &p01, &p11);
    }
    return .{ p00, p01, p10, p11 };
}

// ---------------------------------------------------------------------------
// Zoom only (angle == 0)
// ---------------------------------------------------------------------------

/// Fixed-point source positions for each destination column/row: entry i
/// holds the fraction for destination pixel i in the low 16 bits and, in the
/// high bits, how many source pixels to move on after it.
fn zoomSteps(allocator: std.mem.Allocator, dst_len: i32, step: i32) ![]i32 {
    const steps = try allocator.alloc(i32, @intCast(dst_len + 1));
    var acc: i32 = 0;
    for (steps) |*s| {
        s.* = acc;
        acc &= 0xffff;
        acc += step;
    }
    return steps;
}

fn zoomRgba(src_s: *Surface, dst_s: *Surface, flipx: bool, flipy: bool, smooth: bool) !void {
    const src = View(Rgba).init(src_s);
    const dst = View(Rgba).init(dst_s);
    const allocator = std.heap.c_allocator;

    // With smoothing, the source counts as one pixel smaller so the last
    // interpolation step stays inside the image.
    const shrink: f32 = if (smooth) 1 else 0;
    const sx: i32 = @intFromFloat(65536.0 * (@as(f32, @floatFromInt(src.w)) - shrink) / @as(f32, @floatFromInt(dst.w)));
    const sy: i32 = @intFromFloat(65536.0 * (@as(f32, @floatFromInt(src.h)) - shrink) / @as(f32, @floatFromInt(dst.h)));

    const sax = try zoomSteps(allocator, dst.w, sx);
    defer allocator.free(sax);
    const say = try zoomSteps(allocator, dst.h, sy);
    defer allocator.free(say);

    const dir_x: i32 = if (flipx) -1 else 1;
    const dir_y: i32 = if (flipy) -1 else 1;
    var row: i32 = if (flipy) src.h - 1 else 0;
    var ly: i32 = 0;

    for (0..@intCast(dst.h)) |y| {
        var col: i32 = if (flipx) src.w - 1 else 0;
        var lx: i32 = 0;
        for (0..@intCast(dst.w)) |x| {
            const out = dst.at(@intCast(x), @intCast(y));
            var step = sax[x + 1] >> 16;
            if (smooth) {
                const n = neighbours(src, col, row, flipx, flipy);
                out.* = lerpPixel(n[0], n[1], n[2], n[3], sax[x] & 0xffff, say[y] & 0xffff);
                lx += step;
                if (lx >= src.w) step = 0;
            } else {
                out.* = src.at(col, row).*;
            }
            col += step * dir_x;
        }
        var step = say[y + 1] >> 16;
        if (smooth) {
            ly += step;
            if (ly >= src.h) step = 0;
        }
        row += step * dir_y;
    }
}

fn zoomY(src_s: *Surface, dst_s: *Surface, flipx: bool, flipy: bool) !void {
    const src = View(u8).init(src_s);
    const dst = View(u8).init(dst_s);
    const allocator = std.heap.c_allocator;

    // Whole source pixels to move on after each destination pixel.
    const sax = try allocator.alloc(i32, @intCast(dst.w));
    defer allocator.free(sax);
    const say = try allocator.alloc(i32, @intCast(dst.h));
    defer allocator.free(say);
    for ([_][]i32{ sax, say }, [_]i32{ src.w, src.h }, [_]i32{ dst.w, dst.h }) |steps, src_len, dst_len| {
        var acc: i32 = 0;
        for (steps) |*s| {
            acc += src_len;
            s.* = @divTrunc(acc, dst_len);
            acc = @rem(acc, dst_len);
        }
    }

    const dir_x: i32 = if (flipx) -1 else 1;
    const dir_y: i32 = if (flipy) -1 else 1;
    var row: i32 = if (flipy) src.h - 1 else 0;
    for (0..@intCast(dst.h)) |y| {
        var col: i32 = if (flipx) src.w - 1 else 0;
        for (0..@intCast(dst.w)) |x| {
            dst.at(@intCast(x), @intCast(y)).* = src.at(col, row).*;
            col += sax[x] * dir_x;
        }
        row += say[y] * dir_y;
    }
}

// ---------------------------------------------------------------------------
// Rotation + zoom
// ---------------------------------------------------------------------------

/// Fixed-point walk over the source for each destination row: returns the
/// source position (16.16) of the row's first pixel.
const Transform = struct {
    cx: i32,
    cy: i32,
    isin: i32,
    icos: i32,
    xd: i32,
    yd: i32,
    ax: i32,
    ay: i32,

    fn init(src_w: i32, src_h: i32, dst_w: i32, dst_h: i32, cx: i32, cy: i32, isin: i32, icos: i32) Transform {
        return .{
            .cx = cx,
            .cy = cy,
            .isin = isin,
            .icos = icos,
            .xd = (src_w - dst_w) *% (1 << 15),
            .yd = (src_h - dst_h) *% (1 << 15),
            .ax = (cx *% (1 << 16)) -% (icos *% cx),
            .ay = (cy *% (1 << 16)) -% (isin *% cx),
        };
    }

    fn rowStart(t: Transform, y: i32) [2]i32 {
        const dy = t.cy - y;
        return .{ (t.ax +% t.isin *% dy) +% t.xd, (t.ay -% t.icos *% dy) +% t.yd };
    }
};

/// Integer source pixel of a 16.16 coordinate, truncated to 16 bits like
/// the original's `(short)` cast in the non-smoothing paths.
fn shortPixel(v: i32) i32 {
    return @as(i16, @truncate(v >> 16));
}

fn transformRgba(src_s: *Surface, dst_s: *Surface, t: Transform, flipx: bool, flipy: bool, smooth: bool) void {
    const src = View(Rgba).init(src_s);
    const dst = View(Rgba).init(dst_s);

    for (0..@intCast(dst.h)) |y| {
        var sd = t.rowStart(@intCast(y));
        for (0..@intCast(dst.w)) |x| {
            const out = dst.at(@intCast(x), @intCast(y));
            if (smooth) {
                var dx = sd[0] >> 16;
                var dy = sd[1] >> 16;
                if (dx > -1 and dy > -1 and dx < src.w and dy < src.h) {
                    if (flipx) dx = src.w - 1 - dx;
                    if (flipy) dy = src.h - 1 - dy;
                    const n = neighbours(src, dx, dy, flipx, flipy);
                    out.* = lerpPixel(n[0], n[1], n[2], n[3], sd[0] & 0xffff, sd[1] & 0xffff);
                }
            } else {
                var dx = shortPixel(sd[0]);
                var dy = shortPixel(sd[1]);
                if (flipx) dx = src.w - 1 - dx;
                if (flipy) dy = src.h - 1 - dy;
                if (dx >= 0 and dy >= 0 and dx < src.w and dy < src.h) out.* = src.at(dx, dy).*;
            }
            sd[0] +%= t.icos;
            sd[1] +%= t.isin;
        }
    }
}

fn transformY(src_s: *Surface, dst_s: *Surface, t: Transform, flipx: bool, flipy: bool) void {
    const src = View(u8).init(src_s);
    const dst = View(u8).init(dst_s);

    // Pixels that map outside the source keep the colorkey.
    const key: u8 = @truncate(src_s.format.*.colorkey);
    @memset(dst.pixels[0 .. dst.pitch * @as(usize, @intCast(dst.h))], key);

    for (0..@intCast(dst.h)) |y| {
        var sd = t.rowStart(@intCast(y));
        for (0..@intCast(dst.w)) |x| {
            var dx = shortPixel(sd[0]);
            var dy = shortPixel(sd[1]);
            if (flipx) dx = src.w - 1 - dx;
            if (flipy) dy = src.h - 1 - dy;
            if (dx >= 0 and dy >= 0 and dx < src.w and dy < src.h) {
                dst.at(@intCast(x), @intCast(y)).* = src.at(dx, dy).*;
            }
            sd[0] +%= t.icos;
            sd[1] +%= t.isin;
        }
    }
}

// ---------------------------------------------------------------------------
// Target sizes
// ---------------------------------------------------------------------------

/// Size of the rotated box, plus sin/cos of the angle scaled by zoomx.
fn sizeTrig(width: c_int, height: c_int, angle: f64, zoomx: f64, dstwidth: *c_int, dstheight: *c_int, canglezoom: *f64, sanglezoom: *f64) void {
    const rad = angle * (std.math.pi / 180.0);
    sanglezoom.* = @sin(rad) * zoomx;
    canglezoom.* = @cos(rad) * zoomx;
    const x: f64 = @floatFromInt(width >> 1);
    const y: f64 = @floatFromInt(height >> 1);
    const cx = canglezoom.* * x;
    const cy = canglezoom.* * y;
    const sx = sanglezoom.* * x;
    const sy = sanglezoom.* * y;

    // |±a ± b| is at most |a| + |b|, the maximum the original computed.
    const half_w: c_int = @max(@as(c_int, @intFromFloat(@ceil(@max(@abs(cx + sy), @abs(cx - sy))))), 1);
    const half_h: c_int = @max(@as(c_int, @intFromFloat(@ceil(@max(@abs(sx + cy), @abs(sx - cy))))), 1);
    dstwidth.* = 2 * half_w;
    dstheight.* = 2 * half_h;
}

pub export fn rotozoomSurfaceSizeXY(width: c_int, height: c_int, angle: f64, zoomx: f64, zoomy: f64, dstwidth: *c_int, dstheight: *c_int) void {
    _ = zoomy; // the rotated size only depends on zoomx (as in the original)
    var s: f64 = undefined;
    var co: f64 = undefined;
    sizeTrig(width, height, angle, zoomx, dstwidth, dstheight, &co, &s);
}

pub export fn rotozoomSurfaceSize(width: c_int, height: c_int, angle: f64, zoom: f64, dstwidth: *c_int, dstheight: *c_int) void {
    rotozoomSurfaceSizeXY(width, height, angle, zoom, zoom, dstwidth, dstheight);
}

pub export fn zoomSurfaceSize(width: c_int, height: c_int, zoomx: f64, zoomy: f64, dstwidth: *c_int, dstheight: *c_int) void {
    const zx = @max(zoomx, value_limit);
    const zy = @max(zoomy, value_limit);
    dstwidth.* = @max(@as(c_int, @intFromFloat(@as(f64, @floatFromInt(width)) * zx)), 1);
    dstheight.* = @max(@as(c_int, @intFromFloat(@as(f64, @floatFromInt(height)) * zy)), 1);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Rotate by `angle` degrees and scale by `zoom` into a new surface.
/// 32-bit and 8-bit surfaces are used as they are, anything else is
/// converted to 32-bit RGBA first. `smooth` enables anti-aliasing (32-bit).
pub export fn rotozoomSurface(src: ?*Surface, angle: f64, zoom: f64, smooth: c_int) ?*Surface {
    return rotozoomSurfaceXY(src, angle, zoom, zoom, smooth);
}

pub export fn rotozoomSurfaceXY(src_opt: ?*Surface, angle: f64, zoomx_in: f64, zoomy_in: f64, smooth: c_int) ?*Surface {
    const src = src_opt orelse return null;
    const src_fmt = nonNull(src.format) orelse return null;

    // Remember the colorkey as RGB, to map it into the new surface's format.
    var key_rgb: ?[3]u8 = null;
    if (src.flags & c.SDL_SRCCOLORKEY != 0) {
        var rgb: [3]u8 = undefined;
        c.SDL_GetRGB(src_fmt.colorkey, src_fmt, &rgb[0], &rgb[1], &rgb[2]);
        key_rgb = rgb;
    }

    // Work on 32-bit or 8-bit data; convert anything else to 32-bit RGBA.
    var is32bit = src_fmt.BitsPerPixel == 32;
    var rz_src = src;
    var src_converted = false;
    if (!is32bit and src_fmt.BitsPerPixel != 8) {
        const masks: [4]u32 = if (@import("builtin").cpu.arch.endian() == .little)
            .{ 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000 }
        else
            .{ 0xff000000, 0x00ff0000, 0x0000ff00, 0x000000ff };
        rz_src = nonNull(c.SDL_CreateRGBSurface(c.SDL_SWSURFACE, src.w, src.h, 32, masks[0], masks[1], masks[2], masks[3])) orelse return null;
        // Blit without the colorkey so keyed pixels keep their color.
        const key = src_fmt.colorkey;
        if (key_rgb != null) _ = c.SDL_SetColorKey(src, 0, 0);
        _ = c.SDL_UpperBlit(src, null, rz_src, null);
        if (key_rgb != null) _ = c.SDL_SetColorKey(src, c.SDL_SRCCOLORKEY, key);
        src_converted = true;
        is32bit = true;
    }
    defer if (src_converted) c.SDL_FreeSurface(rz_src);

    // Negative zoom flips; tiny zoom is clamped.
    const flipx = zoomx_in < 0;
    const flipy = zoomy_in < 0;
    const zoomx = @max(@abs(zoomx_in), value_limit);
    const zoomy = @max(@abs(zoomy_in), value_limit);
    const rotate = @abs(angle) > value_limit;

    var dstwidth: c_int = undefined;
    var dstheight: c_int = undefined;
    var canglezoom: f64 = 0;
    var sanglezoom: f64 = 0;
    if (rotate) {
        sizeTrig(rz_src.w, rz_src.h, angle, zoomx, &dstwidth, &dstheight, &canglezoom, &sanglezoom);
    } else {
        zoomSurfaceSize(rz_src.w, rz_src.h, zoomx, zoomy, &dstwidth, &dstheight);
    }

    // Target surface: 32-bit with the source's channel order, or 8-bit.
    const fmt = nonNull(rz_src.format) orelse return null;
    const rz_dst: *Surface = if (is32bit)
        nonNull(c.SDL_CreateRGBSurface(c.SDL_SWSURFACE, dstwidth, dstheight, 32, fmt.Rmask, fmt.Gmask, fmt.Bmask, fmt.Amask)) orelse return null
    else
        nonNull(c.SDL_CreateRGBSurface(c.SDL_SWSURFACE, dstwidth, dstheight, 8, 0, 0, 0, 0)) orelse return null;

    if (key_rgb) |rgb| {
        _ = c.SDL_FillRect(rz_dst, null, c.SDL_MapRGB(rz_dst.format, rgb[0], rgb[1], rgb[2]));
    }

    _ = c.SDL_LockSurface(rz_src);
    defer c.SDL_UnlockSurface(rz_src);

    if (is32bit) {
        if (rotate) {
            const zoominv = 65536.0 / (zoomx * zoomx);
            const t = Transform.init(rz_src.w, rz_src.h, dstwidth, dstheight, dstwidth >> 1, dstheight >> 1, @intFromFloat(sanglezoom * zoominv), @intFromFloat(canglezoom * zoominv));
            transformRgba(rz_src, rz_dst, t, flipx, flipy, smooth != 0);
        } else {
            zoomRgba(rz_src, rz_dst, flipx, flipy, smooth != 0) catch {
                c.SDL_FreeSurface(rz_dst);
                return null;
            };
        }
        _ = c.SDL_SetAlpha(rz_dst, c.SDL_SRCALPHA, 255);
    } else {
        // Same palette (and colorkey) as the source.
        const src_pal = nonNull(fmt.palette).?;
        const dst_pal = nonNull(nonNull(rz_dst.format).?.palette).?;
        const n: usize = @intCast(src_pal.ncolors);
        @memcpy(dst_pal.colors[0..n], src_pal.colors[0..n]);
        dst_pal.ncolors = src_pal.ncolors;

        if (rotate) {
            const zoominv = 65536.0 / (zoomx * zoomx);
            const t = Transform.init(rz_src.w, rz_src.h, dstwidth, dstheight, dstwidth >> 1, dstheight >> 1, @intFromFloat(sanglezoom * zoominv), @intFromFloat(canglezoom * zoominv));
            transformY(rz_src, rz_dst, t, flipx, flipy);
        } else {
            zoomY(rz_src, rz_dst, flipx, flipy) catch {
                c.SDL_FreeSurface(rz_dst);
                return null;
            };
        }
        _ = c.SDL_SetColorKey(rz_dst, c.SDL_SRCCOLORKEY | c.SDL_RLEACCEL, fmt.colorkey);
    }

    return rz_dst;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testSurface(w: c_int, h: c_int) *Surface {
    const s = nonNull(c.SDL_CreateRGBSurface(c.SDL_SWSURFACE, w, h, 32, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000)).?;
    const v = View(Rgba).init(s);
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) v.at(x, y).* = .{ .r = @intCast(x), .g = @intCast(y), .b = 7, .a = 255 };
    }
    return s;
}

test "zoom 1.0 without rotation copies the image" {
    const src = testSurface(13, 7);
    defer c.SDL_FreeSurface(src);
    const dst = rotozoomSurface(src, 0, 1.0, 0).?;
    defer c.SDL_FreeSurface(dst);
    try std.testing.expectEqual(@as(c_int, 13), dst.w);
    try std.testing.expectEqual(@as(c_int, 7), dst.h);
    const a = View(Rgba).init(src);
    const b = View(Rgba).init(dst);
    var y: i32 = 0;
    while (y < 7) : (y += 1) {
        var x: i32 = 0;
        while (x < 13) : (x += 1) try std.testing.expectEqual(a.at(x, y).*, b.at(x, y).*);
    }
}

test "zoom 2.0 doubles pixels" {
    const src = testSurface(4, 3);
    defer c.SDL_FreeSurface(src);
    const dst = rotozoomSurface(src, 0, 2.0, 0).?;
    defer c.SDL_FreeSurface(dst);
    try std.testing.expectEqual(@as(c_int, 8), dst.w);
    const b = View(Rgba).init(dst);
    try std.testing.expectEqual(@as(u8, 1), b.at(3, 0).r);
    try std.testing.expectEqual(@as(u8, 2), b.at(4, 5).r);
    try std.testing.expectEqual(@as(u8, 2), b.at(4, 5).g);
}

test "rotation by 90 degrees" {
    var w: c_int = 0;
    var h: c_int = 0;
    rotozoomSurfaceSize(40, 20, 90, 1, &w, &h);
    // cos(90°) is 6e-17 in floating point, so ceil() rounds the half width
    // from 10 up to 11 (the original computes the same).
    try std.testing.expectEqual(@as(c_int, 22), w);
    try std.testing.expectEqual(@as(c_int, 40), h);

    const src = testSurface(40, 20);
    defer c.SDL_FreeSurface(src);
    const dst = rotozoomSurface(src, 90, 1.0, 1).?;
    defer c.SDL_FreeSurface(dst);
    try std.testing.expectEqual(@as(c_int, 22), dst.w);
    try std.testing.expectEqual(@as(c_int, 40), dst.h);
}
