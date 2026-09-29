//! Rotated and scaled copies of images for the effects, cached.

const std = @import("std");
const game = @import("../../game.zig");
const gfx = @import("../gfx.zig");
const sprites = @import("../sprites.zig");
const k = game.constants;
const Object = game.object.Object;
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Fx = sprites.EffectSprites;

/// Rotated and scaled copies of images, made when first needed (angles in
/// whole degrees counterclockwise, sizes in steps of 1/20). Copies that
/// were not drawn for a while are dropped.
pub const Transforms = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    frame: u32 = 0,

    const Key = struct { src: [*]u32, angle: u16, size: u16 };
    const Entry = struct { img: Image, used: u32 };
    const size_steps = 20;
    /// Frames between sweeps, and how long an unused copy is kept.
    const sweep_interval = 128;
    const keep_frames = 256;

    pub fn deinit(t: *Transforms) void {
        var it = t.map.valueIterator();
        while (it.next()) |e| e.img.deinit(t.gpa);
        t.map.deinit(t.gpa);
    }

    /// `img` turned by `angle` degrees and scaled by `size`; null if that
    /// is too small to see (or there is no memory for it: effects are
    /// only decoration).
    pub fn get(t: *Transforms, img: Image, angle: f64, size: f64) ?Image {
        const a: u16 = @intCast(@mod(@as(i32, @intFromFloat(@round(angle))), 360));
        const s_f = @round(size * size_steps);
        if (!(s_f >= 1)) return null;
        const s: u16 = @intFromFloat(@min(s_f, 10 * size_steps));
        if (a == 0 and s == size_steps) return img;
        const key: Key = .{ .src = img.pixels, .angle = a, .size = s };
        if (t.map.getPtr(key)) |e| {
            e.used = t.frame;
            return e.img;
        }
        const made = img.rotozoom(t.gpa, @floatFromInt(a), @as(f64, @floatFromInt(s)) / size_steps) catch return null;
        t.map.put(t.gpa, key, .{ .img = made, .used = t.frame }) catch {
            made.deinit(t.gpa);
            return null;
        };
        return made;
    }

    /// Call once per drawn frame.
    pub fn endFrame(t: *Transforms) void {
        t.frame +%= 1;
        if (t.frame % sweep_interval != 0) return;
        var old: std.ArrayList(Key) = .empty;
        defer old.deinit(t.gpa);
        var it = t.map.iterator();
        while (it.next()) |e| {
            if (t.frame -% e.value_ptr.used < keep_frames) continue;
            old.append(t.gpa, e.key_ptr.*) catch break;
        }
        for (old.items) |key| {
            const e = t.map.fetchRemove(key).?;
            e.value.img.deinit(t.gpa);
        }
    }
};
