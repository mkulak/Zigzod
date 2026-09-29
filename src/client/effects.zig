//! Visual effects: shots, rockets, explosions, debris, wrecks, fires and
//! tank tracks (QZod_DnEffect). They only decorate; the server decides
//! what actually happens.
//!
//! Effects live in two lists: ground effects (tracks, dust, oil) are drawn
//! under the objects, the rest over them. Effects may spawn more effects,
//! leave craters and throw particles off nearby units.
//!
//! Effects are only decoration, so they never fail: an effect (or its
//! sound, or a rotated image) that can't get memory is left out, which is
//! why the adding functions below ignore allocation errors.

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const sprites = @import("sprites.zig");
const Terrain = @import("terrain.zig").Terrain;
const SoundEffect = @import("sound.zig").Effect;

const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const protocol = @import("../net/protocol.zig");
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Fx = sprites.EffectSprites;

const motion = @import("effects/motion.zig");
const Point = motion.Point;
const Line = motion.Line;
const Arc = motion.Arc;
const Frames = motion.Frames;
const int = motion.int;
const angleOf = motion.angleOf;
pub const Transforms = @import("effects/transforms.zig").Transforms;
const fires = @import("effects/fires.zig");
pub const FireKind = fires.FireKind;
pub const Fire = fires.Fire;
pub const BuildingFires = fires.BuildingFires;
pub const effectsBox = fires.effectsBox;
const deaths = @import("effects/deaths.zig");
const update_mod = @import("effects/update.zig");
const draw_mod = @import("effects/draw.zig");

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

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

    pub fn frames(p: TurretPiece) u8 {
        return switch (p) {
            .light, .medium, .heavy => 8,
            .building0, .building1, .fort0, .fort1, .fort2, .fort3, .fort4 => 12,
            .grenade => 4,
            else => 1,
        };
    }

    pub fn image(p: TurretPiece, s: *const Fx, team: k.Team, i: u8) Image {
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

    pub fn ofCannon(kind: k.Cannon) TurretPiece {
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

pub const Rocket = struct {
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

pub const Effect = union(enum) {
    bullet: struct { team: k.Team, line: Line },
    /// Lasers and pyro flames.
    beam: struct { flame: bool, line: Line, img: usize, angle: f64 },
    rocket: Rocket,
    /// A fixed animation that plays once (fire bursts, mushrooms, smoke,
    /// robots dying, tank dust).
    anim: Anim,
    side_explosion: struct { line: Line, size: f64, frames: Frames },
    /// Bits flying off units and map objects.
    particle: struct { arc: Arc, frames: Frames },
    spark: struct { arc: Arc, frames: Frames },
    robot_flip: struct { team: k.Team, arc: Arc, frames: Frames },
    rock_particle: struct { arc: Arc, frames: Frames, imgs: []const Image },
    /// Big rock or bridge pieces; `reversed` flies back in (a bridge
    /// being rebuilt).
    rock_chunk: struct { arc: Arc, frames: Frames, imgs: *const [12]Image, planet: k.Planet, spin: f64, reversed: bool },
    turret: struct { piece: TurretPiece, team: k.Team, arc: Arc, frames: Frames, spin: f64 },
    map_object: struct { index: u8, arc: Arc, spin: f64, dest: Point },
    /// A destroyed unit burning for a while before blowing apart.
    wreck: Wreck,
    track: struct { imgs: *const [3]Image, pos: [2][2]i32, lay: [2]bool, start: f64, i: u8 },
};

const Anim = struct {
    imgs: []const Image,
    /// Shown instead of `imgs` for the first frames (tank sparks).
    first: []const Image = &.{},
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

pub const Wreck = struct {
    img: Image,
    x: i32,
    y: i32,
    until: f64,
    /// Up to 5 little fires, 2 big smokes and a fire with smoke.
    fires: [8]Fire = undefined,
    fire_n: u8 = 0,
    /// Cannons throw their gun when the wreck blows.
    gun: ?struct { piece: TurretPiece, to: Point, offset: f64 } = null,
};

pub const mushroom_shift = [12]f64{ 14, 9, 2, 0, 0, 0, 1, 2, 3, 4, 5, 6 };

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
    prng: std.Random.DefaultPrng,
    /// Draws from `prng` (which is why effects live on the heap).
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

    pub fn create(gpa: std.mem.Allocator, s: *const sprites.Sprites, palettes: *const gfx.TeamPalettes, seed: u64) std.mem.Allocator.Error!*Effects {
        const fx = try gpa.create(Effects);
        fx.* = .{ .gpa = gpa, .s = &s.fx, .palettes = palettes, .prng = .init(seed), .rng = undefined, .transforms = .{ .gpa = gpa } };
        fx.rng = fx.prng.random();
        return fx;
    }

    pub fn destroy(fx: *Effects) void {
        const gpa = fx.gpa;
        fx.transforms.deinit();
        fx.ground.deinit(gpa);
        fx.air.deinit(gpa);
        fx.spawned.deinit(gpa);
        fx.sounds.deinit(gpa);
        gpa.destroy(fx);
    }

    pub const Heard = struct { sound: SoundEffect, where: gfx.Rect };

    /// A sound from the area `where` (map coordinates).
    pub fn sound(fx: *Effects, e: SoundEffect, where: gfx.Rect) void {
        fx.sounds.append(fx.gpa, .{ .sound = e, .where = where }) catch {};
    }

    // The helpers and spawning functions below are also used by the files
    // in effects/, which is why some are pub that only matter here.

    pub fn soundAt(fx: *Effects, e: SoundEffect, x: i32, y: i32) void {
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

    /// 0 to n - 1.
    pub fn rand(fx: *Effects, n: i32) i32 {
        return fx.rng.intRangeLessThan(i32, 0, n);
    }

    /// One of n things (an index).
    pub fn pick(fx: *Effects, n: usize) usize {
        return fx.rng.uintLessThan(usize, n);
    }

    /// `min` plus up to `spread - 1` more.
    pub fn count(fx: *Effects, min: usize, spread: usize) usize {
        return min + fx.rng.uintLessThan(usize, spread);
    }

    /// `base + (spread - rand(2 * spread))`: a random offset within ±spread.
    pub fn around(fx: *Effects, spread: i32) i32 {
        return spread - fx.rand(2 * spread);
    }

    fn add(fx: *Effects, e: Effect) void {
        fx.spawned.append(fx.gpa, e) catch {};
    }

    /// Wrecks and dying robots go under the other effects.
    pub fn addUnder(fx: *Effects, e: Effect) void {
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
        const first = img;
        const from: Point = .of(from_x - (first.width() >> 1), from_y - (first.height() >> 1));
        var line: Line = .init(.of(from_x, from_y), .of(to_x, to_y), 300, fx.time);
        const angle = line.imageAngle();
        line.start = from;
        fx.add(.{ .beam = .{ .flame = is_flame, .line = line, .img = fx.pick(if (is_flame) 4 else 2), .angle = angle } });
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
                fx.anim(.{ .imgs = fx.s.light_init_fire[fx.pick(4)..][0..1], .x = from_x - 8, .y = from_y - 7, .frames = .init(fx.time, 0.02) });
                offset = .of(-(fx.s.light_bullet.width() >> 1), -(fx.s.light_bullet.height() >> 1));
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

    pub fn mushroom(fx: *Effects, x: i32, y: i32, size: f64) void {
        fx.anim(.{
            .imgs = &fx.s.mushroom,
            .x = x - int(16 * size),
            .y = y - int(32 * size),
            .size = size,
            .mushroom = true,
            .frames = .init(fx.time, 0.08),
        });
    }

    pub fn toughSmoke(fx: *Effects, x: i32, y: i32) void {
        fx.anim(.{ .imgs = &fx.s.tough_smoke, .x = x, .y = y, .centered = true, .frames = .init(fx.time, 0.12) });
    }

    pub fn pyroFire(fx: *Effects, x: i32, y: i32) void {
        const kind: usize = fx.pick(5);
        const n: usize = if (kind < 3) 4 else 6;
        const first = fx.s.pyro_fire[kind][0];
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
    pub fn particle(fx: *Effects, x0: i32, y0: i32, horz: i32, vert: i32) void {
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

    pub fn sparks(fx: *Effects, x: i32, y: i32, min: u32, spread: u32) void {
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

    pub fn rockParticle(fx: *Effects, x0: i32, y0: i32, mid: bool, horz: i32, vert: i32) void {
        const p = @intFromEnum(fx.planet);
        const imgs: []const Image = if (!mid) &fx.s.rock_small[p] else &fx.s.rock_mid[fx.pick(2)][p];
        const lifetime = 1.1 + 0.1 * @as(f64, @floatFromInt(fx.rand(10)));
        const x = x0 + fx.rand(8);
        const y = y0 + fx.rand(24);
        const to: Point = .of(x + fx.around(horz), y + fx.around(vert));
        const rise = 1.1 + 0.01 * @as(f64, @floatFromInt(fx.rand(30)));
        fx.add(.{ .rock_particle = .{ .arc = .init(.of(x - 8, y - 5), to, lifetime, rise, fx.time), .frames = .init(fx.time, 0.07), .imgs = imgs } });
    }

    pub fn rockChunk(fx: *Effects, x0: i32, y0: i32, bridge: bool, reversed: bool) void {
        const p = @intFromEnum(fx.planet);
        const imgs = if (bridge)
            &fx.s.bridge_debris[p]
        else switch (fx.planet) {
            .city, .desert => &fx.s.rock_large[0][p],
            else => &fx.s.rock_large[fx.pick(2)][p],
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

    pub fn mapObjectPiece(fx: *Effects, index: u8, from_x: i32, from_y: i32, to_x: i32, to_y: i32, offset: f64) void {
        const i = @min(index, sprites.map_objects - 1);
        const rise = 0.5 + 0.01 * @as(f64, @floatFromInt(fx.rand(100)));
        const my: i32 = 16 - fx.s.map_object[i].height();
        const from: Point = .of(from_x + 5 - fx.rand(10), from_y + 5 - fx.rand(10) + my);
        var spin: f64 = @floatFromInt(240 - fx.rand(480));
        spin += if (spin >= 0) 100 else -100;
        fx.add(.{ .map_object = .{ .index = i, .arc = .init(from, .of(to_x, to_y + my), offset, rise, fx.time), .spin = spin, .dest = .of(to_x, to_y) } });
    }

    const WreckKind = enum { jeep, launcher, apc, crane, tank };

    pub fn wreck(fx: *Effects, kind: WreckKind, img: Image, x: i32, y: i32) void {
        var w: Wreck = .{ .img = img, .x = x, .y = y, .until = fx.time + 5 + @as(f64, @floatFromInt(fx.rand(3))) };
        // Where fires burn on the wreck.
        const bx: i32, const by: i32, const bw: i32, const bh: i32 = switch (kind) {
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
            fx.addGround(.{ .track = .{ .imgs = imgs, .pos = pos, .lay = lay, .start = fx.time + 0.1 * @as(f64, @floatFromInt(fx.rand(10))), .i = 0 } });
            for (lay, pos) |l, pt| {
                if (!l or fx.rand(4) == 0) continue;
                const dirts: u32 = switch (fx.planet) {
                    .jungle => 1,
                    .city => 0,
                    else => 2,
                };
                if (dirts == 0) continue;
                const d: usize = fx.pick(dirts);
                const first = fx.s.tank_dirt[p][d][0];
                const n: usize = if (fx.planet == .jungle) 6 else 5;
                fx.addGround(.{ .anim = .{ .imgs = fx.s.tank_dirt[p][d][0..n], .x = pt[0] - (first.width() >> 1), .y = pt[1] - first.height(), .frames = .init(fx.time, 0.15) } });
            }
        }
        if (o.showPartiallyDamaged() and fx.rand(3) == 0) fx.tankSmoke(cx, cy, direction, false);
        if (o.showDamaged()) {
            if (fx.rand(3) == 0) fx.tankSmoke(cx, cy, direction, true);
            if (fx.rand(16) == 0) {
                const at = fx.oilCoords(cx, cy, direction, 5, 3, 7);
                fx.addGround(.{ .anim = .{ .imgs = &fx.s.tank_oil[fx.pick(3)], .x = at[0], .y = at[1], .centered = true, .frames = .init(fx.time, 3.0 + 0.1 * @as(f64, @floatFromInt(fx.rand(10)))), .jitter = 1.0 } });
            }
            if (fx.rand(48) == 0) {
                const at = fx.oilCoords(cx, cy, direction, 3, 5, 11);
                const loops: u16 = @intCast(36 + fx.rand(25));
                fx.addGround(.{ .anim = .{ .imgs = &fx.s.ground_spark, .x = at[0], .y = at[1], .centered = true, .frames = .init(fx.time, 0.1), .loops = loops } });
            }
        }
    }

    /// Where a damaged tank drips oil or scrapes sparks.
    fn oilCoords(fx: *Effects, cx0: i32, cy0: i32, direction: u3, down: i32, back: i32, spread: i32) [2]i32 {
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
        const first = imgs[0];
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

    // Units firing and dying (effects/deaths.zig)
    pub const pointOn = deaths.pointOn;
    pub const fireMissile = deaths.fireMissile;
    pub const robotMuzzle = deaths.robotMuzzle;
    pub const destroyed = deaths.destroyed;
    pub const bridgeDebris = deaths.bridgeDebris;
    pub const unitParticles = deaths.unitParticles;

    // Updating (effects/update.zig)
    pub const update = update_mod.update;

    // Drawing (effects/draw.zig)
    pub const drawGround = draw_mod.drawGround;
    pub const draw = draw_mod.draw;
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
    const jx = rng.intRangeLessThan(i32, 0, 2);
    const jy = rng.intRangeLessThan(i32, 0, 2);
    for (&p) |*pt| {
        pt[0] += jx;
        pt[1] += jy;
    }
    return p;
}

test "effects run their course" {
    const gpa = std.testing.allocator;
    const a = try @import("assets.zig").Assets.init(gpa, "bin/assets");
    defer a.deinit();
    const all = try sprites.Sprites.load(a);
    const fx = try Effects.create(gpa, all, &a.palettes, 1);
    defer fx.destroy();

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

    const screen = try Image.create(gpa, 320, 240);
    defer screen.deinit(gpa);
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
