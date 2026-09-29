//! Moving effects along, spawning what they leave behind, and removing
//! those that are over (part of Effects, see effects.zig).

const std = @import("std");
const game = @import("../../game.zig");
const gfx = @import("../gfx.zig");
const motion = @import("motion.zig");
const int = motion.int;
const effects = @import("../effects.zig");
const Effects = effects.Effects;
const Rocket = effects.Rocket;
const Effect = effects.Effect;
const Context = effects.Context;

pub fn update(fx: *Effects, ctx: Context) void {
    fx.time = ctx.time;
    fx.grenade_speed = ctx.world.settings.grenade_missile_speed;
    if (ctx.world.map) |m| fx.planet = m.planet();
    inline for (.{ &fx.ground, &fx.air }) |list| {
        var i: usize = 0;
        while (i < list.items.len) {
            if (step(fx, &list.items[i], ctx)) {
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
        .rocket => |*r| return stepRocket(fx, r, ctx),
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
