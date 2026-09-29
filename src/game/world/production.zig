//! Factories and forts: what they build, their queues and build times,
//! new units leaving them, repairs, robots entering and leaving vehicles
//! and buildings (part of World, see world.zig).

const std = @import("std");
const k = @import("../constants.zig");
const buildlist = @import("../buildlist.zig");
const obj = @import("../object.zig");
const protocol = @import("../../net/protocol.zig");
const world = @import("../world.zig");
const World = world.World;
const Error = world.Error;
const Object = world.Object;
const Point = world.Point;

/// Start producing the first unit on the list if nothing is chosen.
pub fn setDefaultProduction(w: *World, o: *Object) Error!bool {
    const b = o.building() orelse return false;
    if (b.unit != null or b.state != .select) return false;
    const u = buildlist.first(b.type, b.level) orelse return false;
    return setProduction(w, o, u);
}

pub fn setProduction(w: *World, o: *Object, u: obj.Unit) Error!bool {
    const b = o.building() orelse return false;
    if (o.owner == .none or !b.producesUnits()) return false;
    if (b.unit) |cur| if (cur.kind == u.kind and cur.id == u.id) return false;
    if (!buildlist.contains(b.type, b.level, u)) return false;
    b.unit = u;
    b.state = .building;
    b.init_time = w.now();
    _ = recalcBuildTime(w, o);
    if (b.queue.items.len == 0) _ = try addToQueue(w, o, u, true);
    return true;
}

pub fn addToQueue(w: *World, o: *Object, u: obj.Unit, front: bool) Error!bool {
    const b = o.building() orelse return false;
    if (o.owner == .none or !b.producesUnits()) return false;
    if (b.queue.items.len >= obj.max_queue_items) return false;
    if (!buildlist.contains(b.type, b.level, u)) return false;
    const pos: usize = if (front) 0 else b.queue.items.len;
    try b.queue.insert(w.gpa, pos, u);
    return true;
}

pub fn cancelQueued(o: *Object, index: i32, u: obj.Unit) bool {
    const b = o.building() orelse return false;
    if (o.owner == .none or !b.producesUnits()) return false;
    if (index < 0 or index >= b.queue.items.len) return false;
    const q = b.queue.items[@intCast(index)];
    if (q.kind != u.kind or q.id != u.id) return false;
    _ = b.queue.orderedRemove(@intCast(index));
    return true;
}

pub fn stopProduction(o: *Object, clear_queue: bool) bool {
    const b = o.building() orelse return false;
    if (b.unit == null and b.state == .select) return false;
    b.state = .select;
    b.unit = null;
    if (clear_queue) b.queue.clearRetainingCapacity();
    return true;
}

/// After a unit is built: continue with the queue or stop.
pub fn resetProduction(w: *World, o: *Object) Error!void {
    const b = o.building() orelse return;
    if (b.queue.items.len > 0) {
        const next = b.queue.orderedRemove(0);
        _ = stopProduction(o, false);
        _ = try setProduction(w, o, next);
    } else {
        _ = stopProduction(o, true);
    }
}

pub fn resetBuildTime(w: *World, o: *Object, zone_ownage: f32) bool {
    const b = o.building() orelse return false;
    if (zone_ownage == b.zone_ownage) return false;
    b.zone_ownage = std.math.clamp(zone_ownage, 0, 1);
    return recalcBuildTime(w, o);
}

/// Production is faster with more zones, slower when damaged.
pub fn recalcBuildTime(w: *World, o: *Object) bool {
    const b = o.building() orelse return false;
    const u = b.unit orelse return false;
    if (b.state == .select) return false;
    const settings = w.settings.unit(u.kind, u.id) orelse return false;
    var t: f64 = @floatFromInt(settings.build_time);
    t -= t * 0.5 * b.zone_ownage;
    t += t * (1.25 * (1.0 - o.healthRatio()));
    const old = b.final_time;
    b.final_time = b.init_time + t;
    return old != b.final_time;
}

/// Wire state of a building (BUILDING_PAUSED when the team hit its
/// unit limit is shown by clients themselves).
pub fn buildingState(w: *const World, o: *Object) ?protocol.SetBuildingState {
    const b = o.building() orelse return null;
    const u = b.unit;
    return .{
        .ref_id = o.ref_id,
        .state = @intFromEnum(b.state),
        .init_offset = b.init_time - w.now(),
        .prod_time = b.final_time - b.init_time,
        .ot = if (u) |x| @intFromEnum(x.kind) else 255,
        .oid = if (u) |x| x.id else 255,
    };
}

/// Store a built cannon in the building (up to four).
pub fn storeBuiltCannon(w: *World, o: *Object, c: k.Cannon) Error!bool {
    const b = o.building() orelse return false;
    if (b.cannons.items.len >= k.max_stored_cannons) return false;
    try b.cannons.append(w.gpa, c);
    return true;
}

/// Create a produced unit next to the building and send it out.
pub fn buildingCreateUnit(w: *World, o: *Object, u: obj.Unit) Error!?*Object {
    if (u.kind == .cannon) {
        if (w.cannonsInZone(o) < k.max_stored_cannons) {
            if (try storeBuiltCannon(w, o, @enumFromInt(u.id))) {
                try w.relayBuiltCannons(o);
                try w.compMessage(o.owner, o.ref_id, .gun);
            }
        }
        return null;
    }
    const p = o.creationPoint() orelse return null;
    const new = (if (u.kind == .robot)
        try w.createRobotGroup(@enumFromInt(u.id), p.x, p.y, o.owner, .deferred, null, 100)
    else
        try w.createObject(u.kind, u.id, p.x, p.y, o.owner, .deferred, .{})) orelse return null;
    try launchNewUnit(w, new, p, o.creationMovePoint().?);
    try new.waypoints.appendSlice(w.gpa, o.rallypoints.items);
    try announceNewUnit(w, new);
    try w.compMessage(new.owner, new.ref_id, if (u.kind == .robot) .robot else .vehicle);
    return new;
}

/// Center a new unit (and its squad) on `at` and send it to `exit`.
fn launchNewUnit(w: *World, new: *Object, at: Point, exit: Point) Error!void {
    const nx = at.x - (new.width_pix >> 1);
    const ny = at.y - (new.height_pix >> 1);
    new.setPosition(nx, ny);
    for (new.minions.items) |id| if (findNew(w, id)) |m| m.setPosition(nx, ny);
    try new.waypoints.append(w.gpa, .{ .mode = .force_move, .ref_id = -1, .x = exit.x, .y = exit.y });
}

/// Look up objects that are not yet in the main list.
pub fn findNew(w: *const World, ref_id: i32) ?*Object {
    for (w.new_objects.items) |o| if (o.ref_id == ref_id) return o;
    return w.find(ref_id);
}

/// After launching: announce a unit (and its squad) with its orders.
pub fn announceNewUnit(w: *World, new: *Object) Error!void {
    for (new.minions.items) |id| {
        const m = findNew(w, id) orelse continue;
        m.waypoints.clearRetainingCapacity();
        try m.waypoints.appendSlice(w.gpa, new.waypoints.items);
    }
    try w.relayNewObject(new, .all);
    for (new.minions.items) |id| if (findNew(w, id)) |m| try w.relayNewObject(m, .all);
    try w.relayWaypoints(new);
}

/// A repair station finished: the unit comes out as new.
pub fn buildingRepairUnit(w: *World, o: *Object, job: *obj.Building.Repair) Error!?*Object {
    const p = o.repairCenter() orelse return null;
    const new = (if (job.unit.kind == .robot)
        try w.createRobotGroup(@enumFromInt(job.unit.id), p.x, p.y, o.owner, .deferred, null, 100)
    else
        try w.createObject(job.unit.kind, job.unit.id, p.x, p.y, o.owner, .deferred, .{})) orelse return null;
    if (job.drivers.items.len > 0) {
        new.driver_type = @enumFromInt(job.driver_type);
        new.drivers.clearRetainingCapacity();
        try new.drivers.appendSlice(w.gpa, job.drivers.items);
        new.resetDamageInfo(&w.settings);
    }
    try launchNewUnit(w, new, p, o.repairEntrance().?);
    // The unit's orders from before the repair, minus the repair itself.
    if (job.waypoints.items.len > 1) try new.waypoints.appendSlice(w.gpa, job.waypoints.items[1..]);
    try announceNewUnit(w, new);
    try w.resetObjectTeam(new, new.owner);
    return new;
}

/// A unit drives into a repair station.
pub fn unitEnterRepairBuilding(w: *World, unit: *Object, station: *Object) Error!void {
    const b = station.building() orelse return;
    if (b.repair != null or !station.canRepairUnit(unit.owner)) return;
    var job: obj.Building.Repair = .{
        .unit = .{ .kind = unit.objectType(), .id = unit.objectId() },
        .driver_type = @intFromEnum(unit.driver_type),
        .drivers = .empty,
        .waypoints = .empty,
        .done_time = w.now() + 5,
    };
    try job.drivers.appendSlice(w.gpa, unit.drivers.items);
    try job.waypoints.appendSlice(w.gpa, unit.waypoints.items);
    b.repair = job;
    if (unit.kill_time == null) unit.kill_time = 0;
    try w.relayRepairAnim(station, .all, true);
}

/// A robot squad climbs into an empty vehicle or cannon.
pub fn robotEnterObject(w: *World, robot: *Object, target: *Object) Error!void {
    if (!target.canBeEntered()) return;
    target.setDriverType(&w.settings, robot.kind.robot);
    try target.addDriver(w.gpa, &w.settings, robot.health);
    if (robot.kill_time == null) robot.kill_time = 0;
    // All of an APC's seats are filled by the squad.
    if (target.isVehicle(.apc)) {
        for (robot.minions.items) |id| {
            const m = w.find(id) orelse continue;
            try target.addDriver(w.gpa, &w.settings, m.health);
            if (m.kill_time == null) m.kill_time = 0;
        }
    }
    try w.resetObjectTeam(target, robot.owner);
    try w.relayPortraitAnim(target.ref_id, if (target.kind == .vehicle) .vehicle_captured else .gun_captured);
}

/// Robots leave a vehicle/cannon (EJECT_VEHICLE).
pub fn ejectDrivers(w: *World, o: *Object) Error!void {
    if (!o.canEjectDrivers()) return;
    if (o.drivers.items.len > 0) {
        const was_cannon = o.kind == .cannon;
        const n = o.drivers.items.len;
        if (try w.createRobotGroup(o.driver_type, o.x, o.y, o.owner, .direct, n, 100)) |leader| {
            try w.relayNewObject(leader, .all);
            w.setHealth(leader, o.drivers.items[0].health);
            try w.updateObjectHealth(leader, null);
            leader.just_left_cannon = was_cannon;
            for (leader.minions.items, 1..) |id, i| {
                const m = w.find(id) orelse continue;
                try w.relayNewObject(m, .all);
                // The original set the leader's health here too.
                if (i < n) w.setHealth(leader, o.drivers.items[i].health);
                try w.updateObjectHealth(m, null);
                if (was_cannon) leader.just_left_cannon = true;
            }
        }
        o.clearDrivers(&w.settings);
        o.waypoints.clearRetainingCapacity();
        try w.relayWaypoints(o);
        if (w.stopMove(o)) try w.relayLocation(o);
        o.attack_target = null;
        try w.relayAttackTarget(o);
    }
    try w.resetObjectTeam(o, .none);
}
