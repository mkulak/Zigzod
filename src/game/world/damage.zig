//! Health, damage and destruction: what happens when objects are hurt or
//! killed (part of World, see world.zig).

const std = @import("std");
const fit = @import("../../text.zig").fit;
const k = @import("../constants.zig");
const protocol = @import("../../net/protocol.zig");
const world = @import("../world.zig");
const World = world.World;
const Error = world.Error;
const Object = world.Object;

pub fn setHealthPercent(w: *World, o: *Object, percent: i32) void {
    const p = std.math.clamp(percent, 0, 100);
    o.initial_health_percent = p;
    setHealth(w, o, @divTrunc(p * o.max_health, 100));
}

pub fn setHealth(w: *World, o: *Object, new_health: i32) void {
    const was_destroyed = o.isDestroyed();
    o.health = std.math.clamp(new_health, 0, o.max_health);
    if (was_destroyed and !o.isDestroyed()) {
        if (w.grid) |*g| o.setDestroyedImpassables(g, false);
    } else if (!was_destroyed and o.isDestroyed()) {
        if (w.grid) |*g| o.setDestroyedImpassables(g, true);
        onKilled(w, o);
    }
}

/// Something was just destroyed: buildings repair themselves later
/// (forts don't), factories stop producing.
fn onKilled(w: *World, o: *Object) void {
    const b = o.building() orelse return;
    if (!b.isFort()) {
        var t = w.now() + @as(f64, @floatFromInt(w.settings.building_auto_repair_time));
        const extra = w.settings.building_auto_repair_random_additional_time;
        if (extra > 0) t += @floatFromInt(w.randInt(extra + 1));
        o.auto_repair_time = t;
    }
    if (b.producesUnits()) _ = World.stopProduction(o, true);
}

pub fn damageHealth(w: *World, o: *Object, amount: i32) void {
    if (o.health <= 0) return;
    setHealth(w, o, o.health - amount);
    _ = w.recalcBuildTime(o);
}

/// Hurt the driver of a vehicle/cannon; an empty vehicle loses its team.
pub fn damageDriverHealth(w: *World, o: *Object, amount: i32) bool {
    if (o.drivers.items.len == 0) return false;
    const d = &o.drivers.items[0];
    if (d.health <= 0) return false;
    d.health -= amount;
    if (d.health <= 0) {
        o.clearDrivers(&w.settings);
        o.owner = .none;
    }
    return true;
}

/// Tell everyone about a health change and handle deaths
/// (ZServer::UpdateObjectHealth).
pub fn updateObjectHealth(w: *World, o: *Object, attacker: ?i32) Error!void {
    if (o.isDestroyed() and !o.processed_death) {
        o.processed_death = true;
        try relayObjectDeath(w, o, attacker);
        try checkDestroyedFort(w, o);
        try checkDestroyedBridge(w, o);
        try checkNoUnitsDestroyFort(w, o.owner);
    } else {
        try w.relayHealth(o, .all);
    }
    try w.relayBuildingState(o, .all);
}

/// A vehicle's driver was hit: show the effect, or if the driver died,
/// the vehicle stops and becomes neutral.
pub fn updateObjectDriverHealth(w: *World, o: *Object) Error!void {
    if (o.drivers.items.len > 0 and o.drivers.items[0].health > 0) {
        try w.sendPacket(.all, .driver_hit_effect, protocol.DriverHit{ .ref_id = o.ref_id });
        return;
    }
    try w.sendPacket(.all, .snipe_object, protocol.SnipeObject{ .ref_id = o.ref_id });
    if (w.disengage(o)) try w.relayAttackTarget(o);
    try w.resetObjectTeam(o, .none);
    if (o.waypoints.items.len > 0) {
        o.waypoints.clearRetainingCapacity();
        try w.relayWaypoints(o);
        if (w.stopMove(o)) try w.relayLocation(o);
    }
    for (w.objects.items) |other| {
        if (other.attack_target == o.ref_id) {
            _ = w.disengage(other);
            try w.relayAttackTarget(other);
        }
        if (other.waypoints.items.len > 0) {
            const wp = other.waypoints.items[0];
            if ((wp.mode == .attack or wp.mode == .agro) and wp.ref_id == o.ref_id) {
                _ = other.waypoints.orderedRemove(0);
                try w.relayWaypoints(other);
                if (w.stopMove(other)) try w.relayLocation(other);
            }
        }
    }
}

fn relayObjectDeath(w: *World, o: *Object, killer: ?i32) Error!void {
    const t = w.now();
    // Exploding turrets/grenade boxes fire missiles on death.
    var missiles: [128]protocol.FireMissileInfo = undefined;
    var n: usize = 0;
    var missile_damage: i32 = 0;
    const missile_radius: i32 = 40;
    const mh = w.settings.max_turrent_horizontal_distance;
    const mv = w.settings.max_turrent_vertical_distance;
    // Cannons and tanks throw their turret (the missile they fire when
    // they blow up).
    const turret_delay: ?[2]i32 = switch (o.kind) {
        .cannon => .{ 7, 300 },
        .vehicle => |v| switch (v.type) {
            .light, .medium, .heavy => .{ 3, 100 },
            else => null,
        },
        else => null,
    };
    if (turret_delay) |d| {
        missiles[0] = .{
            .offset_time = @as(f64, @floatFromInt(d[0])) + 0.01 * @as(f64, @floatFromInt(w.randInt(d[1]))),
            .x = (o.x + 16) + (mh - w.randInt(mh + mh)),
            .y = (o.y + 16) + (mv - w.randInt(mv + mv)),
        };
        n = 1;
        missile_damage = 40;
    }
    switch (o.kind) {
        .item => |item| if (item == .grenades) {
            const max_off = 130;
            while (n < @as(usize, @intCast(@max(o.grenades, 0))) and n < missiles.len) : (n += 1) {
                missiles[n] = .{
                    .x = (o.x + 16) + (max_off - w.randInt(max_off * 2)),
                    .y = (o.y + 16) + (max_off - w.randInt(max_off * 2)),
                    .offset_time = 3 + 0.01 * @as(f64, @floatFromInt(w.randInt(100))),
                };
                missile_damage = @intFromFloat(w.settings.grenade_damage * k.max_unit_health);
            }
        } else if (item.mapObjectIndex() != null) {
            missiles[0] = .{
                .offset_time = 3 + 0.01 * @as(f64, @floatFromInt(w.randInt(100))),
                .x = (o.x + 16) + (mh - w.randInt(mh + mh)),
                .y = (o.y + 16) + (mv - w.randInt(mv + mv)),
            };
            n = 1;
            missile_damage = @intFromFloat(w.settings.map_item_turrent_damage * k.max_unit_health);
        },
        else => {},
    }
    for (missiles[0..n]) |m| {
        try w.new_missiles.append(w.gpa, .{
            .x = m.x,
            .y = m.y,
            .damage = missile_damage,
            .radius = missile_radius,
            .explode_time = t + m.offset_time,
        });
    }

    // Destroyed objects that go away are deleted with the next step
    // (DELETE_OBJECT). The original meant to say so with
    // `destroy_object`, but always sent false; C++ clients remove the
    // object at once when it is true, so it stays false.
    const header: protocol.DestroyObject = .{
        .ref_id = o.ref_id,
        .fire_missile_amount = @intCast(n),
        .killer_ref_id = killer orelse -1,
        .destroy_object = false,
        .do_fire_death = t - o.damaged_by_fire_time < 1.5,
        .do_missile_death = t - o.damaged_by_missile_time < 1.5,
    };
    if (o.can_be_destroyed and o.kill_time == null) o.kill_time = t;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(w.gpa);
    try payload.appendSlice(w.gpa, std.mem.asBytes(&header));
    try payload.appendSlice(w.gpa, std.mem.sliceAsBytes(missiles[0..n]));
    try w.send(.all, .destroy_object, payload.items);
    if (o.producesUnits()) try w.relayBuildingState(o, .all);
}

/// Kill everything standing on a destroyed bridge.
fn checkDestroyedBridge(w: *World, o: *Object) Error!void {
    const b = o.building() orelse return;
    if (!b.isBridge()) return;
    for (w.objects.items) |other| {
        if (other.isDestroyed() or !other.isMobile()) continue;
        if (!other.intersects(o)) continue;
        setHealth(w, other, 0);
        try relayObjectDeath(w, other, null);
    }
}

/// Losing a fort eliminates its team.
fn checkDestroyedFort(w: *World, o: *Object) Error!void {
    if (!o.isFort()) return;
    const team = o.owner;
    if (team == .none) return;
    try w.sendPacket(.all, .team_ended, protocol.TeamEnded{ .team = @intFromEnum(team), .won = false });
    for (w.objects.items) |other| {
        if (other.owner != team or other.isDestroyed() or other == o) continue;
        if (other.kind == .flag or other.kind == .item) continue;
        setHealth(w, other, 0);
        try relayObjectDeath(w, other, null);
    }
    for (w.objects.items) |f| {
        if (f.kind == .flag and f.owner == team) try w.awardZone(f, .none, null);
    }
    var buf: [96]u8 = undefined;
    try w.news(.all, fit(&buf, "The {s} team has been eliminated", .{team.name()}), .{});
}

/// A team without units loses its forts.
fn checkNoUnitsDestroyFort(w: *World, team: k.Team) Error!void {
    if (team == .none) return;
    for (w.objects.items) |o| {
        if (o.owner == team and o.isUnit() and !o.isDestroyed()) return;
    }
    for (w.objects.items) |o| {
        if (o.owner != team or !o.isFort() or o.isDestroyed()) continue;
        setHealth(w, o, 0);
        try checkDestroyedFort(w, o);
        try relayObjectDeath(w, o, null);
    }
}
