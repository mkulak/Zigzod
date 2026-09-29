//! Effects of units firing and of objects being destroyed: muzzle flashes,
//! missiles, wrecks, debris and explosions (part of Effects, see
//! effects.zig).

const std = @import("std");
const game = @import("../../game.zig");
const gfx = @import("../gfx.zig");
const sprites = @import("../sprites.zig");
const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const protocol = @import("../../net/protocol.zig");
const Image = gfx.Image;
const motion = @import("motion.zig");
const effects = @import("../effects.zig");
const Effects = effects.Effects;
const TurretPiece = effects.TurretPiece;
const effectsBox = effects.effectsBox;
const Wreck = effects.Wreck;

/// A random point on `target` (where a bullet hits).
pub fn pointOn(fx: *Effects, target: *const Object) [2]i32 {
    return .{ target.x + fx.rand(@max(target.width_pix, 1)), target.y + fx.rand(@max(target.height_pix, 1)) };
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
                        const p = pointOn(fx, tg);
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
            const imgs: []const Image = if (fire_death) &fx.s.robot_melt[team] else blk: {
                const d: usize = fx.pick(4);
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
                fx.wreck(.tank, img, o.x, o.y);
            },
        },
        .building => |b| switch (b.type) {
            .bridge_vert, .bridge_horz => bridgeDebris(fx, o, false),
            else => buildingExplosion(fx, o, b.type),
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
        fx.sideExplosion(o.x + box.x + fx.rand(box.w), o.y + box.y + fx.rand(box.h), 1.3);
    }
    for (0..pieces + fx.rng.uintLessThan(u32, pieces_spread)) |_| {
        const sx = o.x + box.x + fx.rand(box.w);
        const sy = o.y + box.y + fx.rand(box.h);
        const ex = o.x + (o.width_pix >> 1) + fx.around(200);
        const ey = o.y + (o.height_pix >> 1) + fx.around(200);
        const offset = flight + 0.01 * @as(f64, @floatFromInt(fx.rand(200)));
        const piece: TurretPiece = if (is_fort)
            @enumFromInt(@intFromEnum(TurretPiece.fort0) + @as(u8, @intCast(fx.pick(5))))
        else if (fx.rand(2) == 0) .building0 else .building1;
        fx.turret(piece, .none, sx, sy, ex, ey, offset);
    }
}

/// Units near a blast throw off particles (ZPlayer::MissileObjectParticles).
pub fn unitParticles(fx: *Effects, world: *const World, x: i32, y: i32, radius0: i32, amount: u32) void {
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
        for (0..n) |_| fx.particle(o.x + fx.rand(@max(o.width_pix, 1)), o.y + fx.rand(@max(o.height_pix, 1)), 25, 25);
    }
}
