//! Wildlife, for decoration only (ABird and AHutAnimal): birds (bats in
//! the city) circling over the map, and small animals that come out of
//! huts, wander around them and go back in.

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const sprites = @import("sprites.zig");
const units = @import("units.zig");
const Effects = @import("effects.zig").Effects;

const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const HutAnimal = sprites.HutAnimal;

fn frac(rng: std.Random, n: u32, step: f64) f64 {
    return @as(f64, @floatFromInt(rng.uintLessThan(u32, n))) * step;
}

// ---------------------------------------------------------------------------
// Birds
// ---------------------------------------------------------------------------

/// How far outside the map birds may fly before they come back.
const bird_padding = 160;
/// One bird per this many tiles.
const tiles_per_bird = 650;

const Bird = struct {
    x: f64 = 0,
    y: f64 = 0,
    /// Heading, degrees counterclockwise from east, and how fast it turns
    /// (degrees per second).
    angle: f64 = 0,
    turning: f64 = 0,
    speed: f64 = 0,
    /// Height, as the picture's size: 1 is low.
    rise: f64 = 1,
    rise_from: f64 = 1,
    rise_to: f64 = 1,
    rise_start: f64 = 0,
    rise_end: f64 = 0,
    frame: u8 = 0,
    next_frame: f64 = 0,
    next_turn: f64 = 0,
    next_call: f64 = 0,
    next_climb: f64 = 0,
    last_time: f64 = 0,
};

pub const Birds = struct {
    birds: [max]Bird = undefined,
    n: usize = 0,
    planet: k.Planet = .desert,
    map_w: i32 = 0,
    map_h: i32 = 0,

    const max = 128;

    /// Birds for a map of w x h tiles.
    pub fn init(planet: k.Planet, w: i32, h: i32, rng: std.Random, time: f64) Birds {
        var b: Birds = .{ .planet = planet, .map_w = w * k.tile_size, .map_h = h * k.tile_size };
        b.n = @min(@as(usize, @intCast(@max(w * h, 0))) / tiles_per_bird, max);
        for (b.birds[0..b.n]) |*bird| b.reset(bird, rng, time);
        return b;
    }

    /// Wing beats are fast for bats.
    fn frameTime(b: *const Birds) f64 {
        return if (b.planet == .city) 0.03 else 0.3;
    }

    /// Start somewhere just off the map, heading for its middle.
    fn reset(b: *const Birds, bird: *Bird, rng: std.Random, time: f64) void {
        const pad = bird_padding;
        const across_w = rng.intRangeLessThan(i32, 0, b.map_w + 2 * pad) - pad;
        const across_h = rng.intRangeLessThan(i32, 0, b.map_h + 2 * pad) - pad;
        const out = rng.intRangeLessThan(i32, 0, pad) + 16;
        const x: i32, const y: i32 = switch (rng.int(u2)) {
            0 => .{ across_w, -out },
            1 => .{ across_w, b.map_h + out },
            2 => .{ -out, across_h },
            3 => .{ b.map_w + out, across_h },
        };
        bird.* = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .angle = std.math.radiansToDegrees(std.math.atan2(-@as(f64, @floatFromInt((b.map_h >> 1) - y)), @as(f64, @floatFromInt((b.map_w >> 1) - x)))),
            .speed = if (b.planet == .city) 80 + frac(rng, 20, 1) else 20 + frac(rng, 10, 1),
            .next_turn = time + 9 + frac(rng, 50, 0.1),
            .next_call = time + 3 + frac(rng, 50, 0.1),
            .next_climb = time + 5 + frac(rng, 100, 0.1),
            .next_frame = time + b.frameTime(),
            .last_time = time,
        };
        bird.angle = @mod(bird.angle, 360);
    }

    pub fn update(b: *Birds, fx: *Effects, rng: std.Random, time: f64) void {
        for (b.birds[0..b.n]) |*bird| {
            if (time >= bird.next_frame) {
                bird.next_frame = time + b.frameTime();
                bird.frame = (bird.frame + 1) % 5;
            }
            // Now and then circle for a while.
            if (time >= bird.next_turn) {
                if (bird.turning == 0) {
                    bird.next_turn = time + 5 + frac(rng, 30, 0.1);
                    bird.turning = frac(rng, 100, 1) - 50;
                } else {
                    bird.next_turn = time + 9 + frac(rng, 50, 0.1);
                    bird.turning = 0;
                }
            }
            if (time >= bird.next_call) {
                bird.next_call = time + 15 + frac(rng, 50, 0.1);
                if (rng.uintLessThan(u32, 3) == 0) fx.soundAt(if (b.planet == .city) .bat_chirp else .crow, @intFromFloat(bird.x), @intFromFloat(bird.y));
            }
            // Climb or sink slowly.
            if (time >= bird.next_climb) {
                bird.next_climb = time + 15 + frac(rng, 100, 0.1);
                bird.rise_start = time;
                bird.rise_end = time + 4 + frac(rng, 60, 0.1);
                bird.rise_from = bird.rise;
                bird.rise_to = 1 + frac(rng, 10, 0.1);
            }
            if (bird.rise != bird.rise_to) {
                bird.rise = if (time > bird.rise_end)
                    bird.rise_to
                else
                    bird.rise_from + (bird.rise_to - bird.rise_from) * (time - bird.rise_start) / (bird.rise_end - bird.rise_start);
            }

            const dt = @max(time - bird.last_time, 0);
            bird.last_time = time;
            bird.angle = @mod(bird.angle + bird.turning * dt, 360);
            const rad = std.math.degreesToRadians(bird.angle);
            bird.x += bird.speed * @cos(rad) * dt;
            bird.y -= bird.speed * @sin(rad) * dt;

            const pad: f64 = bird_padding;
            if (bird.x < -pad or bird.y < -pad or bird.x > pad + @as(f64, @floatFromInt(b.map_w)) or bird.y > pad + @as(f64, @floatFromInt(b.map_h))) {
                b.reset(bird, rng, time);
            }
        }
    }

    /// Over everything, turned to where they fly and larger the higher
    /// they are (their shadow-less picture moves up as they climb).
    pub fn draw(b: *const Birds, cv: gfx.Canvas, view: gfx.Rect, all: *const sprites.Sprites, fx: *Effects) void {
        const imgs = &all.birds[@intFromEnum(b.planet)];
        for (b.birds[0..b.n]) |bird| {
            const x: i32 = @intFromFloat(bird.x);
            const y: i32 = @intFromFloat(bird.y - (bird.rise - 1) * 50);
            if (x < view.x - 64 or y < view.y - 64 or x > view.x + view.w + 64 or y > view.y + view.h + 64) continue;
            const img = fx.transforms.get(imgs[bird.frame], bird.angle, bird.rise) orelse continue;
            cv.drawCentered(img, x, y);
        }
    }
};

// ---------------------------------------------------------------------------
// Hut animals
// ---------------------------------------------------------------------------

/// Which animals live where.
fn animalsOf(planet: k.Planet) []const HutAnimal {
    return switch (planet) {
        .desert => &.{ .green_snake, .green_lizard, .desert_rabit },
        .volcanic => &.{ .raptor, .mini_raptor, .pig_dino, .yellow_worm },
        .arctic => &.{ .arctic_rabit, .penguin, .white_wolf },
        .jungle => &.{ .ostrich, .rat, .turtle },
        .city => &.{ .red_worm, .rat, .green_eyed_fox },
    };
}

const Animal = struct {
    kind: HutAnimal,
    x: f64,
    y: f64,
    /// Where it walks to (a tile's center) and how fast (pixels/second).
    to_x: i32 = 0,
    to_y: i32 = 0,
    dx: f64 = 0,
    dy: f64 = 0,
    direction: u3 = 0,
    state: enum { resting, walking, looking } = .resting,
    going_home: bool = false,
    /// Back in the hut, or stuck: to be removed.
    gone: bool = false,
    walk_i: u8 = 0,
    look_i: u8 = 0,
    next_walk: f64 = 0,
    next_look: f64 = 0,
    next_move: f64 = 0,

    const speed = 15.0;
    const walk_time = 0.2;
    const look_time = 0.35;

    fn tileX(a: *const Animal) i32 {
        return @divFloor(@as(i32, @intFromFloat(a.x)), k.tile_size);
    }

    fn tileY(a: *const Animal) i32 {
        return @divFloor(@as(i32, @intFromFloat(a.y)), k.tile_size);
    }

    fn goTo(a: *Animal, px: i32, py: i32, rng: std.Random, time: f64) void {
        a.to_x = px;
        a.to_y = py;
        const dx = @as(f64, @floatFromInt(px)) - a.x;
        const dy = @as(f64, @floatFromInt(py)) - a.y;
        const mag = @sqrt(dx * dx + dy * dy);
        if (mag < 0.0001) return a.rest(rng, time);
        a.dx = dx / mag * speed;
        a.dy = dy / mag * speed;
        if (units.directionFrom(a.dx, a.dy)) |d| a.direction = d;
        a.state = .walking;
    }

    fn goToTile(a: *Animal, tx: i32, ty: i32, rng: std.Random, time: f64) void {
        a.goTo(tx * k.tile_size + 8, ty * k.tile_size + 8, rng, time);
    }

    fn rest(a: *Animal, rng: std.Random, time: f64) void {
        a.state = .resting;
        a.dx = 0;
        a.dy = 0;
        a.next_move = time + 0.1 + frac(rng, 10, 0.1);
        // Hopping animals sit down.
        switch (a.kind) {
            .desert_rabit, .pig_dino, .arctic_rabit => a.walk_i = 0,
            else => {},
        }
    }

    /// Mostly keep going the way it faces (a turn of 135 degrees or more
    /// is not preferred).
    fn preferred(from: u3, to: u3) bool {
        const diff = @abs(@as(i32, from) - to);
        return diff < 3 or diff > 5;
    }

    /// A step to a free neighbouring tile not too far from home.
    fn wander(a: *Animal, hut: *const Hut, grid: ?*const game.pathfinding.Grid, roam: i32, rng: std.Random, time: f64) void {
        const cx = a.tileX();
        const cy = a.tileY();
        var possible: [8][2]i32 = undefined;
        var preferred_tiles: [8][2]i32 = undefined;
        var n: usize = 0;
        var np: usize = 0;
        var ty = cy - 1;
        while (ty <= cy + 1) : (ty += 1) {
            var tx = cx - 1;
            while (tx <= cx + 1) : (tx += 1) {
                if (tx == cx and ty == cy) continue;
                // (Without a map everything counts as open ground.)
                if (grid) |g| if (!g.tilePassable(tx, ty, false)) continue;
                const ex = tx * k.tile_size + 8 - hut.home_x;
                const ey = ty * k.tile_size + 8 - hut.home_y;
                if (ex * ex + ey * ey > roam * roam) continue;
                possible[n] = .{ tx, ty };
                n += 1;
                if (units.directionFrom(@floatFromInt(tx - cx), @floatFromInt(ty - cy))) |d| if (preferred(a.direction, d)) {
                    preferred_tiles[np] = .{ tx, ty };
                    np += 1;
                };
            }
        }
        if (n == 0) {
            // Nowhere to go (a unit is standing around it, say).
            a.gone = true;
            return;
        }
        const t = if (np > 0 and rng.uintLessThan(u32, 5) != 0) preferred_tiles[rng.uintLessThan(usize, np)] else possible[rng.uintLessThan(usize, n)];
        a.goToTile(t[0], t[1], rng, time);
    }

    fn update(a: *Animal, hut: *const Hut, grid: ?*const game.pathfinding.Grid, roam: i32, dt: f64, rng: std.Random, time: f64) void {
        if (a.state == .walking) {
            const rx = @as(f64, @floatFromInt(a.to_x)) - a.x;
            const ry = @as(f64, @floatFromInt(a.to_y)) - a.y;
            const step = speed * dt;
            if (rx * rx + ry * ry <= step * step) {
                a.x = @floatFromInt(a.to_x);
                a.y = @floatFromInt(a.to_y);
                if (a.going_home) {
                    a.gone = true;
                    return;
                }
                if (rng.uintLessThan(u32, 3) != 0) a.wander(hut, grid, roam, rng, time) else a.rest(rng, time);
            } else {
                a.x += a.dx * dt;
                a.y += a.dy * dt;
            }
        }
        switch (a.state) {
            .resting => if (time >= a.next_move) {
                if (rng.uintLessThan(u32, 5) != 0 or a.kind.lookFrames() == 0) {
                    a.wander(hut, grid, roam, rng, time);
                } else {
                    a.look_i = 0;
                    a.state = .looking;
                }
            },
            .looking => if (time >= a.next_look) {
                a.next_look = time + look_time;
                a.look_i += 1;
                if (a.look_i >= a.kind.lookFrames()) {
                    a.look_i = 0;
                    // Maybe look around once more.
                    if (rng.uintLessThan(u32, 5) != 0) a.rest(rng, time);
                }
            },
            .walking => if (time >= a.next_walk) {
                a.next_walk = time + walk_time;
                a.walk_i = (a.walk_i + 1) % a.kind.walkFrames();
            },
        }
    }

    fn draw(a: *const Animal, cv: gfx.Canvas, art: *const sprites.HutAnimalArt) void {
        const img = switch (a.state) {
            .looking => art.look[a.direction][a.look_i],
            else => art.walk[a.direction][a.walk_i],
        };
        cv.drawCentered(img, @intFromFloat(a.x), @intFromFloat(a.y));
    }
};

/// The animals of one hut: between the settings' minimum and maximum of
/// them are out at a time, coming out and going back in now and then.
pub const Hut = struct {
    animals: [max]Animal = undefined,
    n: usize = 0,
    wanted: usize = 0,
    home_x: i32 = 0,
    home_y: i32 = 0,
    next_count_time: f64 = 0,
    next_wanted_time: f64 = 0,
    last_time: f64 = 0,

    const max = 16;

    pub fn update(h: *Hut, hut: *const Object, world: *const World, planet: k.Planet, rng: std.Random, time: f64) void {
        const s = &world.settings;
        h.home_x = hut.center_x;
        h.home_y = hut.center_y;
        const grid = if (world.grid) |*g| g else null;
        const dt = std.math.clamp(time - h.last_time, 0, 1);
        h.last_time = time;

        var i: usize = 0;
        while (i < h.n) {
            if (h.animals[i].gone) {
                h.n -= 1;
                h.animals[i] = h.animals[h.n];
            } else i += 1;
        }
        for (h.animals[0..h.n]) |*a| a.update(h, grid, s.hut_animal_roam_distance, dt, rng, time);

        if (time >= h.next_wanted_time) {
            h.next_wanted_time = time + 10;
            const lo: usize = @intCast(std.math.clamp(s.hut_animal_min, 0, max));
            const hi: usize = @intCast(std.math.clamp(s.hut_animal_max, 0, max));
            h.wanted = lo + if (hi > lo) rng.uintLessThan(usize, hi - lo) else 0;
        }
        if (time >= h.next_count_time) {
            h.next_count_time = time + 1;
            if (h.wanted > h.n) {
                for (0..rng.uintLessThan(usize, h.wanted - h.n + 1)) |_| h.comeOut(planet, grid, rng, time);
            } else if (h.wanted < h.n) {
                h.sendHome(rng.uintLessThan(usize, h.n - h.wanted + 1));
            }
        }
    }

    /// A new animal steps out of the hut (the tile below it if free).
    fn comeOut(h: *Hut, planet: k.Planet, grid: ?*const game.pathfinding.Grid, rng: std.Random, time: f64) void {
        if (h.n >= max) return;
        const hx = @divFloor(h.home_x, k.tile_size);
        const hy = @divFloor(h.home_y, k.tile_size);
        var exit: [2]i32 = .{ hx, hy + 1 };
        if (grid) |g| if (!g.tilePassable(exit[0], exit[1], false)) {
            var free: [8][2]i32 = undefined;
            var n: usize = 0;
            var ty = hy - 1;
            while (ty <= hy + 1) : (ty += 1) {
                var tx = hx - 1;
                while (tx <= hx + 1) : (tx += 1) {
                    if ((tx != hx or ty != hy) and g.tilePassable(tx, ty, false)) {
                        free[n] = .{ tx, ty };
                        n += 1;
                    }
                }
            }
            if (n == 0) return;
            exit = free[rng.uintLessThan(usize, n)];
        };
        const kinds = animalsOf(planet);
        const a = &h.animals[h.n];
        a.* = .{ .kind = kinds[rng.uintLessThan(usize, kinds.len)], .x = @floatFromInt(h.home_x), .y = @floatFromInt(h.home_y) };
        a.goToTile(exit[0], exit[1], rng, time);
        h.n += 1;
    }

    /// Send some animals back in (counting those already on their way).
    fn sendHome(h: *Hut, amount: usize) void {
        var left = amount;
        for (h.animals[0..h.n]) |a| {
            if (a.going_home) left -|= 1;
        }
        for (h.animals[0..h.n]) |*a| {
            if (left == 0) return;
            if (a.going_home) continue;
            a.going_home = true;
            a.to_x = h.home_x;
            a.to_y = h.home_y;
            const dx = @as(f64, @floatFromInt(h.home_x)) - a.x;
            const dy = @as(f64, @floatFromInt(h.home_y)) - a.y;
            const mag = @max(@sqrt(dx * dx + dy * dy), 0.0001);
            a.dx = dx / mag * Animal.speed;
            a.dy = dy / mag * Animal.speed;
            if (units.directionFrom(a.dx, a.dy)) |d| a.direction = d;
            a.state = .walking;
            left -= 1;
        }
    }

    pub fn draw(h: *const Hut, cv: gfx.Canvas, all: *const sprites.Sprites) void {
        for (h.animals[0..h.n]) |*a| a.draw(cv, &all.hut_animals[@intFromEnum(a.kind)]);
    }
};

test "birds fly around the map and come back" {
    var prng = std.Random.DefaultPrng.init(5);
    const rng = prng.random();
    const a = try @import("assets.zig").Assets.init(std.testing.allocator, "bin/assets");
    defer a.deinit();
    const all = try sprites.Sprites.load(a);
    const fx = try Effects.create(std.testing.allocator, all, &a.palettes, 1);
    defer fx.destroy();
    var birds: Birds = .init(.desert, 64, 64, rng, 0);
    try std.testing.expectEqual(6, birds.n);
    var t: f64 = 0;
    while (t < 600) : (t += 0.1) birds.update(fx, rng, t);
    for (birds.birds[0..birds.n]) |b| {
        try std.testing.expect(b.x >= -bird_padding - 10 and b.x <= 64 * 16 + bird_padding + 10);
        try std.testing.expect(b.rise >= 1 and b.rise <= 2);
    }
}

test "hut animals come out, wander near the hut and go back" {
    var prng = std.Random.DefaultPrng.init(9);
    const rng = prng.random();
    var h: Hut = .{ .home_x = 8 * 16 + 8, .home_y = 8 * 16 + 8 };
    for (0..3) |_| h.comeOut(.jungle, null, rng, 0);
    try std.testing.expectEqual(3, h.n);
    var t: f64 = 0;
    while (t < 60) : (t += 0.05) {
        for (h.animals[0..h.n]) |*an| an.update(&h, null, 7 * 16, 0.05, rng, t);
    }
    for (h.animals[0..h.n]) |an| {
        try std.testing.expect(@abs(an.x - 136) < 16 * 16);
    }
    h.sendHome(3);
    t = 60;
    while (t < 200) : (t += 0.05) {
        for (h.animals[0..h.n]) |*an| an.update(&h, null, 7 * 16, 0.05, rng, t);
    }
    for (h.animals[0..h.n]) |an| try std.testing.expect(an.gone);
}
