//! Visual effects: shots, rockets, explosions, debris, wrecks, fires and
//! tank tracks (QZod_DnEffect). They only decorate; the server decides
//! what actually happens.
//!
//! Effects live in two lists: ground effects (tracks, dust, oil) are drawn
//! under the objects, the rest over them. Effects may spawn more effects,
//! leave craters and throw particles off nearby units.

const std = @import("std");
const c = @import("c");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const sprites = @import("sprites.zig");
const Terrain = @import("terrain.zig").Terrain;
const rotozoom = @import("../sdl_rotozoom.zig");
const SoundEffect = @import("sound.zig").Effect;

const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const protocol = @import("../net/protocol.zig");
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Fx = sprites.EffectSprites;

// ---------------------------------------------------------------------------
// Rotated and scaled images
// ---------------------------------------------------------------------------

/// Rotated and scaled copies of images, made when first needed (angles in
/// whole degrees counterclockwise, sizes in steps of 1/20). Copies that
/// were not drawn for a while are dropped.
pub const Transforms = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    frame: u32 = 0,

    const Key = struct { src: *c.SDL_Surface, angle: u16, size: u16 };
    const Entry = struct { img: ?Image, used: u32 };
    const size_steps = 20;
    /// Frames between sweeps, and how long an unused copy is kept.
    const sweep_interval = 128;
    const keep_frames = 256;

    pub fn deinit(t: *Transforms) void {
        var it = t.map.valueIterator();
        while (it.next()) |e| if (e.img) |img| img.deinit();
        t.map.deinit(t.gpa);
    }

    /// `img` turned by `angle` degrees and scaled by `size`; null if that
    /// is too small to see.
    pub fn get(t: *Transforms, img: Image, angle: f64, size: f64) ?Image {
        const a: u16 = @intCast(@mod(@as(i32, @intFromFloat(@round(angle))), 360));
        const s_f = @round(size * size_steps);
        if (!(s_f >= 1)) return null;
        const s: u16 = @intFromFloat(@min(s_f, 10 * size_steps));
        if (a == 0 and s == size_steps) return img;
        const gop = t.map.getOrPut(t.gpa, .{ .src = img.surface, .angle = a, .size = s }) catch return null;
        if (!gop.found_existing) gop.value_ptr.img = make(img, a, s);
        gop.value_ptr.used = t.frame;
        return gop.value_ptr.img;
    }

    fn make(img: Image, angle: u16, size: u16) ?Image {
        const raw: *c.SDL_Surface = rotozoom.rotozoomSurface(img.surface, @floatFromInt(angle), @as(f64, @floatFromInt(size)) / size_steps, 0) orelse return null;
        defer c.SDL_FreeSurface(raw);
        return Image.fromSurface(raw);
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
            if (e.value.img) |img| img.deinit();
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const Point = struct {
    x: f64,
    y: f64,

    fn of(x: i32, y: i32) Point {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }
};

fn int(v: f64) i32 {
    return @intFromFloat(std.math.clamp(@trunc(v), -1e9, 1e9));
}

/// Angle (degrees, counterclockwise from east) of a screen direction.
fn angleOf(dx: f64, dy: f64) f64 {
    if (game.object.isZero(dx) and game.object.isZero(dy)) return 0;
    var a = std.math.atan2(dy, dx);
    if (a < 0) a += 2 * std.math.pi;
    return @mod(@floor(180.0 * a / std.math.pi + 0.5), 360);
}

/// Straight flight from `from` to `to` at `speed` pixels per second.
const Line = struct {
    start: Point,
    end: Point,
    /// Pixels per second.
    vx: f64,
    vy: f64,
    t0: f64,
    t1: f64,

    fn init(from: Point, to: Point, speed: f64, time: f64) Line {
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const duration = @max(@sqrt(dx * dx + dy * dy) / @max(speed, 1), 0.001);
        return .{ .start = from, .end = to, .vx = dx / duration, .vy = dy / duration, .t0 = time, .t1 = time + duration };
    }

    fn at(l: Line, time: f64) Point {
        const d = time - l.t0;
        return .{ .x = l.start.x + l.vx * d, .y = l.start.y + l.vy * d };
    }

    /// How much to turn an image drawn pointing east to fly this way
    /// (the C++ code's `359 - AngleFromLoc`).
    fn imageAngle(l: Line) f64 {
        return 359 - angleOf(l.vx, l.vy);
    }
};

/// Debris flying in an arc: along a line over `lifetime`, lifted by a
/// parabola peaking halfway (`lift` is 0 at both ends).
const Arc = struct {
    line: Line,
    rise: f64,

    fn init(from: Point, to: Point, lifetime: f64, rise: f64, time: f64) Arc {
        const l = @max(lifetime, 0.001);
        return .{ .line = .{ .start = from, .end = to, .vx = (to.x - from.x) / l, .vy = (to.y - from.y) / l, .t0 = time, .t1 = time + l }, .rise = rise };
    }

    fn lift(a: Arc, time: f64) f64 {
        const d = time - a.line.t0;
        return -(a.rise / (a.line.t1 - a.line.t0)) * d * d + a.rise * d;
    }

    fn done(a: Arc, time: f64) bool {
        return time >= a.line.t1;
    }
};

/// Frames advancing at a fixed interval.
const Frames = struct {
    i: u8 = 0,
    next: f64,
    interval: f64,

    fn init(time: f64, interval: f64) Frames {
        return .{ .next = time + interval, .interval = interval };
    }

    /// Advance if it's time; true if the frame changed.
    fn tick(f: *Frames, time: f64) bool {
        if (time < f.next) return false;
        f.next = time + f.interval;
        f.i += 1;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

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
        if (imgs[f.frames.i]) |img| cv.draw(img, f.base_x - ox, f.base_y - oy);
    }

    /// Fires further down the screen are drawn later.
    pub fn lessThan(_: void, a: Fire, b: Fire) bool {
        return a.base_y < b.base_y;
    }
};

pub const TurretPiece = enum {
    light,
    medium,
    heavy,
    gatling,
    gun,
    howitzer,
    missile_cannon,
    building0,
    building1,
    fort0,
    fort1,
    fort2,
    fort3,
    fort4,
    grenade,

    fn frames(p: TurretPiece) u8 {
        return switch (p) {
            .light, .medium, .heavy => 8,
            .building0, .building1, .fort0, .fort1, .fort2, .fort3, .fort4 => 12,
            .grenade => 4,
            else => 1,
        };
    }

    fn image(p: TurretPiece, s: *const Fx, team: k.Team, i: u8) ?Image {
        return switch (p) {
            .light => s.light_turret[i],
            .medium => s.medium_turret[i],
            .heavy => s.heavy_turret[@intFromEnum(team)][i],
            .gatling => s.cannon_wasted[0],
            .gun => s.cannon_wasted[1],
            .howitzer => s.cannon_wasted[2],
            .missile_cannon => s.cannon_wasted[3],
            .building0 => s.building_piece[0][i],
            .building1 => s.building_piece[1][i],
            .fort0 => s.fort_piece[0][i],
            .fort1 => s.fort_piece[1][i],
            .fort2 => s.fort_piece[2][i],
            .fort3 => s.fort_piece[3][i],
            .fort4 => s.fort_piece[4][i],
            .grenade => s.grenade[i],
        };
    }

    fn ofCannon(kind: k.Cannon) TurretPiece {
        return switch (kind) {
            .gatling => .gatling,
            .gun => .gun,
            .howitzer => .howitzer,
            .missile_cannon => .missile_cannon,
        };
    }
};

pub const RocketKind = enum {
    /// Tank and gun shells (ELightRocket); bigger ones make more blasts.
    light,
    /// Tough robot rockets.
    tough,
    /// Missile launcher: three rockets side by side.
    launcher,
    /// Missile cannon: two rockets.
    missile_cannon,
};

const Rocket = struct {
    kind: RocketKind,
    /// Launcher to target; the rocket itself flies `offset` beside it.
    line: Line,
    offset: Point = .{ .x = 0, .y = 0 },
    /// Offset of the side rockets.
    side: Point = .{ .x = 0, .y = 0 },
    angle: f64,
    last_smoke: f64,
    /// Extra blasts at the end (light rockets).
    extra: Blasts = .{},
    /// Radius of the area whose units throw particles.
    particle_radius: i32 = 40,

    const Blasts = struct { small: u8 = 0, large: u8 = 0, xx_large: u8 = 0 };
};

const Effect = union(enum) {
    bullet: struct { team: k.Team, line: Line },
    /// Lasers and pyro flames.
    beam: struct { flame: bool, line: Line, img: u8, angle: f64 },
    rocket: Rocket,
    /// A fixed animation that plays once (fire bursts, mushrooms, smoke,
    /// robots dying, tank dust).
    anim: Anim,
    side_explosion: struct { line: Line, size: f64, frames: Frames },
    /// Bits flying off units and map objects.
    particle: struct { arc: Arc, frames: Frames },
    spark: struct { arc: Arc, frames: Frames },
    robot_flip: struct { team: k.Team, arc: Arc, frames: Frames },
    rock_particle: struct { arc: Arc, frames: Frames, imgs: []const ?Image },
    /// Big rock or bridge pieces; `reversed` flies back in (a bridge
    /// being rebuilt).
    rock_chunk: struct { arc: Arc, frames: Frames, imgs: *const [12]?Image, planet: k.Planet, spin: f64, reversed: bool },
    turret: struct { piece: TurretPiece, team: k.Team, arc: Arc, frames: Frames, spin: f64 },
    map_object: struct { index: u8, arc: Arc, spin: f64, dest: Point },
    /// A destroyed unit burning for a while before blowing apart.
    wreck: Wreck,
    track: struct { imgs: *const [3]?Image, pos: [2][2]i32, lay: [2]bool, start: f64, i: u8 },
};

const Anim = struct {
    imgs: []const ?Image,
    /// Shown instead of `imgs` for the first frames (tank sparks).
    first: []const ?Image = &.{},
    x: i32,
    y: i32,
    frames: Frames,
    size: f64 = 1,
    centered: bool = false,
    /// Mushroom clouds sink as they grow.
    mushroom: bool = false,
    /// Loop until this many frames were shown (0: play once).
    loops: u16 = 0,
    shown: u16 = 0,
    /// Random extra delay per frame (oil stains).
    jitter: f64 = 0,
};

const Wreck = struct {
    img: ?Image,
    x: i32,
    y: i32,
    until: f64,
    /// Up to 5 little fires, 2 big smokes and a fire with smoke.
    fires: [8]Fire = undefined,
    fire_n: u8 = 0,
    /// Cannons throw their gun when the wreck blows.
    gun: ?struct { piece: TurretPiece, to: Point, offset: f64 } = null,
};

const mushroom_shift = [12]f64{ 14, 9, 2, 0, 0, 0, 1, 2, 3, 4, 5, 6 };

/// What effects need to know about the game while updating.
pub const Context = struct {
    time: f64,
    world: *const World,
    terrain: ?*Terrain,
};

pub const Effects = struct {
    gpa: std.mem.Allocator,
    s: *const Fx,
    palettes: *const gfx.TeamPalettes,
    rng: std.Random,
    transforms: Transforms,
    ground: std.ArrayList(Effect) = .empty,
    air: std.ArrayList(Effect) = .empty,
    /// Effects spawned while updating, added afterwards.
    spawned: std.ArrayList(Effect) = .empty,
    /// Sounds made, with where (the app plays those on screen).
    sounds: std.ArrayList(Heard) = .empty,
    time: f64 = 0,
    planet: k.Planet = .desert,
    /// From the server's settings.
    grenade_speed: i32 = 200,

    pub fn init(gpa: std.mem.Allocator, s: *const sprites.Sprites, palettes: *const gfx.TeamPalettes, rng: std.Random) Effects {
        return .{ .gpa = gpa, .s = &s.fx, .palettes = palettes, .rng = rng, .transforms = .{ .gpa = gpa } };
    }

    pub fn deinit(fx: *Effects) void {
        fx.transforms.deinit();
        fx.ground.deinit(fx.gpa);
        fx.air.deinit(fx.gpa);
        fx.spawned.deinit(fx.gpa);
        fx.sounds.deinit(fx.gpa);
    }

    pub const Heard = struct { sound: SoundEffect, where: gfx.Rect };

    /// A sound from the area `where` (map coordinates).
    pub fn sound(fx: *Effects, e: SoundEffect, where: gfx.Rect) void {
        fx.sounds.append(fx.gpa, .{ .sound = e, .where = where }) catch {};
    }

    fn soundAt(fx: *Effects, e: SoundEffect, x: i32, y: i32) void {
        fx.sound(e, .{ .x = x, .y = y, .w = 0, .h = 0 });
    }

    /// A sound from an object's area.
    pub fn soundOf(fx: *Effects, e: SoundEffect, o: *const Object) void {
        fx.sound(e, .{ .x = o.x, .y = o.y, .w = o.width_pix, .h = o.height_pix });
    }

    pub fn reset(fx: *Effects) void {
        fx.ground.clearRetainingCapacity();
        fx.air.clearRetainingCapacity();
        fx.spawned.clearRetainingCapacity();
    }

    fn rand(fx: *Effects, n: u32) i32 {
        return @intCast(fx.rng.uintLessThan(u32, n));
    }

    /// `min` plus up to `spread - 1` more.
    fn count(fx: *Effects, min: usize, spread: usize) usize {
        return min + fx.rng.uintLessThan(usize, spread);
    }

    /// `base + (spread - rand(2 * spread))`: a random offset within ±spread.
    fn around(fx: *Effects, spread: u32) i32 {
        return @as(i32, @intCast(spread)) - fx.rand(2 * spread);
    }

    fn add(fx: *Effects, e: Effect) void {
        fx.spawned.append(fx.gpa, e) catch {};
    }

    /// Wrecks and dying robots go under the other effects.
    fn addUnder(fx: *Effects, e: Effect) void {
        fx.air.insert(fx.gpa, 0, e) catch {};
    }

    fn addGround(fx: *Effects, e: Effect) void {
        fx.ground.insert(fx.gpa, 0, e) catch {};
    }

    // -----------------------------------------------------------------------
    // Spawning
    // -----------------------------------------------------------------------

    /// A machine gun or rifle bullet: a small box in the team's color.
    pub fn bullet(fx: *Effects, team: k.Team, from_x: i32, from_y: i32, to_x: i32, to_y: i32) void {
        fx.add(.{ .bullet = .{ .team = team, .line = .init(.of(from_x, from_y), .of(to_x, to_y), 300, fx.time) } });
    }

    fn beam(fx: *Effects, is_flame: bool, from_x: i32, from_y: i32, to_x: i32, to_y: i32) void {
        const img = if (is_flame) fx.s.flame_bullet[0] else fx.s.laser_bullet[0];
        const first = img orelse return;
        const from: Point = .of(from_x - (first.width() >> 1), from_y - (first.height() >> 1));
        var line: Line = .init(.of(from_x, from_y), .of(to_x, to_y), 300, fx.time);
        const angle = line.imageAngle();
        line.start = from;
        fx.add(.{ .beam = .{ .flame = is_flame, .line = line, .img = @intCast(fx.rand(if (is_flame) 4 else 2)), .angle = angle } });
    }

    pub fn laser(fx: *Effects, from_x: i32, from_y: i32, to_x: i32, to_y: i32) void {
        fx.beam(false, from_x, from_y, to_x, to_y);
    }

    /// A pyro's flame; it sets a small fire where it lands.
    pub fn flame(fx: *Effects, from_x: i32, from_y: i32, to_x: i32, to_y: i32) void {
        fx.beam(true, from_x, from_y, to_x, to_y);
    }

    pub const RocketOptions = struct {
        speed: i32,
        /// Extra blasts (light rockets): small, large and extra large.
        small: u8 = 0,
        large: u8 = 0,
        xx_large: u8 = 0,
        particle_radius: i32 = 40,
    };

    pub fn rocket(fx: *Effects, kind: RocketKind, from_x: i32, from_y: i32, to_x: i32, to_y: i32, o: RocketOptions) void {
        const line: Line = .init(.of(from_x, from_y), .of(to_x, to_y), @floatFromInt(o.speed), fx.time);
        const dx = line.end.x - line.start.x;
        const dy = line.end.y - line.start.y;
        const mag = @max(@sqrt(dx * dx + dy * dy), 0.001);
        const ux = dx / mag;
        const uy = dy / mag;
        var offset: Point = .{ .x = 0, .y = 0 };
        var side: Point = .{ .x = 0, .y = 0 };
        switch (kind) {
            .light => {
                // A muzzle flash; the shell is drawn from its corner.
                fx.anim(.{ .imgs = fx.s.light_init_fire[@intCast(fx.rand(4))..][0..1], .x = from_x - 8, .y = from_y - 7, .frames = .init(fx.time, 0.02) });
                if (fx.s.light_bullet) |img| offset = .of(-(img.width() >> 1), -(img.height() >> 1));
            },
            .tough => {},
            .launcher => side = .{ .x = uy * 8, .y = ux * -8 },
            .missile_cannon => {
                offset = .{ .x = @trunc(uy * -4), .y = @trunc(ux * 8) };
                side = .{ .x = uy * 8, .y = ux * -8 };
            },
        }
        fx.add(.{ .rocket = .{
            .kind = kind,
            .line = line,
            .offset = offset,
            .side = side,
            .angle = line.imageAngle(),
            .last_smoke = fx.time,
            .extra = .{ .small = o.small, .large = o.large, .xx_large = o.xx_large },
            .particle_radius = o.particle_radius,
        } });
    }

    fn anim(fx: *Effects, a: Anim) void {
        fx.add(.{ .anim = a });
    }

    fn mushroom(fx: *Effects, x: i32, y: i32, size: f64) void {
        fx.anim(.{
            .imgs = &fx.s.mushroom,
            .x = x - int(16 * size),
            .y = y - int(32 * size),
            .size = size,
            .mushroom = true,
            .frames = .init(fx.time, 0.08),
        });
    }

    fn toughSmoke(fx: *Effects, x: i32, y: i32) void {
        fx.anim(.{ .imgs = &fx.s.tough_smoke, .x = x, .y = y, .centered = true, .frames = .init(fx.time, 0.12) });
    }

    fn pyroFire(fx: *Effects, x: i32, y: i32) void {
        const kind: usize = @intCast(fx.rand(5));
        const n: usize = if (kind < 3) 4 else 6;
        const first = fx.s.pyro_fire[kind][0] orelse return;
        fx.anim(.{ .imgs = fx.s.pyro_fire[kind][0..n], .x = x - (first.width() >> 1), .y = y - (first.height() >> 1), .frames = .init(fx.time, 0.06) });
    }

    pub fn sideExplosion(fx: *Effects, x: i32, y: i32, size: f64) void {
        const speed: f64 = @floatFromInt(20 + fx.rand(10));
        const dx: f64 = @floatFromInt(fx.around(20));
        const dy: f64 = @floatFromInt(fx.around(20));
        const mag = @max(@sqrt(dx * dx + dy * dy), 0.001);
        const start: Point = .of(x - 16, y - 16);
        fx.add(.{ .side_explosion = .{
            .line = .{ .start = start, .end = start, .vx = dx / mag * speed, .vy = dy / mag * speed, .t0 = fx.time, .t1 = fx.time },
            .size = size,
            .frames = .init(fx.time, 0.13),
        } });
    }

    /// A bit of debris flying off a unit.
    pub fn particle(fx: *Effects, x0: i32, y0: i32, horz: u32, vert: u32) void {
        const lifetime = 1.4 + 0.1 * @as(f64, @floatFromInt(fx.rand(10)));
        const x = x0 + fx.rand(8);
        const y = y0 + fx.rand(24);
        const to: Point = .of(x + fx.around(horz), y + fx.around(vert));
        const rise = 1.1 + 0.01 * @as(f64, @floatFromInt(fx.rand(30)));
        fx.add(.{ .particle = .{ .arc = .init(.of(x - 8, y - 5), to, lifetime, rise, fx.time), .frames = .init(fx.time, 0.03) } });
    }

    fn spark(fx: *Effects, x0: i32, y0: i32) void {
        const lifetime = 1.5 + 0.1 * @as(f64, @floatFromInt(fx.rand(3)));
        const x = x0 + 2 - fx.rand(5);
        const y = y0 + 2 - fx.rand(5);
        // Further down and sideways than up.
        const to: Point = .of(x + 180 - fx.rand(360), y + 150 - fx.rand(220));
        const rise = 3 + 0.01 * @as(f64, @floatFromInt(fx.rand(300)));
        fx.add(.{ .spark = .{ .arc = .init(.of(x - 8, y - 5), to, lifetime, rise, fx.time), .frames = .init(fx.time, 0.1) } });
    }

    fn sparks(fx: *Effects, x: i32, y: i32, min: u32, spread: u32) void {
        const n = min + fx.rng.uintLessThan(u32, spread);
        for (0..n) |_| fx.spark(x, y);
    }

    /// A robot thrown through the air (killed by a blast, or sniped out of
    /// a vehicle).
    pub fn robotFlip(fx: *Effects, team: k.Team, x0: i32, y0: i32) void {
        if (team == .none) return;
        const lifetime = 3.5 + 0.1 * @as(f64, @floatFromInt(fx.rand(10)));
        const x = x0 + 2 - fx.rand(5);
        const y = y0 + 2 - fx.rand(5);
        const to: Point = .of(x + fx.around(100), y + fx.around(100));
        const rise = 1.3 + 0.01 * @as(f64, @floatFromInt(fx.rand(200)));
        fx.add(.{ .robot_flip = .{ .team = team, .arc = .init(.of(x, y), to, lifetime, rise, fx.time), .frames = .init(fx.time, 0.05) } });
    }

    fn rockParticle(fx: *Effects, x0: i32, y0: i32, mid: bool, horz: u32, vert: u32) void {
        const p = @intFromEnum(fx.planet);
        const imgs: []const ?Image = if (!mid) &fx.s.rock_small[p] else &fx.s.rock_mid[@intCast(fx.rand(2))][p];
        const lifetime = 1.1 + 0.1 * @as(f64, @floatFromInt(fx.rand(10)));
        const x = x0 + fx.rand(8);
        const y = y0 + fx.rand(24);
        const to: Point = .of(x + fx.around(horz), y + fx.around(vert));
        const rise = 1.1 + 0.01 * @as(f64, @floatFromInt(fx.rand(30)));
        fx.add(.{ .rock_particle = .{ .arc = .init(.of(x - 8, y - 5), to, lifetime, rise, fx.time), .frames = .init(fx.time, 0.07), .imgs = imgs } });
    }

    fn rockChunk(fx: *Effects, x0: i32, y0: i32, bridge: bool, reversed: bool) void {
        const p = @intFromEnum(fx.planet);
        const imgs = if (bridge)
            &fx.s.bridge_debris[p]
        else switch (fx.planet) {
            .city, .desert => &fx.s.rock_large[0][p],
            else => &fx.s.rock_large[@intCast(fx.rand(2))][p],
        };
        const lifetime = 1.5 + 0.1 * @as(f64, @floatFromInt(fx.rand(10)));
        const x = x0 + fx.rand(8);
        const y = y0 + fx.rand(24);
        var from: Point = .of(x - 8, y - 5);
        var to: Point = .of(x + fx.around(140), y + fx.around(140));
        if (reversed) std.mem.swap(Point, &from, &to);
        const rise = 1.1 + 0.01 * @as(f64, @floatFromInt(fx.rand(200)));
        fx.add(.{ .rock_chunk = .{
            .arc = .init(from, to, lifetime, rise, fx.time),
            .frames = .init(fx.time, 0.07),
            .imgs = imgs,
            .planet = fx.planet,
            .spin = @floatFromInt(240 - fx.rand(480)),
            .reversed = reversed,
        } });
    }

    /// A piece (turret, gun, building part or grenade) thrown to (x, y),
    /// landing after `offset` seconds.
    pub fn turret(fx: *Effects, piece: TurretPiece, team: k.Team, from_x: i32, from_y: i32, to_x: i32, to_y: i32, offset: f64) void {
        if (piece == .heavy and team == .none) return;
        const rise = 1 + 0.01 * @as(f64, @floatFromInt(fx.rand(300)));
        const from: Point = .of(from_x + 5 - fx.rand(10), from_y + 5 - fx.rand(10));
        var arc: Arc = .init(from, .of(to_x, to_y), @abs(offset), rise, fx.time);
        // A late piece (offset used up by the burning wreck) lands at once.
        if (offset <= 0) arc.line.t1 = fx.time;
        fx.add(.{ .turret = .{ .piece = piece, .team = team, .arc = arc, .frames = .init(fx.time, 0.1), .spin = @floatFromInt(240 - fx.rand(480)) } });
    }

    fn mapObjectPiece(fx: *Effects, index: u8, from_x: i32, from_y: i32, to_x: i32, to_y: i32, offset: f64) void {
        const i = @min(index, sprites.map_objects - 1);
        const rise = 0.5 + 0.01 * @as(f64, @floatFromInt(fx.rand(100)));
        const my: i32 = if (fx.s.map_object[i]) |img| 16 - img.height() else 0;
        const from: Point = .of(from_x + 5 - fx.rand(10), from_y + 5 - fx.rand(10) + my);
        var spin: f64 = @floatFromInt(240 - fx.rand(480));
        spin += if (spin >= 0) 100 else -100;
        fx.add(.{ .map_object = .{ .index = i, .arc = .init(from, .of(to_x, to_y + my), offset, rise, fx.time), .spin = spin, .dest = .of(to_x, to_y) } });
    }

    const WreckKind = enum { jeep, launcher, apc, crane, tank };

    fn wreck(fx: *Effects, kind: WreckKind, img: ?Image, x: i32, y: i32) void {
        var w: Wreck = .{ .img = img, .x = x, .y = y, .until = fx.time + 5 + @as(f64, @floatFromInt(fx.rand(3))) };
        // Where fires burn on the wreck.
        const bx: i32, const by: i32, const bw: u32, const bh: u32 = switch (kind) {
            .jeep => .{ 5, 14, 22, 10 },
            .launcher => .{ 5, 10, 21, 19 },
            .apc => .{ 5, 8, 18, 20 },
            .crane => .{ 4, 9, 23, 19 },
            .tank => .{ 8, 8, 16, 16 },
        };
        const counts = [_]struct { FireKind, u32, u32 }{ .{ .little_fire, 3, 3 }, .{ .big_smoke, 1, 2 }, .{ .small_fire_smoke, 0, 2 } };
        for (counts) |kc| {
            const n = kc[1] + fx.rng.uintLessThan(u32, kc[2]);
            for (0..n) |_| {
                w.fires[w.fire_n] = .init(kc[0], x + bx + fx.rand(bw), y + by + fx.rand(bh), fx.rng, fx.time);
                w.fire_n += 1;
            }
        }
        std.mem.sort(Fire, w.fires[0..w.fire_n], {}, Fire.lessThan);
        fx.addUnder(.{ .wreck = w });
    }

    /// Tank tracks, dust, smoke and oil behind a moving vehicle
    /// (ZVehicle::TryDropTracks; call every 0.2 s while it moves).
    pub fn vehicleTrail(fx: *Effects, o: *const Object, direction: u3, map: *const game.map.Map, terrain_info: *const game.map.Terrain) void {
        const veh = o.kind.vehicle;
        const cx = o.center_x;
        const cy = o.center_y;
        const pos = trackCoords(cx, cy, direction, fx.rng);
        var lay: [2]bool = .{ false, false };
        for (&lay, pos) |*l, p| {
            const on_road = for ([_][2]i32{ .{ 0, 0 }, .{ 0, -16 }, .{ 0, 16 }, .{ -16, 0 }, .{ 16, 0 } }) |d| {
                if (map.isRoad(terrain_info, p[0] + d[0], p[1] + d[1])) break true;
            } else false;
            if (!on_road and fx.rand(5) != 0) l.* = true;
        }
        const p = @intFromEnum(fx.planet);
        if (lay[0] or lay[1]) {
            const kind: usize = if (veh.type == .jeep) 1 else 0;
            const imgs = &fx.s.track[kind][p][direction];
            if (imgs[0] != null) fx.addGround(.{ .track = .{ .imgs = imgs, .pos = pos, .lay = lay, .start = fx.time + 0.1 * @as(f64, @floatFromInt(fx.rand(10))), .i = 0 } });
            for (lay, pos) |l, pt| {
                if (!l or fx.rand(4) == 0) continue;
                const dirts: u32 = switch (fx.planet) {
                    .jungle => 1,
                    .city => 0,
                    else => 2,
                };
                if (dirts == 0) continue;
                const d: usize = @intCast(fx.rand(dirts));
                const first = fx.s.tank_dirt[p][d][0] orelse continue;
                const n: usize = if (fx.planet == .jungle) 6 else 5;
                fx.addGround(.{ .anim = .{ .imgs = fx.s.tank_dirt[p][d][0..n], .x = pt[0] - (first.width() >> 1), .y = pt[1] - first.height(), .frames = .init(fx.time, 0.15) } });
            }
        }
        if (o.showPartiallyDamaged() and fx.rand(3) == 0) fx.tankSmoke(cx, cy, direction, false);
        if (o.showDamaged()) {
            if (fx.rand(3) == 0) fx.tankSmoke(cx, cy, direction, true);
            if (fx.rand(16) == 0) {
                const at = fx.oilCoords(cx, cy, direction, 5, 3, 7);
                fx.addGround(.{ .anim = .{ .imgs = &fx.s.tank_oil[@intCast(fx.rand(3))], .x = at[0], .y = at[1], .centered = true, .frames = .init(fx.time, 3.0 + 0.1 * @as(f64, @floatFromInt(fx.rand(10)))), .jitter = 1.0 } });
            }
            if (fx.rand(48) == 0) {
                const at = fx.oilCoords(cx, cy, direction, 3, 5, 11);
                const loops: u16 = @intCast(36 + fx.rand(25));
                fx.addGround(.{ .anim = .{ .imgs = &fx.s.ground_spark, .x = at[0], .y = at[1], .centered = true, .frames = .init(fx.time, 0.1), .loops = loops } });
            }
        }
    }

    /// Where a damaged tank drips oil or scrapes sparks.
    fn oilCoords(fx: *Effects, cx0: i32, cy0: i32, direction: u3, down: i32, back: i32, spread: u32) [2]i32 {
        var cx = cx0;
        var cy = cy0;
        switch (direction) {
            0 => cx -= 5,
            4 => cx += 5,
            2 => cy += 5,
            6 => cy -= 5,
            1 => {
                cx -= 4;
                cy += 4;
            },
            3 => {
                cx += 4;
                cy += 4;
            },
            5 => {
                cx += 4;
                cy -= 4;
            },
            7 => {
                cx -= 4;
                cy -= 4;
            },
        }
        cy += down;
        cx -= back;
        cy -= back;
        cx += fx.rand(spread);
        cy += fx.rand(spread);
        return .{ cx, cy };
    }

    fn tankSmoke(fx: *Effects, cx: i32, cy: i32, direction: u3, with_sparks: bool) void {
        const imgs = &fx.s.track_dust[direction];
        const first = imgs[0] orelse return;
        const w = first.width();
        const h = first.height();
        var x = cx;
        var y = cy;
        switch (direction) {
            0 => {
                x -= 15 + w;
                y += fx.rand(8) - h;
            },
            4 => {
                x += 15;
                y += fx.rand(8) - h;
            },
            2 => {
                y += 15;
                x += fx.rand(9) - 12;
            },
            6 => {
                y -= 15 + h;
                x += fx.rand(9) - 12;
            },
            1 => {
                const shift = fx.rand(7);
                x += shift - 13 - w;
                y += 7 + shift;
            },
            3 => {
                const shift = fx.rand(7);
                x += 13 - shift;
                y += 7 + shift;
            },
            5 => {
                const shift = fx.rand(7);
                x += 6 + shift;
                y += shift - 12 - h;
            },
            7 => {
                const shift = fx.rand(7);
                x -= 6 + shift + w;
                y += shift - 12 - h;
            },
        }
        fx.addGround(.{ .anim = .{
            .imgs = imgs,
            .first = if (with_sparks) &fx.s.track_spark[direction] else &.{},
            .x = x,
            .y = y,
            .frames = .init(fx.time, 0.15),
        } });
    }

    // -----------------------------------------------------------------------
    // Units firing and dying
    // -----------------------------------------------------------------------

    /// A random point on `target` (where a bullet hits).
    pub fn pointOn(fx: *Effects, target: *const Object) [2]i32 {
        return .{ target.x + fx.rand(@intCast(@max(target.width_pix, 1))), target.y + fx.rand(@intCast(@max(target.height_pix, 1))) };
    }

    /// The server says `o` fired at (x, y) (FireMissile of each unit).
    pub fn fireMissile(fx: *Effects, o: *const Object, x: i32, y: i32, direction: u3, turret_direction: u3, target: ?*const Object, tough_rocket: bool) void {
        // Muzzles of cannons and tanks, per direction.
        const mx = [8]i32{ 20, 12, 0, -12, -20, -12, 0, 12 };
        const my = [8]i32{ 0, -12, -20, -12, 0, 12, 20, 12 };
        switch (o.kind) {
            .cannon => |cn| {
                const sx = o.x + 17 + mx[direction];
                const sy = o.y + 14 + my[direction];
                switch (cn.type) {
                    .gun => fx.rocket(.light, sx, sy, x, y, .{ .speed = o.missile_speed, .large = 1 }),
                    .howitzer => fx.rocket(.light, sx, sy, x, y, .{ .speed = o.missile_speed, .small = 1, .large = 1 }),
                    .missile_cannon => fx.rocket(.missile_cannon, sx, sy, x, y, .{ .speed = o.missile_speed, .particle_radius = o.damage_radius }),
                    .gatling => {},
                }
                fx.soundOf(switch (cn.type) {
                    .gun => .gun_fire,
                    .howitzer => .heavy_fire,
                    .missile_cannon => .missile_fire,
                    .gatling => .gatling_fire,
                }, o);
            },
            .vehicle => |veh| {
                const sx = o.x + 17 + mx[turret_direction];
                const sy = o.y + 14 + my[turret_direction];
                switch (veh.type) {
                    .light => fx.rocket(.light, sx, sy, x, y, .{ .speed = o.missile_speed }),
                    .medium => fx.rocket(.light, sx, sy, x, y, .{ .speed = o.missile_speed, .large = 1 }),
                    .heavy => fx.rocket(.light, sx, sy, x, y, .{ .speed = o.missile_speed, .large = 1, .xx_large = 1 }),
                    .missile_launcher => fx.rocket(.launcher, sx, sy, x, y, .{ .speed = o.missile_speed, .particle_radius = o.damage_radius }),
                    .apc => if (target) |tg| {
                        fx.soundOf(.tough_fire, o);
                        // One rocket for each tough inside.
                        fx.rocket(.tough, o.x + 16, o.y + 16, x, y, .{ .speed = o.missile_speed });
                        for (1..o.drivers.items.len) |_| {
                            const p = fx.pointOn(tg);
                            fx.rocket(.tough, o.x + 16, o.y + 16, p[0], p[1], .{ .speed = o.missile_speed });
                        }
                    },
                    else => {},
                }
                switch (veh.type) {
                    .light => fx.soundOf(.light_fire, o),
                    .medium => fx.soundOf(.medium_fire, o),
                    .heavy => fx.soundOf(.heavy_fire, o),
                    .missile_launcher => fx.soundOf(.missile_fire, o),
                    else => {},
                }
            },
            .robot => if (tough_rocket) {
                if (target != null) {
                    const d = robotMuzzle(direction);
                    fx.rocket(.tough, o.x + 8 + d[0], o.y + 8 + d[1], x, y, .{ .speed = o.missile_speed });
                    fx.soundOf(.tough_fire, o);
                }
            } else {
                // A grenade.
                const dx: f64 = @floatFromInt(o.center_x - x);
                const dy: f64 = @floatFromInt(o.center_y - y);
                const speed: f64 = @floatFromInt(@max(fx.grenade_speed, 1));
                fx.turret(.grenade, .none, o.center_x + 2, o.center_y + 2, x, y, @sqrt(dx * dx + dy * dy) / speed);
                fx.soundOf(.throw_grenade, o);
            },
            else => {},
        }
    }

    /// Where a robot's gun is, per direction.
    pub fn robotMuzzle(direction: u3) [2]i32 {
        const t = [8][2]i32{ .{ 8, 0 }, .{ 8, -8 }, .{ 0, -8 }, .{ -8, -8 }, .{ -8, 0 }, .{ -8, 8 }, .{ 0, 8 }, .{ 8, 8 } };
        return t[direction];
    }

    /// How a unit looked when it died (tanks leave that picture).
    pub const Look = struct { direction: u3 = 0, move_i: u8 = 0 };

    /// `o` was destroyed (DoDeathEffect + FireTurrentMissile).
    pub fn destroyed(fx: *Effects, o: *const Object, look: Look, fire_death: bool, missile_death: bool, missiles: []const protocol.FireMissileInfo, all_sprites: *const sprites.Sprites) void {
        switch (o.kind) {
            .robot => if (missile_death)
                fx.robotFlip(o.owner, o.center_x, o.center_y)
            else if (o.owner != .none) {
                const team = @intFromEnum(o.owner);
                const imgs: []const ?Image = if (fire_death) &fx.s.robot_melt[team] else blk: {
                    const d: usize = @intCast(fx.rand(4));
                    break :blk fx.s.robot_die[d][team][0..if (d == 3) 8 else 10];
                };
                fx.addUnder(.{ .anim = .{ .imgs = imgs, .x = o.x, .y = o.y, .frames = .init(fx.time, 0.16) } });
            },
            .vehicle => |veh| switch (veh.type) {
                .jeep => fx.wreck(.jeep, fx.s.jeep_wasted, o.x, o.y),
                .missile_launcher => fx.wreck(.launcher, fx.s.missile_launcher_wasted, o.x, o.y),
                .apc => fx.wreck(.apc, fx.s.apc_wasted, o.x, o.y),
                .crane => fx.wreck(.crane, fx.s.crane_wasted, o.x, o.y),
                .light, .medium, .heavy => {
                    const img = all_sprites.vehicle[@intFromEnum(veh.type)].damaged[@intFromEnum(o.owner)][look.direction][@min(look.move_i, 2)];
                    if (img != null) fx.wreck(.tank, img, o.x, o.y);
                },
            },
            .building => |b| switch (b.type) {
                .bridge_vert, .bridge_horz => fx.bridgeDebris(o, false),
                else => fx.buildingExplosion(o, b.type),
            },
            .item => |it| switch (it) {
                .rock => {
                    for (0..fx.count(12, 6)) |_| fx.rockParticle(o.x, o.y, false, 80, 60);
                    for (0..fx.count(4, 3)) |_| fx.rockParticle(o.x, o.y, true, 40, 40);
                    for (0..fx.count(0, 2)) |_| fx.rockChunk(o.x, o.y, false, false);
                },
                else => if (it.mapObjectIndex() != null) {
                    for (0..fx.count(10, 8)) |_| fx.particle(o.x, o.y, 65, 55);
                    fx.sparks(o.x + 16, o.y + 16, 20, 20);
                },
            },
            else => {},
        }

        for (missiles) |m| switch (o.kind) {
            .cannon => |cn| {
                // The wreck smoulders for 2-4 s, then its gun flies off.
                const burn: f64 = @floatFromInt(2 + fx.rand(3));
                var w: Wreck = .{ .img = fx.s.cannon_wasted[@intFromEnum(TurretPiece.ofCannon(cn.type)) - @intFromEnum(TurretPiece.gatling)], .x = o.x, .y = o.y, .until = fx.time + burn };
                w.gun = .{ .piece = .ofCannon(cn.type), .to = .of(m.x, m.y), .offset = m.offset_time - burn };
                fx.addUnder(.{ .wreck = w });
            },
            .vehicle => |veh| switch (veh.type) {
                .light => fx.turret(.light, o.owner, o.x + 8, o.y + 8, m.x, m.y, m.offset_time),
                .medium => fx.turret(.medium, o.owner, o.x + 8, o.y + 8, m.x, m.y, m.offset_time),
                .heavy => fx.turret(.heavy, o.owner, o.x + 8, o.y + 8, m.x, m.y, m.offset_time),
                else => {},
            },
            .item => |it| if (it == .grenades) {
                fx.turret(.grenade, .none, o.x + 2, o.y + 2, m.x, m.y, m.offset_time);
            } else if (it.mapObjectIndex()) |i| {
                fx.mapObjectPiece(i, o.x, o.y, m.x, m.y, m.offset_time);
            },
            else => {},
        };
    }

    /// A bridge falls apart, or (`reversed`) its pieces fly back together.
    pub fn bridgeDebris(fx: *Effects, o: *const Object, reversed: bool) void {
        if (o.kind.building.type == .bridge_vert) {
            const x = o.x + 16;
            var y = o.y + 16 + 5 + fx.rand(10);
            while (y < o.y + o.height_pix - 16) : (y += 5 + fx.rand(10)) fx.rockChunk(x + fx.rand(32), y, true, reversed);
        } else {
            var x = o.x + 16 + 5 + fx.rand(10);
            const y = o.y + 16;
            while (x < o.x + o.width_pix - 16) : (x += 5 + fx.rand(10)) fx.rockChunk(x, y + fx.rand(32), true, reversed);
        }
    }

    fn buildingExplosion(fx: *Effects, o: *const Object, kind: k.Building) void {
        const box = effectsBox(o);
        fx.soundOf(.explosion, o);
        // Fireballs, then pieces: counts and flight times per building.
        const balls: u32, const balls_spread: u32, const pieces: u32, const pieces_spread: u32, const flight: f64 = switch (kind) {
            .fort_front, .fort_back => .{ 12, 6, 16, 6, 3 },
            .radar => .{ 4, 3, 3, 3, 1.5 },
            .repair => .{ 6, 3, 4, 3, 1.5 },
            else => .{ 8, 3, 6, 3, 1.5 },
        };
        const is_fort = kind == .fort_front or kind == .fort_back;
        for (0..balls + fx.rng.uintLessThan(u32, balls_spread)) |_| {
            fx.sideExplosion(o.x + box.x + fx.rand(@intCast(box.w)), o.y + box.y + fx.rand(@intCast(box.h)), 1.3);
        }
        for (0..pieces + fx.rng.uintLessThan(u32, pieces_spread)) |_| {
            const sx = o.x + box.x + fx.rand(@intCast(box.w));
            const sy = o.y + box.y + fx.rand(@intCast(box.h));
            const ex = o.x + (o.width_pix >> 1) + fx.around(200);
            const ey = o.y + (o.height_pix >> 1) + fx.around(200);
            const offset = flight + 0.01 * @as(f64, @floatFromInt(fx.rand(200)));
            const piece: TurretPiece = if (is_fort)
                @enumFromInt(@intFromEnum(TurretPiece.fort0) + @as(u8, @intCast(fx.rand(5))))
            else if (fx.rand(2) == 0) .building0 else .building1;
            fx.turret(piece, .none, sx, sy, ex, ey, offset);
        }
    }

    /// Units near a blast throw off particles (ZPlayer::MissileObjectParticles).
    fn unitParticles(fx: *Effects, world: *const World, x: i32, y: i32, radius0: i32, amount: u32) void {
        const radius = @divTrunc(radius0 * 8, 10);
        for (world.objects.items) |o| {
            switch (o.kind) {
                .cannon, .vehicle, .robot => {},
                else => continue,
            }
            if (o.x > x + radius or o.x + o.width_pix < x - radius) continue;
            if (o.y > y + radius or o.y + o.height_pix < y - radius) continue;
            var n = 14 + fx.rng.uintLessThan(u32, @max(amount, 1));
            if (o.kind == .robot) n /= 2;
            for (0..n) |_| fx.particle(o.x + fx.rand(@intCast(@max(o.width_pix, 1))), o.y + fx.rand(@intCast(@max(o.height_pix, 1))), 25, 25);
        }
    }

    // -----------------------------------------------------------------------
    // Updating
    // -----------------------------------------------------------------------

    pub fn update(fx: *Effects, ctx: Context) void {
        fx.time = ctx.time;
        fx.grenade_speed = ctx.world.settings.grenade_missile_speed;
        if (ctx.world.map) |m| fx.planet = m.planet();
        inline for (.{ &fx.ground, &fx.air }) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (fx.step(&list.items[i], ctx)) {
                    i += 1;
                } else {
                    _ = list.orderedRemove(i);
                }
            }
        }
        fx.air.appendSlice(fx.gpa, fx.spawned.items) catch {};
        fx.spawned.clearRetainingCapacity();
    }

    /// Advance one effect; false when it is over.
    fn step(fx: *Effects, e: *Effect, ctx: Context) bool {
        const t = ctx.time;
        switch (e.*) {
            .bullet => |b| if (t >= b.line.t1) {
                for (0..fx.count(0, 3)) |_| fx.particle(int(b.line.end.x), int(b.line.end.y), 25, 25);
                fx.soundAt(.ricochet, int(b.line.end.x), int(b.line.end.y));
                return false;
            },
            .beam => |*b| if (t >= b.line.t1) {
                if (b.flame) fx.pyroFire(int(b.line.end.x), int(b.line.end.y));
                return false;
            },
            .rocket => |*r| return fx.stepRocket(r, ctx),
            .anim => |*a| {
                if (a.frames.tick(t)) {
                    if (a.jitter > 0) a.frames.next = t + a.frames.interval + 0.1 * @as(f64, @floatFromInt(fx.rand(10)));
                    a.shown += 1;
                    if (a.loops > 0) {
                        if (a.frames.i >= a.imgs.len) a.frames.i = 0;
                        if (a.shown >= a.loops) return false;
                    } else if (a.frames.i >= a.imgs.len) return false;
                }
            },
            .side_explosion => |*s| if (s.frames.tick(t) and s.frames.i >= 7) return false,
            .particle => |*p| {
                if (p.arc.done(t)) return false;
                if (p.frames.tick(t) and p.frames.i >= 20) p.frames.i = 0;
            },
            .spark => |*p| {
                if (p.arc.done(t)) return false;
                if (p.frames.tick(t) and p.frames.i >= 6) p.frames.i = 0;
            },
            .robot_flip => |*p| {
                if (t >= p.frames.next) {
                    // Tumbles through the air, then lies and gets up.
                    p.frames.i += 1;
                    if (t < p.arc.line.t1) {
                        p.frames.next = t + 0.05;
                        if (p.frames.i > 7) p.frames.i = 0;
                    } else {
                        p.frames.next = t + 0.15;
                        if (p.frames.i < 8) p.frames.i = 8;
                    }
                    if (p.frames.i > 32) return false;
                }
            },
            .rock_particle => |*p| {
                if (p.arc.done(t)) return false;
                if (p.frames.tick(t) and p.frames.i >= 6) p.frames.i = 0;
            },
            .rock_chunk => |*p| {
                if (p.arc.done(t)) {
                    if (!p.reversed) {
                        const at = p.arc.line.at(t);
                        for (0..fx.count(12, 6)) |_| fx.rockParticle(int(at.x), int(at.y - (p.arc.lift(t)) * 30), false, 80, 60);
                    }
                    return false;
                }
                if (p.frames.tick(t) and p.frames.i >= 12) p.frames.i = 0;
            },
            .turret => |*p| {
                if (p.arc.done(t)) {
                    const at = p.arc.line.at(t);
                    const ex = int(p.arc.line.end.x);
                    const ey = int(p.arc.line.end.y);
                    fx.mushroom(ex + 7 - fx.rand(14), ey - fx.rand(14), 1.3);
                    fx.sideExplosion(ex + fx.around(24), ey + fx.around(24), 1.0);
                    const lift = p.arc.lift(t) + 1;
                    fx.sparks(int(at.x) + 16, int(at.y - lift * 30 + 30) + 16, 30, 30);
                    if (ctx.terrain) |tr| tr.crater(fx.rng, ex, ey, false, 0.35);
                    fx.soundAt(.turret_explosion, ex, ey);
                    return false;
                }
                if (p.frames.tick(t) and p.frames.i >= p.piece.frames()) p.frames.i = 0;
            },
            .map_object => |*p| if (p.arc.done(t)) {
                const dx = int(p.dest.x);
                const dy = int(p.dest.y);
                fx.mushroom(dx, dy, 1.0);
                for (0..fx.count(10, 8)) |_| fx.particle(dx, dy, 65, 55);
                fx.soundAt(.turret_explosion, int(p.arc.line.end.x), int(p.arc.line.end.y));
                return false;
            },
            .wreck => |*w| {
                if (t >= w.until) {
                    if (w.gun) |g| {
                        fx.sparks(w.x + 16, w.y + 16, 20, 15);
                        fx.turret(g.piece, .none, w.x, w.y, int(g.to.x), int(g.to.y), g.offset);
                    } else fx.sparks(w.x + 16, w.y + 16, 40, 30);
                    return false;
                }
                for (w.fires[0..w.fire_n]) |*f| f.update(t);
            },
            .track => |*tr| {
                const d = t - tr.start;
                if (d >= 3.9) return false;
                tr.i = if (d >= 3.6) 2 else if (d >= 3.3) 1 else 0;
            },
        }
        return true;
    }

    fn stepRocket(fx: *Effects, r: *Rocket, ctx: Context) bool {
        const t = ctx.time;
        if (t < r.line.t1) {
            // Smoke trails.
            if (r.kind == .light) return true;
            const speed = @sqrt(r.line.vx * r.line.vx + r.line.vy * r.line.vy);
            const back = 6.0 / @max(speed, 1);
            const every = 8.0 / @max(speed, 1);
            while (t - r.last_smoke > every) : (r.last_smoke += every) {
                const at = r.line.at(r.last_smoke - back);
                const x = at.x + r.offset.x;
                const y = at.y + r.offset.y;
                fx.toughSmoke(int(x), int(y));
                if (r.kind != .tough) fx.toughSmoke(int(x + r.side.x), int(y + r.side.y));
                if (r.kind == .launcher) fx.toughSmoke(int(x - r.side.x), int(y - r.side.y));
            }
            return true;
        }
        const ex = int(r.line.end.x);
        const ey = int(r.line.end.y);
        fx.soundAt(.explosion, ex, ey);
        switch (r.kind) {
            .light => {
                const e = r.extra;
                for (0..e.xx_large) |_| fx.mushroom(ex + 9 - fx.rand(18), ey - fx.rand(18), 1.5);
                for (0..e.large) |_| fx.mushroom(ex + 7 - fx.rand(14), ey - fx.rand(14), 1.3);
                for (0..e.small) |_| fx.mushroom(ex + 5 - fx.rand(10), ey - fx.rand(10), 1.0);
                fx.mushroom(ex, ey, 1.0);
                fx.unitParticles(ctx.world, ex, ey, 40, 7 + @as(u32, e.small) * 2 + @as(u32, e.large) * 3 + @as(u32, e.xx_large) * 4);
                if (ctx.terrain) |tr| {
                    const chance = fx.rng.float(f64);
                    const big = (e.xx_large > 0 and chance <= 0.35) or (e.large > 0 and chance <= 0.15);
                    tr.crater(fx.rng, ex, ey, big, 0.75);
                }
            },
            .tough => {
                fx.mushroom(ex, ey, 1.0);
                if (ctx.terrain) |tr| tr.crater(fx.rng, ex, ey, false, 0.35);
            },
            .launcher => {
                for (0..3) |_| fx.mushroom(ex + 9 - fx.rand(18), ey - fx.rand(18), 1.5);
                for (0..2) |_| fx.mushroom(ex + 5 - fx.rand(10), ey - fx.rand(10), 1.0);
                fx.mushroom(ex, ey, 1.0);
                fx.unitParticles(ctx.world, ex, ey, r.particle_radius, 7 + 2 * 2 + 3 * 4);
                if (ctx.terrain) |tr| tr.crater(fx.rng, ex, ey, true, 0.75);
            },
            .missile_cannon => {
                for (0..3) |_| fx.mushroom(ex + 7 - fx.rand(14), ey - fx.rand(14), 1.3);
                fx.mushroom(ex + 5 - fx.rand(10), ey - fx.rand(10), 1.0);
                fx.mushroom(ex, ey, 1.0);
                fx.unitParticles(ctx.world, ex, ey, r.particle_radius, 7 + 1 * 2 + 3 * 3);
                if (ctx.terrain) |tr| tr.crater(fx.rng, ex, ey, false, 1.0);
            },
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    /// Draw `img` turned and scaled, from its corner or centered on (x, y).
    fn put(fx: *Effects, cv: Canvas, view: gfx.Rect, img: ?Image, x: i32, y: i32, angle: f64, size: f64, centered: bool) void {
        const i = img orelse return;
        // Skip what is well off screen before transforming.
        const margin = 2 * @max(i.width(), i.height()) + 32;
        if (x < view.x - margin or y < view.y - margin or x > view.x + view.w + margin or y > view.y + view.h + margin) return;
        const out = fx.transforms.get(i, angle, size) orelse return;
        if (centered) cv.drawCentered(out, x, y) else cv.draw(out, x, y);
    }

    /// Tracks, dust and oil: under the objects.
    pub fn drawGround(fx: *Effects, cv: Canvas, view: gfx.Rect) void {
        for (fx.ground.items) |*e| fx.drawOne(e, cv, view);
    }

    /// Everything else: over the objects.
    pub fn draw(fx: *Effects, cv: Canvas, view: gfx.Rect) void {
        for (fx.air.items) |*e| fx.drawOne(e, cv, view);
        fx.transforms.endFrame();
    }

    fn drawOne(fx: *Effects, e: *Effect, cv: Canvas, view: gfx.Rect) void {
        const s = fx.s;
        const t = fx.time;
        switch (e.*) {
            .bullet => |b| {
                const at = b.line.at(t);
                const col = fx.palettes.color(b.team);
                cv.fill(.{ .x = int(at.x), .y = int(at.y), .w = 2, .h = 2 }, col);
            },
            .beam => |*b| {
                const at = b.line.at(t);
                const img = if (b.flame) s.flame_bullet[b.img] else s.laser_bullet[b.img];
                fx.put(cv, view, img, int(at.x), int(at.y), b.angle, 1, false);
                // Flames flicker.
                if (b.flame) b.img = @intCast(fx.rand(4));
            },
            .rocket => |r| {
                var at = r.line.at(t);
                at.x += r.offset.x;
                at.y += r.offset.y;
                const x = int(at.x);
                const y = int(at.y);
                switch (r.kind) {
                    .light => fx.put(cv, view, s.light_bullet, x, y, r.angle, 1, false),
                    .tough => fx.put(cv, view, s.tough_bullet[0], x, y, r.angle, 1, true),
                    .launcher => {
                        fx.put(cv, view, s.mo_bullet, x, y, r.angle, 1, true);
                        fx.put(cv, view, s.mo_bullet, int(at.x + r.side.x), int(at.y + r.side.y), r.angle, 1, true);
                        fx.put(cv, view, s.mo_bullet, int(at.x - r.side.x), int(at.y - r.side.y), r.angle, 1, true);
                    },
                    .missile_cannon => {
                        fx.put(cv, view, s.mc_bullet, x, y, r.angle, 1, true);
                        fx.put(cv, view, s.mc_bullet, int(at.x + r.side.x), int(at.y + r.side.y), r.angle, 1, true);
                    },
                }
            },
            .anim => |a| {
                const img = if (a.frames.i < a.first.len) a.first[a.frames.i] else a.imgs[@min(a.frames.i, a.imgs.len - 1)];
                const y = if (a.mushroom) a.y + int(mushroom_shift[@min(a.frames.i, 11)] * a.size) else a.y;
                fx.put(cv, view, img, a.x, y, 0, a.size, a.centered);
            },
            .side_explosion => |x| {
                const at = x.line.at(t);
                fx.put(cv, view, s.side_explosion[@min(x.frames.i, 6)], int(at.x), int(at.y), 0, x.size, false);
            },
            .particle => |p| {
                const at = p.arc.line.at(t);
                fx.put(cv, view, s.unit_particle[p.frames.i], int(at.x), int(at.y - p.arc.lift(t) * 65), 0, 1, false);
            },
            .spark => |p| {
                const at = p.arc.line.at(t);
                const lift = p.arc.lift(t);
                fx.put(cv, view, s.spark[p.frames.i], int(at.x), int(at.y - lift * 30), 0, lift, true);
            },
            .robot_flip => |p| {
                const in_air = t < p.arc.line.t1;
                const at = p.arc.line.at(@min(t, p.arc.line.t1));
                const lift = if (in_air) p.arc.lift(t) else 0;
                fx.put(cv, view, s.robot_flip[@intFromEnum(p.team)][p.frames.i], int(at.x), int(at.y - lift * 30), 0, 1 + lift, true);
            },
            .rock_particle => |p| {
                const at = p.arc.line.at(t);
                const lift = p.arc.lift(t);
                fx.put(cv, view, p.imgs[p.frames.i % p.imgs.len], int(at.x), int(at.y - lift * 150), 0, 1 + lift, true);
            },
            .rock_chunk => |p| {
                const at = p.arc.line.at(t);
                const lift = p.arc.lift(t);
                fx.put(cv, view, p.imgs[p.frames.i], int(at.x), int(at.y - lift * 30), @mod(p.spin * (t - p.arc.line.t0), 360), 1 + lift, true);
            },
            .turret => |p| {
                const at = p.arc.line.at(t);
                const size = p.arc.lift(t) + 1;
                const img = p.piece.image(s, p.team, p.frames.i);
                fx.put(cv, view, img, int(at.x), int(at.y - size * 30 + 30), @mod(p.spin * (t - p.arc.line.t0), 360), size, true);
            },
            .map_object => |p| {
                const at = p.arc.line.at(t);
                const lift = p.arc.lift(t);
                fx.put(cv, view, s.map_object[p.index], int(at.x), int(at.y - lift * 30), @mod(p.spin * (t - p.arc.line.t0), 360), lift + 1, true);
            },
            .wreck => |*w| {
                if (w.img) |img| cv.draw(img, w.x, w.y);
                for (w.fires[0..w.fire_n]) |*f| f.draw(cv, s);
            },
            .track => |tr| for (tr.pos, tr.lay) |p, lay| {
                if (lay) fx.put(cv, view, tr.imgs[tr.i], p[0], p[1], 0, 1, true);
            },
        }
    }
};

/// Where a vehicle's two tracks touch the ground, per direction
/// (ETrack::SetTrackCoords, including its random jiggle).
pub fn trackCoords(cx: i32, cy: i32, direction: u3, rng: std.Random) [2][2]i32 {
    var p: [2][2]i32 = switch (direction) {
        0 => .{ .{ cx - 15, cy - 2 }, .{ cx - 15, cy + 10 } },
        4 => .{ .{ cx + 17, cy - 2 }, .{ cx + 17, cy + 10 } },
        2 => .{ .{ cx - 8, cy + 15 }, .{ cx + 8, cy + 15 } },
        6 => .{ .{ cx - 8, cy - 11 }, .{ cx + 8, cy - 11 } },
        1 => .{ .{ cx - 14, cy + 4 + 3 }, .{ cx - 4, cy + 14 + 3 } },
        5 => .{ .{ cx + 14 - 1, cy - 4 + 4 }, .{ cx + 4 - 1, cy - 14 + 4 } },
        3 => .{ .{ cx + 14 + 1, cy + 4 + 4 }, .{ cx + 4 + 1, cy + 14 + 4 } },
        7 => .{ .{ cx - 14, cy - 4 + 3 }, .{ cx - 4, cy - 14 + 3 } },
    };
    const jx: i32 = @intCast(rng.uintLessThan(u32, 2));
    const jy: i32 = @intCast(rng.uintLessThan(u32, 2));
    for (&p) |*pt| {
        pt[0] += jx;
        pt[1] += jy;
    }
    return p;
}

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
            const x = o.x + box.x + @as(i32, @intCast(rng.uintLessThan(u32, @intCast(box.w))));
            const y = o.y + box.y + @as(i32, @intCast(rng.uintLessThan(u32, @intCast(box.h))));
            f.fires.append(gpa, .random(x, y, rng, time)) catch return;
        }
        std.mem.sort(Fire, f.fires.items, {}, Fire.lessThan);
    }

    pub fn draw(f: *const BuildingFires, cv: Canvas, s: *const sprites.Sprites) void {
        for (f.fires.items) |*fire| fire.draw(cv, &s.fx);
    }
};

/// The part of a building where fires burn and explosions happen.
fn effectsBox(o: *const Object) gfx.Rect {
    return switch (o.kind.building.type) {
        .fort_front, .fort_back => .{ .x = 18, .y = 18, .w = 136, .h = 118 },
        .radar => .{ .x = 1, .y = 6, .w = 44, .h = 30 },
        .repair, .robot_factory, .vehicle_factory => .{ .x = 8, .y = 8, .w = @max(o.width_pix - 24, 1), .h = @max(o.height_pix - 24, 1) },
        .bridge_vert, .bridge_horz => .{ .x = 16, .y = 16, .w = 32, .h = 32 },
    };
}

test "effects run their course" {
    const gpa = std.testing.allocator;
    const palettes = gfx.TeamPalettes.load("bin/assets");
    const all = try sprites.Sprites.load(gpa, "bin/assets", &palettes);
    defer all.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    var fx = Effects.init(gpa, all, &palettes, prng.random());
    defer fx.deinit();

    const io = std.testing.io;
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    const terrain_info = try gpa.create(game.map.Terrain);
    defer gpa.destroy(terrain_info);
    terrain_info.* = try game.map.Terrain.load(io, assets);
    var world = game.world.World.init(gpa, terrain_info, 1);
    defer world.deinit();

    fx.bullet(.red, 0, 0, 100, 0);
    fx.flame(0, 0, 50, 50);
    fx.laser(0, 0, 50, 50);
    fx.rocket(.light, 10, 10, 200, 100, .{ .speed = 300, .large = 1, .xx_large = 1 });
    fx.rocket(.tough, 10, 10, 200, 100, .{ .speed = 150 });
    fx.rocket(.launcher, 10, 10, 200, 100, .{ .speed = 200 });
    fx.rocket(.missile_cannon, 10, 10, 200, 100, .{ .speed = 200 });
    fx.turret(.heavy, .blue, 50, 50, 150, 150, 1.0);
    fx.turret(.fort2, .none, 50, 50, 150, 150, 2.0);
    fx.sideExplosion(100, 100, 1.3);
    fx.robotFlip(.green, 60, 60);
    fx.wreck(.jeep, fx.s.jeep_wasted, 40, 40);

    const screen = Image.create(320, 240).?;
    defer screen.deinit();
    const view: gfx.Rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 };
    const cv: Canvas = .{ .target = screen, .clip = view };

    var time: f64 = 0;
    var most: usize = 0;
    while (time < 20) : (time += 0.05) {
        fx.update(.{ .time = time, .world = &world, .terrain = null });
        fx.draw(cv, view);
        most = @max(most, fx.air.items.len);
    }
    // Things exploded into more things, and all of it is over now.
    try std.testing.expect(most > 12);
    try std.testing.expectEqual(0, fx.air.items.len);
    try std.testing.expect(fx.transforms.map.count() > 0);
}
