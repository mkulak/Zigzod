//! Unit animations and drawing: cannons, vehicles and robots (the client
//! side of ZCannon, ZVehicle, ZRobot and their subclasses).

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const Sprites = @import("sprites.zig").Sprites;
const Effects = @import("effects.zig").Effects;

const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const Canvas = gfx.Canvas;
const Image = gfx.Image;

pub const vehicle_move_anim_speed = 0.1;

/// Direction of travel from a velocity: 0 east, counting counterclockwise
/// in 45 degree steps (screen y points down). Null when not moving.
pub fn directionFrom(dx: f64, dy: f64) ?u3 {
    if (game.object.isZero(dx) and game.object.isZero(dy)) return null;
    var a = std.math.atan2(dy, dx);
    if (a < 0) a += 2 * std.math.pi;
    a += std.math.pi / 8.0;
    const step = std.math.pi / 4.0;
    // Angles grow clockwise on screen; directions counterclockwise.
    const i: u32 = @intFromFloat(@floor(a / step));
    return @intCast((8 - (i % 8)) % 8);
}

pub const RobotMode = enum {
    standing,
    walking,
    attacking,
    cigarette,
    beer,
    full_scan,
    head_stretch,
    pickup_up,
    pickup_down,
};

pub const UnitVisual = struct {
    direction: u3 = 0,
    /// Turret direction.
    turret: u3 = 0,
    moving: bool = false,
    move_i: u8 = 0,
    next_move_time: f64 = 0,
    next_turret_time: f64 = 0,
    next_attack_time: f64 = 0,
    last_process_time: f64 = 0,

    /// What the unit was last seen doing (to notice changes).
    seen_dx: f32 = 0,
    seen_dy: f32 = 0,
    seen_target: ?i32 = null,

    /// Flash white for a frame when hit (the driver when sniped).
    hit: bool = false,
    driver_hit: bool = false,

    // Cannons.
    just_placed: bool = false,
    place_i: u8 = 0,
    /// Gatling guns and jeeps alternate frames while shooting; howitzers
    /// and missile cannons show a flash after firing.
    firing: bool = false,
    fire_until: f64 = 0,

    // Vehicles.
    lid_i: u8 = 0,
    show_robot: bool = false,
    next_lid_time: f64 = 0,
    jeep_bounce: bool = false,
    next_bounce_time: f64 = 0,
    crane_anim: bool = false,
    hook_i: u8 = 0,
    next_hook_time: f64 = 0,
    /// Tracks and dust are left behind every 0.2 s.
    next_track_time: f64 = 0,
    /// APCs: when each passenger shoots next.
    passenger_shots: [8]f64 = @splat(0),

    // Robots.
    mode: RobotMode = .standing,
    action_i: u8 = 0,
    throwing: bool = false,
    grenade_i: u8 = 0,
    next_grenade_time: f64 = 0,
    next_process_time: f64 = 0,
};

/// A new unit's starting look.
pub fn init(o: *const Object, v: *UnitVisual, rng: std.Random, our_team: k.Team, time: f64) void {
    switch (o.kind) {
        .vehicle => {
            v.direction = rng.int(u3);
            v.turret = v.direction;
            v.move_i = rng.uintLessThan(u8, 3);
            v.next_turret_time = time + 1;
        },
        .robot => {
            v.direction = 6;
            v.next_process_time = time + 0.3;
        },
        .cannon => v.just_placed = o.owner == our_team,
        else => {},
    }
}

fn speedFactor(o: *const Object) f64 {
    if (o.move_speed == 0 or !o.isMoving()) return 1.0;
    const speed = @sqrt(o.dx * o.dx + o.dy * o.dy);
    return @as(f64, @floatFromInt(o.move_speed)) / speed;
}

fn directionTo(o: *const Object, target: *const Object) ?u3 {
    return directionFrom(@floatFromInt(target.center_x - o.x), @floatFromInt(target.center_y - o.y));
}

pub const Update = struct {
    world: *const World,
    time: f64,
    rng: std.Random,
    fx: *Effects,
};

/// Advance a unit's animations.
pub fn update(o: *const Object, v: *UnitVisual, u: Update) void {
    const t = u.time;
    const target = u.world.findOpt(o.attack_target);

    // A new velocity: turn that way (RecalcDirection).
    if (o.dx != v.seen_dx or o.dy != v.seen_dy) {
        v.seen_dx = o.dx;
        v.seen_dy = o.dy;
        if (directionFrom(o.dx, o.dy)) |d| {
            if (o.kind == .robot and v.mode != .walking) v.move_i = 0;
            v.direction = d;
            v.moving = true;
            if (o.kind == .vehicle) v.move_i = 0;
            if (o.kind == .robot) v.mode = .walking;
        } else {
            v.moving = false;
            if (o.kind == .robot) v.mode = .standing;
        }
    }
    // A new attack target (SetAttackObject).
    if (o.attack_target != v.seen_target) {
        v.seen_target = o.attack_target;
        switch (o.kind) {
            .robot => if (target != null) {
                v.mode = .attacking;
                v.action_i = 0;
                v.next_attack_time = t + 0.1;
            } else if (v.mode != .walking and v.mode != .standing) {
                v.mode = .standing;
            },
            .cannon => if (target) |tg| {
                if (directionTo(o, tg)) |d| v.direction = d;
            } else {
                v.firing = false;
            },
            .vehicle => |veh| if (target) |tg| {
                if (veh.type != .jeep) if (directionTo(o, tg)) |d| {
                    v.turret = d;
                };
            } else {
                v.firing = false;
            },
            else => {},
        }
    }

    switch (o.kind) {
        .cannon => |cn| updateCannon(o, cn.type, v, target, u),
        .vehicle => |veh| updateVehicle(o, veh.type, veh.lid_open, v, target, u),
        .robot => |rb| updateRobot(o, rb, v, target, u),
        else => {},
    }
}

fn updateCannon(o: *const Object, kind: k.Cannon, v: *UnitVisual, target: ?*Object, u: Update) void {
    const t = u.time;
    if (v.firing and kind != .gatling and t >= v.fire_until) v.firing = false;
    if (v.just_placed) {
        if (t - v.last_process_time < 0.1) return;
        v.last_process_time = t;
        v.place_i += 1;
        if (v.place_i >= 7) {
            v.place_i = 0;
            v.just_placed = false;
        }
        return;
    }
    if (kind == .gatling) if (target) |tg| {
        // Rattle: alternate frames while shooting, a bullet every other.
        if (t < v.next_attack_time) return;
        v.firing = !v.firing;
        v.next_attack_time = t + 0.07 + @as(f64, @floatFromInt(u.rng.uintLessThan(u32, 100))) * 0.0003;
        if (directionTo(o, tg)) |d| v.direction = d;
        if (v.firing) {
            const bullet_x = [8]i32{ 18, 13, 0, -13, -18, -16, -1, 13 };
            const bullet_y = [8]i32{ -3, -16, -18, -16, -3, 10, 13, 10 };
            const p = u.fx.pointOn(tg);
            u.fx.bullet(o.owner, o.center_x + bullet_x[v.direction], o.center_y - 7 + bullet_y[v.direction], p[0], p[1]);
            u.fx.soundOf(.gatling_fire, o);
        }
        return;
    };
    if (t - v.last_process_time < 1.0 or o.owner == .none) return;
    v.last_process_time = t;
    if (target) |tg| {
        if (kind != .gatling) if (directionTo(o, tg)) |d| {
            v.direction = d;
        };
    } else v.direction +%= 1;
}

fn updateVehicle(o: *const Object, kind: k.Vehicle, lid_open: bool, v: *UnitVisual, target: ?*Object, u: Update) void {
    const t = u.time;
    switch (kind) {
        .light, .medium, .heavy => {
            // The hatch opens (showing the driver) and closes.
            if (t >= v.next_lid_time) {
                v.next_lid_time = t + 0.2;
                if (lid_open) {
                    if (v.lid_i >= 2) v.show_robot = true else v.lid_i += 1;
                } else {
                    v.show_robot = false;
                    if (v.lid_i > 0) v.lid_i -= 1;
                }
            }
        },
        else => {},
    }

    if (v.moving and t >= v.next_track_time) {
        v.next_track_time = t + 0.2;
        if (u.world.map) |*m| u.fx.vehicleTrail(o, v.direction, m, u.world.terrain);
    }

    // Tracks and wheels.
    if (v.moving and t >= v.next_move_time) {
        switch (kind) {
            .light, .medium, .heavy => v.move_i = if (v.move_i == 0) 2 else v.move_i - 1,
            .jeep => v.move_i = (v.move_i + 1) % 4,
            else => v.move_i = (v.move_i + 1) % 3,
        }
        v.next_move_time = t + vehicle_move_anim_speed * speedFactor(o);
    }

    switch (kind) {
        .jeep => {
            if (t >= v.next_bounce_time) {
                v.next_bounce_time = t + 0.25 * speedFactor(o);
                v.jeep_bounce = !v.jeep_bounce;
            }
            if (target) |tg| {
                if (t >= v.next_attack_time) {
                    v.firing = !v.firing;
                    v.next_attack_time = t + 0.07 + @as(f64, @floatFromInt(u.rng.uintLessThan(u32, 100))) * 0.0003;
                    if (directionTo(o, tg)) |d| v.turret = d;
                    if (v.firing) {
                        // From the gun on the bouncing jeep.
                        const turret_x = [8]i32{ 0, 6, 12, 20, 25, 20, 15, 5 };
                        const turret_y = [8]i32{ 2, 7, 4, 8, 2, -4, -3, -4 };
                        const shift_x = [8]i32{ 0, -2, -5, -8, -10, -8, -5, -2 };
                        const shift_y = [8]i32{ 0, 0, 0, 0, 0, 5, 6, 5 };
                        const bullet_x = [8]i32{ 17, 14, 7, 0, -3, -3, 7, 15 };
                        const bullet_y = [8]i32{ 10, 1, -2, 0, 10, 16, 17, 15 };
                        const x = o.x + turret_x[v.direction] + shift_x[v.turret] + bullet_x[v.turret];
                        const y = o.y + turret_y[v.direction] + shift_y[v.turret] + bullet_y[v.turret] - @intFromBool(v.jeep_bounce);
                        const p = u.fx.pointOn(tg);
                        u.fx.bullet(o.owner, x, y, p[0], p[1]);
                        u.fx.soundOf(.jeep_fire, o);
                    }
                }
            } else if (t >= v.next_turret_time) {
                v.next_turret_time = t + 1.0;
                v.turret +%= 1;
            }
        },
        .apc, .crane => {
            if (t >= v.next_turret_time) {
                v.next_turret_time = t + 1.0;
                v.turret +%= 1;
            }
            // Passengers shoot out of the APC (toughs fire rockets, which
            // the server announces).
            if (target) |tg| if (kind == .apc and !o.damage_is_missile) {
                const n = @min(o.drivers.items.len, v.passenger_shots.len);
                for (v.passenger_shots[0..n]) |*next| {
                    if (t < next.*) continue;
                    next.* = t + o.damage_interval + 0.012 * @as(f64, @floatFromInt(u.rng.uintLessThan(u32, 10)));
                    const p = u.fx.pointOn(tg);
                    switch (o.driver_type) {
                        .grunt, .psycho, .sniper => {
                            u.fx.bullet(o.owner, o.x + 16, o.y + 16, p[0], p[1]);
                            u.fx.soundOf(.rifle_fire, o);
                        },
                        .pyro => {
                            u.fx.flame(o.x + 16, o.y + 16, p[0], p[1]);
                            u.fx.soundOf(.pyro_fire, o);
                        },
                        .laser => {
                            u.fx.laser(o.x + 16, o.y + 16, p[0], p[1]);
                            u.fx.soundOf(.laser_fire, o);
                        },
                        .tough => {},
                    }
                }
            };
            if (kind == .crane and v.crane_anim and t >= v.next_hook_time) {
                v.next_hook_time = t + 0.01;
                v.hook_i = (v.hook_i + 1) % 16;
            }
        },
        else => if (t >= v.next_turret_time) {
            if (target) |tg| {
                if (directionTo(o, tg)) |d| v.turret = d;
            } else {
                v.next_turret_time = t + 1.0;
                v.turret +%= 1;
            }
        },
    }
}

fn fireFrames(r: k.Robot) u8 {
    return switch (r) {
        .grunt, .sniper => 5,
        .psycho => 2,
        else => 3,
    };
}

fn throwsGrenades(o: *const Object, world: *const World, target: ?*Object) bool {
    if (o.grenades > 0) return true;
    if (world.findOpt(o.leader)) |l| if (l.grenades > 0) return true;
    if (target) |tg| return tg.attacked_by_explosives;
    return false;
}

fn updateRobot(o: *const Object, kind: k.Robot, v: *UnitVisual, target: ?*Object, u: Update) void {
    const t = u.time;
    const rng = u.rng;
    if (v.throwing and t >= v.next_grenade_time) {
        v.next_grenade_time = t + 0.15;
        v.grenade_i += 1;
        if (v.grenade_i >= 4) {
            v.grenade_i = 0;
            v.throwing = false;
        }
    }

    // Idle antics, walking, facing the target.
    if (t >= v.next_process_time) {
        switch (v.mode) {
            .walking => v.move_i = (v.move_i + 1) % 4,
            .standing => if (rng.uintLessThan(u32, 10) == 0) {
                if (rng.uintLessThan(u32, 3) != 0) {
                    v.direction = rng.int(u3);
                } else {
                    v.action_i = 0;
                    v.direction = 6;
                    v.mode = switch (rng.uintLessThan(u32, 4)) {
                        0 => .cigarette,
                        1 => .beer,
                        2 => .full_scan,
                        else => .head_stretch,
                    };
                }
            },
            .cigarette, .head_stretch, .beer, .full_scan, .pickup_up, .pickup_down => {
                v.action_i += 1;
                const frames: u8 = switch (v.mode) {
                    .cigarette, .head_stretch => 11,
                    .beer => 10,
                    .full_scan => 12,
                    else => 4,
                };
                if (v.action_i >= frames) {
                    v.mode = .standing;
                    v.action_i = 0;
                }
            },
            .attacking => if (target) |tg| {
                if (directionTo(o, tg)) |d| v.direction = d;
            },
        }
        v.next_process_time = t + 0.3 * speedFactor(o);
    }

    if (v.mode != .attacking or t < v.next_attack_time) return;
    if (kind != .tough and throwsGrenades(o, u.world, target)) return;
    const jitter = @as(f64, @floatFromInt(rng.uintLessThan(u32, 100)));
    defer if (target) |tg| {
        // The frame where the gun goes off.
        const shoots = switch (kind) {
            .grunt, .sniper => v.action_i == 4,
            .psycho => v.action_i != 0,
            .pyro, .laser => v.action_i == 2,
            .tough => false,
        };
        if (shoots) {
            const p = u.fx.pointOn(tg);
            const m = Effects.robotMuzzle(v.direction);
            switch (kind) {
                .pyro => u.fx.flame(o.x + 8 + m[0], o.y + 8 + m[1], p[0], p[1]),
                .laser => u.fx.laser(o.x + 8 + m[0], o.y + 8 + m[1], p[0], p[1]),
                else => u.fx.bullet(o.owner, o.x + 8, o.y + 8, p[0], p[1]),
            }
            u.fx.soundOf(switch (kind) {
                .pyro => .pyro_fire,
                .laser => .laser_fire,
                .psycho => .psycho_fire,
                else => .rifle_fire,
            }, o);
        }
    };
    switch (kind) {
        .grunt, .sniper => {
            v.action_i += 1;
            if (v.action_i >= 5) v.action_i = 3;
            v.next_attack_time = if (v.action_i >= 3)
                (if (kind == .grunt) t + 0.40 + jitter * 0.002 else t + 0.30 + jitter * 0.0018)
            else
                t + 0.02;
        },
        .psycho => {
            v.action_i = (v.action_i + 1) % 2;
            v.next_attack_time = t + 0.07 + jitter * 0.0003;
        },
        .pyro, .laser => {
            v.action_i = (v.action_i + 1) % 3;
            v.next_attack_time = if (v.action_i == 0)
                (if (kind == .pyro) t + 0.07 + jitter * 0.0003 else t + 0.30 + jitter * 0.002)
            else
                t + 0.05 + jitter * 0.0003;
        },
        .tough => if (v.action_i != 0) {
            // Started by firing a rocket.
            v.action_i = (v.action_i + 1) % 3;
            v.next_attack_time = if (v.action_i == 0) t + 0.7 + jitter * 0.003 else t + 0.05 + jitter * 0.0003;
        },
    }
}

/// The server says the unit fired a missile at (x, y).
pub fn fireMissile(o: *const Object, v: *UnitVisual, x: i32, y: i32, u: Update) void {
    const time = u.time;
    const jitter = @as(f64, @floatFromInt(u.rng.uintLessThan(u32, 100)));
    const target = u.world.findOpt(o.attack_target);
    // Toughs fire rockets (only while attacking); other robots throw
    // grenades.
    const tough = o.kind == .robot and o.kind.robot == .tough;
    if (tough and v.mode != .attacking) return;
    u.fx.fireMissile(o, x, y, v.direction, v.turret, target, tough);
    switch (o.kind) {
        .cannon => |cn| if (cn.type == .howitzer or cn.type == .missile_cannon) {
            v.firing = true;
            v.fire_until = time + 0.05 + jitter * 0.0003;
        },
        .robot => {
            if (tough) {
                v.action_i = 1;
                v.next_attack_time = time + 0.05 + jitter * 0.0003;
            } else {
                v.throwing = true;
                v.grenade_i = 0;
                v.next_grenade_time = time + 0.15;
            }
        },
        else => {},
    }
}

pub fn pickupGrenades(v: *UnitVisual) void {
    if (v.mode == .attacking) return;
    v.mode = if (v.direction < 4) .pickup_up else .pickup_down;
    v.action_i = 0;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn put(cv: Canvas, img: Image, x: i32, y: i32, hit: bool) void {
    if (hit) cv.drawHit(img, x, y) else cv.draw(img, x, y);
}

pub fn draw(cv: Canvas, s: *const Sprites, o: *const Object, v: *UnitVisual, world: *const World, submerge: i32) void {
    defer {
        v.hit = false;
        v.driver_hit = false;
    }
    const owner = @intFromEnum(o.owner);
    switch (o.kind) {
        .cannon => |cn| {
            const cs = &s.cannon[@intFromEnum(cn.type)];
            const d = v.direction;
            const img = if (o.isDestroyed())
                cs.wasted[owner]
            else if (v.just_placed)
                (if (v.place_i < 3) s.init_place[v.place_i] else cs.place[owner][v.place_i - 3])
            else if (v.firing) cs.fire[owner][d] else cs.passive[owner][d];
            const off: [2]i32 = switch (cn.type) {
                .gatling => .{ ([8]i32{ 1, 0, 0, 0, -1, 0, 0, 0 })[d], -7 },
                .gun => .{ 0, 0 },
                .howitzer => .{ -2 + ([8]i32{ 5, 2, 2, 2, 0, 2, 2, 2 })[d], -12 + ([8]i32{ 0, 0, 0, 0, 0, 3, 3, 3 })[d] },
                .missile_cannon => .{ 0, -8 },
            };
            put(cv, img, o.x + off[0], o.y + off[1], v.hit);
        },
        .vehicle => |veh| drawVehicle(cv, s, o, veh.type, v),
        .robot => |rb| {
            const r = &s.robot;
            const d = v.direction;
            const img: Image = if (o.owner == .none) r.null_img else switch (v.mode) {
                .walking => r.walk[owner][d][v.move_i % 4],
                .standing => r.stand[owner][d],
                .beer => r.beer[owner][@min(v.action_i, 9)],
                .cigarette => r.cigarette[owner][@min(v.action_i, 10)],
                .full_scan => r.full_area_scan[owner][@min(v.action_i, 11)],
                .head_stretch => r.head_stretch[owner][@min(v.action_i, 10)],
                .pickup_up => r.pickup_up[owner][@min(v.action_i, 3)],
                .pickup_down => r.pickup_down[owner][@min(v.action_i, 3)],
                .attacking => if (v.throwing or (rb != .tough and throwsGrenades(o, world, world.findOpt(o.attack_target))))
                    r.throw[owner][d][v.grenade_i % 4]
                else
                    r.fire[@intFromEnum(rb)][owner][d][@min(v.action_i, fireFrames(rb) - 1)],
            };
            const i = img;
            // Robots sink into water.
            const part: gfx.Rect = .{ .x = 0, .y = 0, .w = i.width(), .h = @max(i.height() - submerge, 0) };
            if (v.hit) cv.drawHit(i, o.x, o.y + submerge) else cv.drawPart(i, part, o.x, o.y + submerge);
        },
        else => {},
    }
}

fn drawVehicle(cv: Canvas, s: *const Sprites, o: *const Object, kind: k.Vehicle, v: *UnitVisual) void {
    const vs = &s.vehicle[@intFromEnum(kind)];
    const owner = @intFromEnum(o.owner);
    const d = v.direction;
    const td = v.turret;
    const f = v.move_i;
    const x = o.x;
    const y = o.y;
    const hit = v.hit;
    const manned = o.owner != .none;
    switch (kind) {
        .light, .medium, .heavy => {
            if (o.isDestroyed()) return put(cv, vs.damaged[owner][d][f % 3], x, y, false);
            const damaged = o.showDamaged();
            const body = if (damaged) vs.damaged[owner][d][f % 3] else vs.base[owner][d][f % 3];
            switch (kind) {
                .light => {
                    var sx: i32 = 0;
                    var sy: i32 = 0;
                    if (damaged) switch (d) {
                        2, 6 => {
                            sx = 1;
                            sy = 3;
                        },
                        1, 5 => sx = 2,
                        else => {},
                    };
                    put(cv, body, x + sx, y + sy, hit);
                    if (!manned) return;
                    const tx = x + ([8]i32{ 2, 0, -2, 0, 2, 0, -2, 0 })[d];
                    put(cv, vs.top[owner][td], tx + ([8]i32{ 0, 0, 0, -1, 0, 0, 0, 1 })[td], y + ([8]i32{ -2, -2, -1, 0, 0, 0, 1, -2 })[td], hit);
                    drawLid(cv, s, o, v, tx + ([8]i32{ 11, 11, 12, 12, 12, 12, 12, 11 })[td], y + ([8]i32{ 3, 4, 5, 4, 3, 3, 4, 3 })[td]);
                },
                .medium => {
                    const uy = ([8]i32{ 6, 0, 5, 0, 6, 0, 5, 0 })[d];
                    put(cv, body, x, y + uy, hit);
                    if (!manned) return;
                    const tx = x + ([8]i32{ 0, 0, -1, -2, 0, 0, -1, -2 })[d];
                    const ty = y + uy + ([8]i32{ 0, 6, 0, 6, 0, 6, 0, 6 })[d];
                    put(cv, vs.top[owner][td], tx + ([8]i32{ 4, 5, 7, 5, 2, 6, 7, 5 })[td], ty + ([8]i32{ -5, -3, -4, -5, -5, -5, -5, -5 })[td], hit);
                    drawLid(cv, s, o, v, tx + 12, ty - 5);
                },
                else => {
                    put(cv, body, x, y, hit);
                    if (!manned) return;
                    const tx = x + ([8]i32{ 4, 2, -1, -3, 4, 2, -1, -3 })[d];
                    const ty = y + ([8]i32{ 0, -3, -5, -4, 0, -3, -5, -4 })[d];
                    put(cv, vs.top[owner][td], tx + ([8]i32{ 4, 0, 0, 0, -4, 0, 0, 0 })[td], ty + ([8]i32{ 0, -2, -2, -2, 0, 0, 0, 0 })[td], hit);
                    drawLid(cv, s, o, v, tx + ([8]i32{ 8, 13, 16, 17, 16, 11, 7, 7 })[td], ty + ([8]i32{ 9, 9, 7, 4, 3, 2, 4, 7 })[td]);
                },
            }
        },
        .jeep => {
            if (o.isDestroyed()) return put(cv, vs.wasted[owner], x, y, hit);
            const bounce: i32 = @intFromBool(v.jeep_bounce);
            const body = vs.base[owner][d][@intCast(bounce)];
            if (d != 2 and d != 6) put(cv, s.jeep.under[d][f % 4], x, y, hit);
            put(cv, body, x, y, hit);
            if (!manned) return;
            const gx = x + ([8]i32{ 0, 6, 12, 20, 25, 20, 15, 5 })[d] + ([8]i32{ 0, -2, -5, -8, -10, -8, -5, -2 })[td];
            const gy = y + ([8]i32{ 2, 7, 4, 8, 2, -4, -3, -4 })[d] + ([8]i32{ 0, 0, 0, 0, 0, 5, 6, 5 })[td] - bounce;
            put(cv, if (v.firing) s.jeep.gun_fire[td] else s.jeep.gun[td], gx, gy, hit);
        },
        .apc => {
            if (o.isDestroyed()) return put(cv, vs.wasted[owner], x, y, hit);
            put(cv, vs.base[owner][d][f % 3], x, y, hit);
            if (manned) put(cv, vs.top[0][td], x + ([8]i32{ 1, 5, 9, 13, 15, 11, 8, 5 })[d], y + ([8]i32{ 5, 8, 5, 8, 5, 3, 3, 4 })[d], hit);
        },
        .missile_launcher => {
            if (o.isDestroyed()) return put(cv, vs.wasted[owner], x, y, false);
            put(cv, vs.base[owner][d][f % 3], x, y, hit);
            if (!manned) return;
            put(cv, vs.top[owner][td], x + ([8]i32{ 0, 2, 3, 8, 9, 7, 2, 0 })[d] + ([8]i32{ 2, 0, 0, 0, 0, -2, 0, 0 })[td], y + ([8]i32{ 0, 3, 0, 4, 0, -2, -3, -3 })[d] + ([8]i32{ 0, 0, 0, -2, -2, 0, 2, -2 })[td], hit);
        },
        .crane => {
            if (o.isDestroyed()) return put(cv, vs.wasted[owner], x, y, false);
            put(cv, vs.base[owner][d][f % 3], x, y, hit);
            if (!manned) return;
            const cx = x + ([8]i32{ -6, -3, 0, 3, 6, 1, 0, -2 })[d];
            const cy = y + ([8]i32{ -6, -4, -5, -4, -6, -8, -9, -8 })[d];
            put(cv, s.crane.hook[v.hook_i], cx + ([8]i32{ 0, 4, 14, 23, 25, 21, 14, 5 })[d], cy + ([8]i32{ 14, 20, 23, 20, 14, 8, 5, 8 })[d], hit);
            put(cv, s.crane.arm[d], cx, cy, hit);
        },
    }
}

/// A tank's hatch, with the driver when it is open.
fn drawLid(cv: Canvas, s: *const Sprites, o: *const Object, v: *const UnitVisual, x: i32, y: i32) void {
    const td = v.turret;
    const lid = s.robot.tank_lid[td][v.lid_i % 3];
    if (!v.show_robot) return put(cv, lid, x, y, v.hit);
    const driver = s.robot.tank_robot[@intFromEnum(o.owner)][td][0];
    const rx = x + ([8]i32{ 3, -1, -3, -7, -10, -7, -4, 0 })[td];
    const ry = y + ([8]i32{ 0, -4, -6, -4, 0, 1, 1, 1 })[td];
    // The driver sits behind the hatch when facing away.
    if (td > 3 or td == 0) {
        put(cv, lid, x, y, v.hit);
        put(cv, driver, rx, ry, v.driver_hit);
    } else {
        put(cv, driver, rx, ry, v.driver_hit);
        put(cv, lid, x, y, v.hit);
    }
}

test "directions" {
    try std.testing.expectEqual(@as(?u3, 0), directionFrom(1, 0));
    try std.testing.expectEqual(@as(?u3, 2), directionFrom(0, -1));
    try std.testing.expectEqual(@as(?u3, 1), directionFrom(1, -1));
    try std.testing.expectEqual(@as(?u3, 4), directionFrom(-1, 0));
    try std.testing.expectEqual(@as(?u3, 6), directionFrom(0, 1));
    try std.testing.expectEqual(@as(?u3, 7), directionFrom(1, 1));
    try std.testing.expectEqual(@as(?u3, null), directionFrom(0, 0));
}
