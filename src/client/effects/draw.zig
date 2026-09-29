//! Drawing the effects (part of Effects, see effects.zig).

const std = @import("std");
const game = @import("../../game.zig");
const gfx = @import("../gfx.zig");
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const motion = @import("motion.zig");
const int = motion.int;
const effects = @import("../effects.zig");
const Effects = effects.Effects;
const mushroom_shift = effects.mushroom_shift;
const Effect = effects.Effect;

/// Draw `img` turned and scaled, from its corner or centered on (x, y).
pub fn put(fx: *Effects, cv: Canvas, view: gfx.Rect, img: Image, x: i32, y: i32, angle: f64, size: f64, centered: bool) void {
    const i = img;
    // Skip what is well off screen before transforming.
    const margin = 2 * @max(i.width(), i.height()) + 32;
    if (x < view.x - margin or y < view.y - margin or x > view.x + view.w + margin or y > view.y + view.h + margin) return;
    const out = fx.transforms.get(i, angle, size) orelse return;
    if (centered) cv.drawCentered(out, x, y) else cv.draw(out, x, y);
}

/// Tracks, dust and oil: under the objects.
pub fn drawGround(fx: *Effects, cv: Canvas, view: gfx.Rect) void {
    for (fx.ground.items) |*e| drawOne(fx, e, cv, view);
}

/// Everything else: over the objects.
pub fn draw(fx: *Effects, cv: Canvas, view: gfx.Rect) void {
    for (fx.air.items) |*e| drawOne(fx, e, cv, view);
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
            put(fx, cv, view, img, int(at.x), int(at.y), b.angle, 1, false);
            // Flames flicker.
            if (b.flame) b.img = fx.pick(4);
        },
        .rocket => |r| {
            var at = r.line.at(t);
            at.x += r.offset.x;
            at.y += r.offset.y;
            const x = int(at.x);
            const y = int(at.y);
            switch (r.kind) {
                .light => put(fx, cv, view, s.light_bullet, x, y, r.angle, 1, false),
                .tough => put(fx, cv, view, s.tough_bullet[0], x, y, r.angle, 1, true),
                .launcher => {
                    put(fx, cv, view, s.mo_bullet, x, y, r.angle, 1, true);
                    put(fx, cv, view, s.mo_bullet, int(at.x + r.side.x), int(at.y + r.side.y), r.angle, 1, true);
                    put(fx, cv, view, s.mo_bullet, int(at.x - r.side.x), int(at.y - r.side.y), r.angle, 1, true);
                },
                .missile_cannon => {
                    put(fx, cv, view, s.mc_bullet, x, y, r.angle, 1, true);
                    put(fx, cv, view, s.mc_bullet, int(at.x + r.side.x), int(at.y + r.side.y), r.angle, 1, true);
                },
            }
        },
        .anim => |a| {
            const img = if (a.frames.i < a.first.len) a.first[a.frames.i] else a.imgs[@min(a.frames.i, a.imgs.len - 1)];
            const y = if (a.mushroom) a.y + int(mushroom_shift[@min(a.frames.i, 11)] * a.size) else a.y;
            put(fx, cv, view, img, a.x, y, 0, a.size, a.centered);
        },
        .side_explosion => |x| {
            const at = x.line.at(t);
            put(fx, cv, view, s.side_explosion[@min(x.frames.i, 6)], int(at.x), int(at.y), 0, x.size, false);
        },
        .particle => |p| {
            const at = p.arc.line.at(t);
            put(fx, cv, view, s.unit_particle[p.frames.i], int(at.x), int(at.y - p.arc.lift(t) * 65), 0, 1, false);
        },
        .spark => |p| {
            const at = p.arc.line.at(t);
            const lift = p.arc.lift(t);
            put(fx, cv, view, s.spark[p.frames.i], int(at.x), int(at.y - lift * 30), 0, lift, true);
        },
        .robot_flip => |p| {
            const in_air = t < p.arc.line.t1;
            const at = p.arc.line.at(@min(t, p.arc.line.t1));
            const lift = if (in_air) p.arc.lift(t) else 0;
            put(fx, cv, view, s.robot_flip[@intFromEnum(p.team)][p.frames.i], int(at.x), int(at.y - lift * 30), 0, 1 + lift, true);
        },
        .rock_particle => |p| {
            const at = p.arc.line.at(t);
            const lift = p.arc.lift(t);
            put(fx, cv, view, p.imgs[p.frames.i % p.imgs.len], int(at.x), int(at.y - lift * 150), 0, 1 + lift, true);
        },
        .rock_chunk => |p| {
            const at = p.arc.line.at(t);
            const lift = p.arc.lift(t);
            put(fx, cv, view, p.imgs[p.frames.i], int(at.x), int(at.y - lift * 30), @mod(p.spin * (t - p.arc.line.t0), 360), 1 + lift, true);
        },
        .turret => |p| {
            const at = p.arc.line.at(t);
            const size = p.arc.lift(t) + 1;
            const img = p.piece.image(s, p.team, p.frames.i);
            put(fx, cv, view, img, int(at.x), int(at.y - size * 30 + 30), @mod(p.spin * (t - p.arc.line.t0), 360), size, true);
        },
        .map_object => |p| {
            const at = p.arc.line.at(t);
            const lift = p.arc.lift(t);
            put(fx, cv, view, s.map_object[p.index], int(at.x), int(at.y - lift * 30), @mod(p.spin * (t - p.arc.line.t0), 360), lift + 1, true);
        },
        .wreck => |*w| {
            cv.draw(w.img, w.x, w.y);
            for (w.fires[0..w.fire_n]) |*f| f.draw(cv, s);
        },
        .track => |tr| for (tr.pos, tr.lay) |p, lay| {
            if (lay) put(fx, cv, view, tr.imgs[tr.i], p[0], p[1], 0, 1, true);
        },
    }
}
