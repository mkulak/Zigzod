//! How effects move and animate: straight flights, arcs, frame timing.

const std = @import("std");
const game = @import("../../game.zig");
const gfx = @import("../gfx.zig");
const sprites = @import("../sprites.zig");
const k = game.constants;
const Object = game.object.Object;
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Fx = sprites.EffectSprites;

pub const Point = struct {
    x: f64,
    y: f64,

    pub fn of(x: i32, y: i32) Point {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }
};

pub fn int(v: f64) i32 {
    return @intFromFloat(std.math.clamp(@trunc(v), -1e9, 1e9));
}

/// Angle (degrees, counterclockwise from east) of a screen direction.
pub fn angleOf(dx: f64, dy: f64) f64 {
    if (game.object.isZero(dx) and game.object.isZero(dy)) return 0;
    var a = std.math.atan2(dy, dx);
    if (a < 0) a += 2 * std.math.pi;
    return @mod(@floor(180.0 * a / std.math.pi + 0.5), 360);
}

/// Straight flight from `from` to `to` at `speed` pixels per second.
pub const Line = struct {
    start: Point,
    end: Point,
    /// Pixels per second.
    vx: f64,
    vy: f64,
    t0: f64,
    t1: f64,

    pub fn init(from: Point, to: Point, speed: f64, time: f64) Line {
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const duration = @max(@sqrt(dx * dx + dy * dy) / @max(speed, 1), 0.001);
        return .{ .start = from, .end = to, .vx = dx / duration, .vy = dy / duration, .t0 = time, .t1 = time + duration };
    }

    pub fn at(l: Line, time: f64) Point {
        const d = time - l.t0;
        return .{ .x = l.start.x + l.vx * d, .y = l.start.y + l.vy * d };
    }

    /// How much to turn an image drawn pointing east to fly this way
    /// (the C++ code's `359 - AngleFromLoc`).
    pub fn imageAngle(l: Line) f64 {
        return 359 - angleOf(l.vx, l.vy);
    }
};

/// Debris flying in an arc: along a line over `lifetime`, lifted by a
/// parabola peaking halfway (`lift` is 0 at both ends).
pub const Arc = struct {
    line: Line,
    rise: f64,

    pub fn init(from: Point, to: Point, lifetime: f64, rise: f64, time: f64) Arc {
        const l = @max(lifetime, 0.001);
        return .{ .line = .{ .start = from, .end = to, .vx = (to.x - from.x) / l, .vy = (to.y - from.y) / l, .t0 = time, .t1 = time + l }, .rise = rise };
    }

    pub fn lift(a: Arc, time: f64) f64 {
        const d = time - a.line.t0;
        return -(a.rise / (a.line.t1 - a.line.t0)) * d * d + a.rise * d;
    }

    pub fn done(a: Arc, time: f64) bool {
        return time >= a.line.t1;
    }
};

/// Frames advancing at a fixed interval.
pub const Frames = struct {
    i: u8 = 0,
    next: f64,
    interval: f64,

    pub fn init(time: f64, interval: f64) Frames {
        return .{ .next = time + interval, .interval = interval };
    }

    /// Advance if it's time; true if the frame changed.
    pub fn tick(f: *Frames, time: f64) bool {
        if (time < f.next) return false;
        f.next = time + f.interval;
        f.i += 1;
        return true;
    }
};
