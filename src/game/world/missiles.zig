//! Explosions that happen later (grenades, rockets, shells) and the
//! damage they do around them (part of World, see world.zig).

const std = @import("std");
const world = @import("../world.zig");
const World = world.World;
const Error = world.Error;
const DamageMissile = world.DamageMissile;

pub fn fireMissile(w: *World, m: DamageMissile) Error!void {
    try w.missiles.append(w.gpa, m);
}

/// Explode due missiles and damage everything in their radius.
pub fn processMissiles(w: *World) Error!void {
    const t = w.now();
    var i: usize = 0;
    while (i < w.missiles.items.len) {
        if (t >= w.missiles.items[i].explode_time) {
            const m = w.missiles.orderedRemove(i);
            try missileDamage(w, m);
        } else i += 1;
    }
    try w.missiles.appendSlice(w.gpa, w.new_missiles.items);
    w.new_missiles.clearRetainingCapacity();
}

fn missileDamage(w: *World, m: DamageMissile) Error!void {
    if (m.radius <= 0) return;
    const radius: f32 = @floatFromInt(m.radius);
    for (w.objects.items) |o| {
        if (o.isDestroyed()) continue;
        if (m.team != .none and o.owner == m.team) continue;
        const dx = m.x - o.center_x;
        const dy = m.y - o.center_y;
        if (@abs(dx) > m.radius or @abs(dy) > m.radius) continue;
        const mag = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
        if (mag >= radius) continue;
        const dmg: f64 = @as(f64, @floatFromInt(m.damage)) * (1.0 - mag / radius);
        w.damageHealth(o, @intFromFloat(dmg));
        o.damaged_by_missile_time = w.now();
        if (m.attacker != null and m.attack_player_given and m.target == o.ref_id and o.isDestroyed()) {
            try w.relayPortraitAnim(m.attacker.?, .target_destroyed);
        }
        try w.updateObjectHealth(o, m.attacker);
    }
}
