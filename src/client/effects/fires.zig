//! Fire and smoke burning on wrecks and damaged buildings.

const std = @import("std");
const game = @import("../../game.zig");
const gfx = @import("../gfx.zig");
const sprites = @import("../sprites.zig");
const k = game.constants;
const Object = game.object.Object;
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Fx = sprites.EffectSprites;
const motion = @import("motion.zig");
const Frames = motion.Frames;

/// Kinds of fire and smoke on wrecks and damaged buildings (EStandard).
pub const FireKind = enum { big_smoke, little_fire, small_fire_smoke, fire };

/// A looping fire or smoke (EStandard). Wrecks and buildings own theirs.
pub const Fire = struct {
    kind: FireKind,
    /// Where it burns (its bottom center, roughly).
    base_x: i32,
    base_y: i32,
    frames: Frames,

    pub fn init(kind: FireKind, x: i32, y: i32, rng: std.Random, time: f64) Fire {
        var f: Fire = .{ .kind = kind, .base_x = x, .base_y = y, .frames = .init(time, 0.1) };
        f.frames.i = rng.uintLessThan(u8, 4);
        f.frames.interval = 0.15;
        return f;
    }

    /// Fires on buildings are chosen at random: mostly flames.
    pub fn random(x: i32, y: i32, rng: std.Random, time: f64) Fire {
        const choice = rng.uintLessThan(u32, 100);
        const kind: FireKind = if (choice < 10) .big_smoke else if (choice < 20) .small_fire_smoke else if (choice < 50) .fire else .little_fire;
        return .init(kind, x, y, rng, time);
    }

    pub fn update(f: *Fire, time: f64) void {
        if (f.frames.tick(time) and f.frames.i >= 4) f.frames.i = 0;
    }

    pub fn draw(f: *const Fire, cv: Canvas, s: *const Fx) void {
        const imgs, const ox: i32, const oy: i32 = switch (f.kind) {
            .big_smoke => .{ &s.big_smoke, 16, 32 },
            .little_fire => .{ &s.little_fire, 4, 8 },
            .small_fire_smoke => .{ &s.small_fire_smoke, 8, 16 },
            .fire => .{ &s.fire, 4, 8 },
        };
        cv.draw(imgs[f.frames.i], f.base_x - ox, f.base_y - oy);
    }

    /// Fires further down the screen are drawn later.
    pub fn lessThan(_: void, a: Fire, b: Fire) bool {
        return a.base_y < b.base_y;
    }
};

/// Damage fires and smoke on a building (ZBuilding::ProcessBuildingsEffects):
/// more of them the more it is damaged.
pub const BuildingFires = struct {
    fires: std.ArrayList(Fire) = .empty,
    max: u32,

    pub fn init(o: *const Object, rng: std.Random) BuildingFires {
        const b = o.kind.building;
        const max: u32 = switch (b.type) {
            .fort_front, .fort_back => 20 + rng.uintLessThan(u32, 8),
            .radar => 6 + rng.uintLessThan(u32, 3),
            .repair => 6 + rng.uintLessThan(u32, 4),
            .robot_factory, .vehicle_factory => 8 + rng.uintLessThan(u32, 4),
            .bridge_vert, .bridge_horz => 0,
        };
        return .{ .max = max };
    }

    pub fn deinit(f: *BuildingFires, gpa: std.mem.Allocator) void {
        f.fires.deinit(gpa);
    }

    /// Put out all fires (the building was rebuilt).
    pub fn clear(f: *BuildingFires) void {
        f.fires.clearRetainingCapacity();
    }

    pub fn update(f: *BuildingFires, gpa: std.mem.Allocator, o: *const Object, rng: std.Random, time: f64) void {
        for (f.fires.items) |*fire| fire.update(time);
        const ratio = std.math.clamp(@as(f64, @floatFromInt(o.health)) / @as(f64, @floatFromInt(@max(o.max_health, 1))), 0, 1);
        const wanted: usize = @intFromFloat(@as(f64, @floatFromInt(f.max)) * (1 - ratio));
        if (f.fires.items.len >= wanted) return;
        const box = effectsBox(o);
        while (f.fires.items.len < wanted) {
            const x = o.x + box.x + rng.intRangeLessThan(i32, 0, box.w);
            const y = o.y + box.y + rng.intRangeLessThan(i32, 0, box.h);
            f.fires.append(gpa, .random(x, y, rng, time)) catch return;
        }
        std.mem.sort(Fire, f.fires.items, {}, Fire.lessThan);
    }

    pub fn draw(f: *const BuildingFires, cv: Canvas, s: *const sprites.Sprites) void {
        for (f.fires.items) |*fire| fire.draw(cv, &s.fx);
    }
};

/// The part of a building where fires burn and explosions happen.
pub fn effectsBox(o: *const Object) gfx.Rect {
    return switch (o.kind.building.type) {
        .fort_front, .fort_back => .{ .x = 18, .y = 18, .w = 136, .h = 118 },
        .radar => .{ .x = 1, .y = 6, .w = 44, .h = 30 },
        .repair, .robot_factory, .vehicle_factory => .{ .x = 8, .y = 8, .w = @max(o.width_pix - 24, 1), .h = @max(o.height_pix - 24, 1) },
        .bridge_vert, .bridge_horz => .{ .x = 16, .y = 16, .w = 32, .h = 32 },
    };
}
