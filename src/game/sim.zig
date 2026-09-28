//! The server's simulation step: every object follows its orders (moving,
//! attacking, entering vehicles, repairing, ...), fights enemies nearby and
//! produces units; afterwards the results are applied to the world and sent
//! to clients (from ZObject::ProcessServer and ZServer::ProcessObjects).
//!
//! Path finding runs synchronously here; the original used threads and
//! waited for their answers.

const std = @import("std");
const k = @import("constants.zig");
const obj = @import("object.zig");
const pathfinding = @import("pathfinding.zig");
const protocol = @import("../net/protocol.zig");
const World = @import("world.zig").World;
const DamageMissile = @import("world.zig").DamageMissile;

const Object = obj.Object;
const Waypoint = obj.Waypoint;
const Point = pathfinding.Point;
const Error = std.mem.Allocator.Error;

// Progress through the waypoints that have several stages
// (`WaypointState.stage`).
const CraneStage = enum(u8) { goto_entrance, enter, exit };
const RepairStage = enum(u8) { goto_entrance, enter, exit, wait };
const AgroStage = enum(u8) { attack, back_to_center };
const FortStage = enum(u8) { goto_entrance, enter, exit };

fn stage(o: *const Object, comptime S: type) S {
    return @enumFromInt(o.wp.stage);
}

fn setStage(o: *Object, s: anytype) void {
    o.wp.stage = @intFromEnum(s);
}

/// One simulation step: scuffle idle units, remove the dead, process every
/// object, report what happened, then explode missiles.
pub fn step(w: *World) Error!void {
    try w.scuffleUnits();

    const t = w.now();
    var i: usize = 0;
    while (i < w.objects.items.len) {
        const o = w.objects.items[i];
        if (o.kill_time) |kt| if (t >= kt) {
            try w.deleteObject(i);
            continue;
        };
        i += 1;
    }

    for (w.objects.items) |o| try processObject(w, o);
    // Reporting can't add to `objects` (new units wait in `new_objects`).
    for (w.objects.items) |o| try report(w, o);

    try w.addNewObjects();
    try w.checkFlagCaptures();
    try w.processMissiles();
}

// ---------------------------------------------------------------------------
// Orders from players
// ---------------------------------------------------------------------------

/// Replace a unit's orders with ones a player sent; invalid waypoints are
/// dropped and ones only the server may give are downgraded. Returns false
/// if the unit takes no orders from `team`.
pub fn setOrders(w: *World, o: *Object, team: k.Team, orders: []const Waypoint) Error!bool {
    if (o.owner == .none or o.owner != team) return false;
    if (!o.canSetWaypoints() or o.leader != null) return false;

    // A waypoint in a stage that can't be interrupted stays first.
    if (!canOverwriteWaypoint(o) and o.waypoints.items.len > 0) {
        o.waypoints.shrinkRetainingCapacity(1);
    } else {
        o.waypoints.clearRetainingCapacity();
    }
    for (orders) |order| {
        var wp = order;
        if (checkOrder(w, o, &wp)) try o.waypoints.append(w.gpa, wp);
    }
    o.just_left_cannon = false;
    try w.cloneMinionWaypoints(o);
    return true;
}

pub fn setRallypoints(w: *World, o: *Object, team: k.Team, points: []const Waypoint) Error!bool {
    if (o.owner == .none or o.owner != team) return false;
    if (!o.canSetRallypoints()) return false;
    o.rallypoints.clearRetainingCapacity();
    for (points) |p| if (p.mode == .move) try o.rallypoints.append(w.gpa, p);
    return true;
}

fn checkOrder(w: *World, o: *Object, wp: *Waypoint) bool {
    if (!o.canAttack()) wp.attack_to = false;
    const target = w.find(wp.ref_id);
    switch (wp.mode) {
        .move => return o.canMove(),
        // Only the server gives these.
        .force_move, .dodge => {
            wp.mode = .move;
            return o.canMove();
        },
        .agro => {
            wp.mode = .attack;
            const t = target orelse return false;
            return canAttackObject(w, o, t);
        },
        .attack => {
            const t = target orelse return false;
            return canAttackObject(w, o, t);
        },
        .enter => {
            const t = target orelse return false;
            return o.canMove() and o.kind == .robot and t.canBeEntered();
        },
        .crane_repair => {
            const t = target orelse return false;
            return o.canMove() and o.isVehicle(.crane) and t.canBeRepairedByCrane(o.owner);
        },
        .unit_repair => {
            const t = target orelse return false;
            return o.canMove() and o.canBeRepaired() and t.canRepairUnit(o.owner);
        },
        .enter_fort => {
            const t = target orelse return false;
            return o.canMove() and t.canEnterFort(o.owner);
        },
        .pickup_grenades => {
            const t = target orelse return false;
            return o.canMove() and o.canPickupGrenades() and t.isItem(.grenades);
        },
        .none, _ => return false,
    }
}

// ---------------------------------------------------------------------------
// Processing one object
// ---------------------------------------------------------------------------

fn processObject(w: *World, o: *Object) Error!void {
    const t = w.now();
    const dt = t - o.last_process_time;
    o.last_process_time = t;
    o.ev = .{};

    o.ev.auto_repaired = autoRepair(w, o);
    processStamina(w, o, dt);
    if (o.isDestroyed()) return;

    o.ev.build_unit = unitBuilt(w, o);
    if (o.building()) |b| if (b.repair) |r| {
        o.ev.repair_done = t >= r.done_time;
    };
    processLid(w, o);

    var attack_player_given = false;
    if (o.waypoints.items.len > 0) {
        const wp = o.waypoints.items[0];
        const is_new = !wp.eql(o.last_wp);
        if (is_new) {
            o.last_wp = wp;
            o.xover = 0;
            o.yover = 0;
            o.wp.reset();
            // Everything moves towards the target: start with "stay here".
            setTarget(o, o.center_x, o.center_y);
            o.is_running = false;
        }
        switch (wp.mode) {
            .move => try moveWaypoint(w, o, wp, dt, is_new, true),
            .force_move => try moveWaypoint(w, o, wp, dt, is_new, false),
            .dodge => try dodgeWaypoint(w, o, wp, dt, is_new),
            .enter => try enterWaypoint(w, o, wp, dt, is_new),
            .attack => {
                attack_player_given = wp.player_given;
                try attackWaypoint(w, o, wp, dt);
            },
            .agro => try agroWaypoint(w, o, wp, dt, is_new),
            .crane_repair => try craneRepairWaypoint(w, o, wp, dt, is_new),
            .unit_repair => try unitRepairWaypoint(w, o, wp, dt, is_new),
            .enter_fort => try enterFortWaypoint(w, o, wp, dt, is_new),
            .pickup_grenades => try pickupWaypoint(w, o, wp, dt, is_new),
            .none, _ => killWaypoint(w, o),
        }
    }

    try checkPassiveEngage(w, o);
    try processAttackDamage(w, o, attack_player_given);
}

/// Destroyed buildings rebuild themselves after a while, unless their
/// zone's fort is gone.
fn autoRepair(w: *World, o: *Object) bool {
    const at = o.auto_repair_time orelse return false;
    if (w.now() < at) return false;
    o.auto_repair_time = null;
    if (hasDestroyedFortInZone(w, o)) return false;
    w.setHealth(o, o.max_health);
    return true;
}

fn hasDestroyedFortInZone(w: *World, o: *const Object) bool {
    const zone = o.zone orelse return false;
    for (w.objects.items) |other| {
        if (other.zone == zone and other.isFort() and other.isDestroyed()) return true;
    }
    return false;
}

fn processStamina(w: *World, o: *Object, dt: f64) void {
    if (o.is_running) {
        o.stamina -= dt;
        if (o.stamina < 0) {
            o.stamina = 0;
            o.is_running = false;
        }
    } else {
        o.stamina = @min(o.stamina + dt * w.settings.run_recharge_rate, o.max_stamina);
    }
}

fn unitBuilt(w: *World, o: *Object) ?obj.Unit {
    const b = o.building() orelse return null;
    const u = b.unit orelse return null;
    if (b.state == .select or o.owner == .none) return null;
    if (w.now() < b.final_time or w.unit_limit_reached[@intFromEnum(o.owner)]) return null;
    return u;
}

fn processLid(w: *World, o: *Object) void {
    switch (o.kind) {
        .vehicle => |*v| if (v.close_lid_time) |ct| if (w.now() >= ct) {
            v.close_lid_time = null;
            v.lid_open = false;
            o.ev.updated_lid = true;
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Movement
// ---------------------------------------------------------------------------

fn setTarget(o: *Object, x: i32, y: i32) void {
    o.wp.x = x;
    o.wp.y = y;
    o.wp.sx = o.center_x;
    o.wp.sy = o.center_y;
    o.wp.adx = @intCast(@abs(x - o.center_x));
    o.wp.ady = @intCast(@abs(y - o.center_y));
}

/// At (or past) the current target; snaps onto it.
fn reachedTarget(o: *Object) bool {
    if (o.center_x == o.wp.x and o.center_y == o.wp.y) {
        o.xover = 0;
        o.yover = 0;
        return true;
    }
    if (@abs(o.center_x - o.wp.sx) >= o.wp.adx and @abs(o.center_y - o.wp.sy) >= o.wp.ady) {
        o.setPosition(o.wp.x - (o.width_pix >> 1), o.wp.y - (o.height_pix >> 1));
        o.xover = 0;
        o.yover = 0;
        return true;
    }
    return false;
}

/// Head for the current target, planning a path around obstacles.
fn planPath(w: *World, o: *Object) Error!void {
    o.wp.path.clearRetainingCapacity();
    o.wp.got_path = true;
    const path = try w.grid.?.findPath(w.gpa, o.x + 8, o.y + 8, o.wp.x, o.wp.y, o.isRobot(), hasExplosives(w, o)) orelse {
        w.setVelocity(o);
        return;
    };
    defer w.gpa.free(path);
    if (path.len == 0) {
        _ = w.stopMove(o);
        return;
    }
    setTarget(o, path[0].x, path[0].y);
    try o.wp.path.appendSlice(w.gpa, path[1..]);
    w.setVelocity(o);
}

/// Continue with the next point of the path, if any.
fn nextPathPoint(w: *World, o: *Object) bool {
    if (o.wp.path.items.len == 0) return false;
    const p = o.wp.path.orderedRemove(0);
    setTarget(o, p.x, p.y);
    w.setVelocity(o);
    return true;
}

fn damagedSpeed(w: *const World, o: *const Object) f64 {
    if (o.showPartiallyDamaged()) return w.settings.partially_damaged_unit_speed;
    if (o.showDamaged()) return w.settings.damaged_unit_speed;
    return 1.0;
}

fn runSpeed(w: *const World, o: *const Object) f64 {
    const running = if (w.findOpt(o.leader)) |l| l.is_running else o.is_running;
    return if (running and !o.showDamaged()) w.settings.run_unit_speed else 1.0;
}

/// Move by the velocity; returns the blocked tile if an obstacle is in
/// the way (only for stoppable moves).
fn processMove(w: *World, o: *Object, dt: f64, stoppable: bool) ?Point {
    if (obj.isZero(o.dx) and obj.isZero(o.dy)) return null;

    const nx = @as(f64, @floatFromInt(o.x)) + o.dx * dt + o.xover;
    const ny = @as(f64, @floatFromInt(o.y)) + o.dy * dt + o.yover;
    const inx: i32 = @intFromFloat(@floor(nx));
    const iny: i32 = @intFromFloat(@floor(ny));

    // Minions squeeze through anything their leader got past.
    if (stoppable and o.leader == null) {
        if (w.grid.?.withinImpassable(inx + 1, iny + 1, o.width_pix - 2, o.height_pix - 2, o.isRobot())) |stop| {
            return if (reachedTarget(o)) null else stop;
        }
    }

    // Robots can't shoot while walking.
    if (o.kind == .robot) _ = w.disengage(o);

    o.xover = nx - @as(f64, @floatFromInt(inx));
    o.yover = ny - @as(f64, @floatFromInt(iny));
    o.setPosition(inx, iny);

    const previous = o.real_move_speed;
    o.real_move_speed = @as(f64, @floatFromInt(o.move_speed)) * w.walkSpeed(o.center_x, o.center_y) * damagedSpeed(w, o) * runSpeed(w, o);
    if (o.real_move_speed != previous) {
        var dx: f64 = o.dx;
        var dy: f64 = o.dy;
        if (previous > 0) {
            dx /= previous;
            dy /= previous;
        }
        o.dx = @floatCast(dx * o.real_move_speed);
        o.dy = @floatCast(dy * o.real_move_speed);
        o.ev.updated_velocity = true;
    }
    return null;
}

/// Move; if blocked, attack the obstacle if possible or give up the
/// waypoint. Returns whether the waypoint goes on.
fn moveOrKillWaypoint(w: *World, o: *Object, dt: f64, stoppable: bool) Error!bool {
    const stop = processMove(w, o, dt, stoppable) orelse return true;
    if (!try attackImpassableAt(w, o, stop)) killWaypoint(w, o);
    return false;
}

fn killWaypoint(w: *World, o: *Object) void {
    o.ev.updated_waypoints = true;
    if (o.waypoints.items.len > 0) _ = o.waypoints.orderedRemove(0);
    _ = w.stopMove(o);
    o.last_wp = .{};
}

/// Whether new orders may replace the current waypoint.
fn canOverwriteWaypoint(o: *const Object) bool {
    if (o.waypoints.items.len == 0) return true;
    return switch (o.waypoints.items[0].mode) {
        .force_move => false,
        .crane_repair => stage(o, CraneStage) == .goto_entrance,
        .unit_repair => switch (stage(o, RepairStage)) {
            .goto_entrance, .wait => true,
            else => false,
        },
        .enter_fort => stage(o, FortStage) == .goto_entrance,
        else => true,
    };
}

fn attemptStartRun(w: *World, o: *Object, target: ?Point) void {
    const min_stamina = 0.3;
    if (target) |p| {
        const reach: i32 = @intFromFloat(@as(f64, @floatFromInt(o.move_speed)) * o.stamina);
        if (!withinDistance(o.center_x, o.center_y, p.x, p.y, reach)) return;
    }
    if (o.is_running) return;
    // One in five doesn't bother.
    if (w.randInt(5) == 0) return;
    if (o.stamina < min_stamina) return;
    o.is_running = true;
}

// ---------------------------------------------------------------------------
// Waypoints
// ---------------------------------------------------------------------------

fn moveWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool, stoppable: bool) Error!void {
    if (is_new) {
        setTarget(o, wp.x, wp.y);
        // Forced moves go straight to their target.
        if (stoppable) {
            try planPath(w, o);
        } else {
            w.setVelocity(o);
        }
        // Run for flags.
        for (w.objects.items) |f| {
            if (f.kind == .flag and f.distanceTo(wp.x, wp.y) <= 32) {
                attemptStartRun(w, o, .{ .x = wp.x, .y = wp.y });
                break;
            }
        }
    }
    if (try checkAttackTo(w, o, wp)) return;
    if (!o.wp.got_path and stoppable) return;
    if (!try moveOrKillWaypoint(w, o, dt, stoppable)) return;
    if (!reachedTarget(o)) return;
    if (!nextPathPoint(w, o)) killWaypoint(w, o);
}

fn dodgeWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool) Error!void {
    if (is_new) {
        setTarget(o, wp.x, wp.y);
        w.setVelocity(o);
        attemptStartRun(w, o, null);
    }
    if (!try moveOrKillWaypoint(w, o, dt, true)) return;
    if (reachedTarget(o)) killWaypoint(w, o);
}

fn enterWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool) Error!void {
    if (is_new) {
        setTarget(o, wp.x, wp.y);
        try planPath(w, o);
        attemptStartRun(w, o, .{ .x = wp.x, .y = wp.y });
    }
    const target = w.find(wp.ref_id) orelse return killWaypoint(w, o);
    if (!target.canBeEntered()) return killWaypoint(w, o);

    if (target.underPoint(o.center_x, o.center_y)) {
        killWaypoint(w, o);
        if (o.leader == null) o.ev.entered_target = target.ref_id;
        return;
    }
    if (try checkAttackTo(w, o, wp)) return;
    if (!o.wp.got_path) return;
    if (!try moveOrKillWaypoint(w, o, dt, true)) return;
    if (!reachedTarget(o)) return;
    if (!nextPathPoint(w, o)) killWaypoint(w, o);
}

fn pickupWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool) Error!void {
    if (!o.canPickupGrenades()) return killWaypoint(w, o);
    const box = w.find(wp.ref_id) orelse return killWaypoint(w, o);
    if (!box.isItem(.grenades)) return killWaypoint(w, o);

    if (box.underPoint(o.center_x, o.center_y)) {
        killWaypoint(w, o);
        if (o.leader == null) {
            o.ev.pickup_grenade_anim = true;
            o.ev.updated_grenades = true;
            o.grenades += box.grenades;
            box.grenades = 0;
            w.setHealth(box, 0);
            o.ev.delete_grenade_box = box.ref_id;
        }
        return;
    }
    if (is_new) {
        setTarget(o, wp.x, wp.y);
        try planPath(w, o);
        attemptStartRun(w, o, .{ .x = wp.x, .y = wp.y });
    }
    if (try checkAttackTo(w, o, wp)) return;
    if (!o.wp.got_path) return;
    if (!try moveOrKillWaypoint(w, o, dt, true)) return;
    if (!reachedTarget(o)) return;
    if (!nextPathPoint(w, o)) killWaypoint(w, o);
}

fn attackWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64) Error!void {
    const target = w.find(wp.ref_id) orelse return killWaypoint(w, o);
    if (!canAttackObject(w, o, target)) return killWaypoint(w, o);

    if (withinAttackRadius(w, o, target)) {
        _ = w.stopMove(o);
        w.engage(o, target);
        return;
    }

    // Hunt it down.
    if (!o.wp.got_path) {
        const spot = nearestAttackSpot(w, target, o.x, o.y, o.attack_radius, o.isRobot()) orelse
            Point{ .x = target.x + 8, .y = target.y + 8 };
        setTarget(o, spot.x, spot.y);
        // To notice when the target has moved away.
        o.wp.init_attack_x = spot.x;
        o.wp.init_attack_y = spot.y;
        try planPath(w, o);
        return;
    }
    if (@abs(target.center_x - o.wp.init_attack_x) > o.attack_radius or
        @abs(target.center_y - o.wp.init_attack_y) > o.attack_radius)
    {
        // Moved too far: plan again.
        _ = w.stopMove(o);
        o.wp.reset();
        return;
    }
    w.setVelocity(o);
    if (!try moveOrKillWaypoint(w, o, dt, true)) return;
    if (!reachedTarget(o)) return;
    if (!nextPathPoint(w, o)) {
        _ = w.stopMove(o);
        o.wp.reset();
    }
}

/// A target found by the unit itself: chase it, but not too far from
/// where the chase started.
fn agroWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool) Error!void {
    if (is_new) {
        o.wp.agro_center_x = o.center_x;
        o.wp.agro_center_y = o.center_y;
        setStage(o, AgroStage.attack);
    }
    const target = w.find(wp.ref_id) orelse return killWaypoint(w, o);
    if (!canAttackObject(w, o, target)) return killWaypoint(w, o);

    const tx = target.center_x;
    const ty = target.center_y;
    const leash = o.attack_radius + w.settings.agro_distance;
    if (!withinDistance(tx, ty, o.wp.agro_center_x, o.wp.agro_center_y, leash)) {
        if (stage(o, AgroStage) != .back_to_center) {
            setStage(o, AgroStage.back_to_center);
            setTarget(o, o.wp.agro_center_x, o.wp.agro_center_y);
            w.setVelocity(o);
        }
    } else if (stage(o, AgroStage) != .attack) {
        setStage(o, AgroStage.attack);
        setTarget(o, tx, ty);
        w.setVelocity(o);
    }

    switch (stage(o, AgroStage)) {
        .attack => if (withinAttackRadius(w, o, target)) {
            _ = w.stopMove(o);
            w.engage(o, target);
        } else {
            setTarget(o, tx, ty);
            w.setVelocity(o);
            _ = try moveOrKillWaypoint(w, o, dt, true);
        },
        .back_to_center => {
            if (!try moveOrKillWaypoint(w, o, dt, true)) return;
            if (reachedTarget(o)) killWaypoint(w, o);
        },
    }
}

fn buildingTarget(w: *World, ref_id: i32) ?*Object {
    const b = w.find(ref_id) orelse return null;
    return if (b.kind == .building) b else null;
}

/// Walk into an enemy fort to blow it up.
fn enterFortWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool) Error!void {
    const fort = buildingTarget(w, wp.ref_id) orelse return killWaypoint(w, o);

    if (is_new) {
        setStage(o, FortStage.goto_entrance);
        const entrance = fort.creationMovePoint() orelse return killWaypoint(w, o);
        o.wp.fort_exit_x = entrance.x;
        o.wp.fort_exit_y = entrance.y;
        setTarget(o, entrance.x, entrance.y);
        try planPath(w, o);
    }

    if (!fort.canEnterFort(o.owner)) switch (stage(o, FortStage)) {
        .goto_entrance => return killWaypoint(w, o),
        .enter => {
            // It blew up while we were going in: back out.
            setTarget(o, o.wp.fort_exit_x, o.wp.fort_exit_y);
            setStage(o, FortStage.exit);
            w.setVelocity(o);
        },
        .exit => {},
    };

    if (try checkAttackTo(w, o, wp)) return;
    if (!o.wp.got_path) return;
    if (!try moveOrKillWaypoint(w, o, dt, stage(o, FortStage) == .goto_entrance)) return;
    if (!reachedTarget(o)) return;

    switch (stage(o, FortStage)) {
        .goto_entrance => if (!nextPathPoint(w, o)) {
            const inside = fort.creationPoint() orelse return killWaypoint(w, o);
            setTarget(o, inside.x, inside.y);
            w.setVelocity(o);
            setStage(o, FortStage.enter);
        },
        .enter => {
            setTarget(o, o.wp.fort_exit_x, o.wp.fort_exit_y);
            setStage(o, FortStage.exit);
            o.ev.destroy_fort = fort.ref_id;
            w.setVelocity(o);
        },
        .exit => killWaypoint(w, o),
    }
}

/// A crane drives into a destroyed building, which then rebuilds itself.
fn craneRepairWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool) Error!void {
    const building = buildingTarget(w, wp.ref_id) orelse return killWaypoint(w, o);

    if (is_new) {
        setStage(o, CraneStage.goto_entrance);
        const entrances = building.craneEntrance() orelse return killWaypoint(w, o);
        // Bridges have an entrance at each end: take the closer one.
        const e = if (o.distanceTo(entrances[0].x, entrances[0].y) < o.distanceTo(entrances[1].x, entrances[1].y))
            entrances[0]
        else
            entrances[1];
        setTarget(o, e.x, e.y);
        o.wp.crane_exit_x = e.x;
        o.wp.crane_exit_y = e.y;
        try planPath(w, o);
    }

    if (!building.canBeRepairedByCrane(o.owner)) switch (stage(o, CraneStage)) {
        .goto_entrance => return killWaypoint(w, o),
        .enter => {
            // Repaired by someone else meanwhile: back out.
            setTarget(o, o.wp.crane_exit_x, o.wp.crane_exit_y);
            setStage(o, CraneStage.exit);
            w.setVelocity(o);
        },
        .exit => {},
    };

    if (!o.wp.got_path) return;
    if (!try moveOrKillWaypoint(w, o, dt, stage(o, CraneStage) == .goto_entrance)) return;
    if (!reachedTarget(o)) return;

    switch (stage(o, CraneStage)) {
        .goto_entrance => if (!nextPathPoint(w, o)) {
            const center = building.craneCenter() orelse return killWaypoint(w, o);
            setStage(o, CraneStage.enter);
            setTarget(o, center.x, center.y);
            w.setVelocity(o);
            o.ev.crane_anim = .{ .on = true, .building = building.ref_id };
        },
        .enter => {
            setTarget(o, o.wp.crane_exit_x, o.wp.crane_exit_y);
            w.setVelocity(o);
            setStage(o, CraneStage.exit);
        },
        .exit => {
            // Repair right away.
            building.auto_repair_time = 0;
            o.ev.crane_anim = .{ .on = false, .building = building.ref_id };
            killWaypoint(w, o);
        },
    }
}

/// A damaged unit drives into a repair station (waiting its turn).
fn unitRepairWaypoint(w: *World, o: *Object, wp: Waypoint, dt: f64, is_new: bool) Error!void {
    const station = buildingTarget(w, wp.ref_id) orelse return killWaypoint(w, o);

    if (is_new) {
        setStage(o, RepairStage.goto_entrance);
        const e = station.repairEntrance() orelse return killWaypoint(w, o);
        setTarget(o, e.x, e.y);
        try planPath(w, o);
    }

    if (!station.canRepairUnit(o.owner) or !o.canBeRepaired()) {
        // If we were going in we must come out.
        if (stage(o, RepairStage) != .enter) return killWaypoint(w, o);
        const e = station.repairEntrance() orelse return killWaypoint(w, o);
        setTarget(o, e.x, e.y);
        setStage(o, RepairStage.exit);
        w.setVelocity(o);
    }

    if (try checkAttackTo(w, o, wp)) return;
    if (!o.wp.got_path) return;

    // Someone else is being repaired: wait, or come back out.
    if (station.repairingAUnit()) switch (stage(o, RepairStage)) {
        .enter => {
            const e = station.repairEntrance() orelse return killWaypoint(w, o);
            setTarget(o, e.x, e.y);
            setStage(o, RepairStage.exit);
            w.setVelocity(o);
        },
        .wait => return,
        else => {},
    };

    const stoppable = switch (stage(o, RepairStage)) {
        .enter, .exit => false,
        else => true,
    };
    if (!try moveOrKillWaypoint(w, o, dt, stoppable)) return;
    if (!reachedTarget(o)) return;

    switch (stage(o, RepairStage)) {
        .goto_entrance => if (!nextPathPoint(w, o)) {
            setStage(o, RepairStage.wait);
            w.setVelocity(o);
        },
        .exit => {
            setStage(o, RepairStage.wait);
            w.setVelocity(o);
        },
        .enter => {
            o.ev.entered_repair = station.ref_id;
            // Back out if the station doesn't take us after all (another
            // unit entered at the same moment).
            const e = station.repairEntrance() orelse return killWaypoint(w, o);
            setTarget(o, e.x, e.y);
            setStage(o, RepairStage.exit);
            w.setVelocity(o);
        },
        .wait => {
            const center = station.repairCenter() orelse return killWaypoint(w, o);
            setStage(o, RepairStage.enter);
            setTarget(o, center.x, center.y);
            w.setVelocity(o);
        },
    }
}

/// With "attack to" orders, go for enemies met on the way.
fn checkAttackTo(w: *World, o: *Object, wp: Waypoint) Error!bool {
    if (!wp.attack_to or !canOverwriteWaypoint(o)) return false;

    var choices: std.ArrayList(*Object) = .empty;
    defer choices.deinit(w.gpa);
    for (w.objects.items) |other| {
        if (!other.isUnit() or other.owner == .none or other.owner == o.owner) continue;
        if (withinAgroRadius(w, o, other)) try choices.append(w.gpa, other);
    }
    if (choices.items.len == 0) return false;

    const choice = choices.items[@intCast(w.randInt(@intCast(choices.items.len)))];
    try o.waypoints.insert(w.gpa, 0, .{ .mode = .attack, .ref_id = choice.ref_id, .x = choice.center_x, .y = choice.center_y });
    return true;
}

/// Blocked by a rock or similar that explosives can clear: attack it.
fn attackImpassableAt(w: *World, o: *Object, p: Point) Error!bool {
    if (!hasExplosives(w, o)) return false;
    for (w.objects.items) |other| {
        if (!other.isDestroyableImpass() or !other.causesImpassAt(p.x, p.y)) continue;
        if (!canAttackObject(w, o, other)) continue;
        try o.waypoints.insert(w.gpa, 0, .{ .mode = .attack, .ref_id = other.ref_id, .x = other.center_x, .y = other.center_y });
        try w.cloneMinionWaypoints(o);
        return true;
    }
    return false;
}

/// Where to stand to attack `target` from (sx, sy).
fn nearestAttackSpot(w: *World, target: *const Object, sx: i32, sy: i32, radius: i32, is_robot: bool) ?Point {
    const g = &w.grid.?;
    const cx = target.center_x;
    const cy = target.center_y;
    if (g.shouldBeAbleToMoveTo(sx, sy, cx, cy, is_robot)) return .{ .x = cx, .y = cy };

    // Around a fort's cannons: its top-left tile, above, right or left.
    const candidates = [_]Point{
        .{ .x = target.x + 8, .y = target.y + 8 },
        .{ .x = target.x + 8, .y = target.y + 8 - 32 },
        .{ .x = target.x + 8 + 48, .y = target.y + 8 },
        .{ .x = target.x + 8 - 48, .y = target.y + 8 },
    };
    for (candidates) |c| {
        if (c.x != cx and c.y != cy and g.shouldBeAbleToMoveTo(sx, sy, c.x, c.y, is_robot)) return c;
    }

    // Along the line towards the attacker, within range.
    const m = w.map.?;
    var line = pathfinding.Line.init(cx >> 4, cy >> 4, sx >> 4, sy >> 4, m.header.width, m.header.height);
    while (line.next()) |tile| {
        const e = Point{ .x = (tile.x << 4) + 8, .y = (tile.y << 4) + 8 };
        if (!withinDistance(cx, cy, e.x, e.y, radius)) break;
        if (g.shouldBeAbleToMoveTo(sx, sy, e.x, e.y, is_robot)) return e;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Combat
// ---------------------------------------------------------------------------

fn withinDistance(x1: i32, y1: i32, x2: i32, y2: i32, distance: i32) bool {
    const dx: i64 = x1 - x2;
    const dy: i64 = y1 - y2;
    const d: i64 = distance;
    return dx * dx + dy * dy <= d * d;
}

fn hasExplosives(w: *const World, o: *const Object) bool {
    return o.hasExplosives(w.findOpt(o.leader));
}

pub fn canAttackObject(w: *const World, o: *const Object, target: *const Object) bool {
    if (!o.canAttack() or target.isDestroyed() or o.owner == target.owner) return false;
    return hasExplosives(w, o) or !target.attacked_by_explosives;
}

fn inRange(w: *const World, o: *const Object, target: *const Object, radius: i32) bool {
    if (!withinDistance(o.center_x, o.center_y, target.center_x, target.center_y, radius)) return false;
    if (target.isDestroyableImpass()) return true;
    const grid = w.grid orelse return true;
    return !grid.engageBarrierBetween(o.center_x, o.center_y, target.center_x, target.center_y);
}

fn withinAttackRadius(w: *const World, o: *const Object, target: *const Object) bool {
    return inRange(w, o, target, o.attack_radius);
}

pub fn withinAgroRadius(w: *const World, o: *const Object, target: *const Object) bool {
    return inRange(w, o, target, o.attack_radius + w.settings.agro_distance);
}

fn closest(o: *const Object, choices: []const *Object) ?*Object {
    var best: ?*Object = null;
    var best_distance: f64 = 0;
    for (choices) |c| {
        const d = o.distanceToObject(c);
        if (best == null or d < best_distance) {
            best = c;
            best_distance = d;
        }
    }
    return best;
}

/// Twice a second idle units look around: attack enemies in range, chase
/// ones close by, or wander off to enter empty vehicles, grab flags and
/// pick up grenades.
fn checkPassiveEngage(w: *World, o: *Object) Error!void {
    const t = w.now();
    if (t < o.next_passive_check_time) return;
    o.next_passive_check_time = t + 0.5;

    if (!o.canAttack() or o.owner == .none or !o.isUnit()) return;
    if (o.kind == .robot and o.isMoving()) return;

    if (w.findOpt(o.attack_target)) |target| {
        if (!withinAttackRadius(w, o, target)) _ = w.disengage(o);
        return;
    } else if (o.attack_target != null) {
        _ = w.disengage(o);
        return;
    }

    const gpa = w.gpa;
    var agro: std.ArrayList(*Object) = .empty;
    defer agro.deinit(gpa);
    var vehicles: std.ArrayList(*Object) = .empty;
    defer vehicles.deinit(gpa);
    var flags: std.ArrayList(*Object) = .empty;
    defer flags.deinit(gpa);
    var grenades: std.ArrayList(*Object) = .empty;
    defer grenades.deinit(gpa);

    const idle = o.waypoints.items.len == 0 and o.kind != .cannon;
    for (w.objects.items) |other| {
        if (!other.isUnit()) continue;
        if (other.owner != .none and other.owner != o.owner and canAttackObject(w, o, other)) {
            if (withinAttackRadius(w, o, other)) {
                w.engage(o, other);
                return;
            }
            if (idle and withinAgroRadius(w, o, other)) try agro.append(gpa, other);
        }
        if (idle and o.leader == null and agro.items.len == 0) {
            if (o.kind == .robot and other.canBeEntered() and
                withinDistance(o.center_x, o.center_y, other.center_x, other.center_y, w.settings.auto_grab_vehicle_distance) and
                !other.isVehicle(.apc) and !(o.just_left_cannon and other.kind == .cannon))
            {
                try vehicles.append(gpa, other);
            }
        }
    }

    if (o.leader == null and agro.items.len == 0 and o.waypoints.items.len == 0) {
        for (w.objects.items) |other| {
            const radius = switch (other.kind) {
                .flag => if (o.canMove() and other.owner != o.owner) w.settings.auto_grab_flag_distance else continue,
                .item => |item| if (item == .grenades and o.canPickupGrenades()) w.settings.auto_grab_vehicle_distance else continue,
                else => continue,
            };
            if (!withinDistance(o.center_x, o.center_y, other.center_x, other.center_y, radius)) continue;
            try (if (other.kind == .flag) &flags else &grenades).append(gpa, other);
        }
    }

    if (closest(o, agro.items)) |target| {
        try o.waypoints.append(gpa, .{ .mode = .agro, .ref_id = target.ref_id, .x = target.center_x, .y = target.center_y });
        return;
    }

    // Pick one of the kinds of things to go for at random.
    const Kind = struct { list: []const *Object, mode: obj.WaypointMode };
    var kinds: [3]Kind = undefined;
    var n: usize = 0;
    for ([_]Kind{
        .{ .list = vehicles.items, .mode = .enter },
        .{ .list = flags.items, .mode = .move },
        .{ .list = grenades.items, .mode = .pickup_grenades },
    }) |kind| {
        if (kind.list.len == 0) continue;
        kinds[n] = kind;
        n += 1;
    }
    if (n == 0) return;
    const kind = kinds[@intCast(w.randInt(@intCast(n)))];
    const choice = closest(o, kind.list).?;
    try o.waypoints.append(gpa, .{ .mode = kind.mode, .ref_id = choice.ref_id, .x = choice.center_x, .y = choice.center_y, .attack_to = true });
    try w.cloneMinionWaypoints(o);
}

fn randomChance(w: *World) f64 {
    return @as(f64, @floatFromInt(w.randInt(10000))) / 10000.0;
}

fn explodeTime(from: Point, to: Point, speed: i32, now: f64) f64 {
    if (speed <= 0) return now;
    const dx: f32 = @floatFromInt(to.x - from.x);
    const dy: f32 = @floatFromInt(to.y - from.y);
    return now + @as(f64, @sqrt(dx * dx + dy * dy)) / @as(f64, @floatFromInt(speed));
}

/// Shoot at the attack target when the weapon is ready.
fn processAttackDamage(w: *World, o: *Object, attack_player_given: bool) Error!void {
    const target_id = o.attack_target orelse return;
    if (o.damage == 0) return;
    const t = w.now();
    if (t < o.next_damage_time) return;
    o.next_damage_time = t + o.damage_interval;

    const target = w.find(target_id) orelse {
        _ = w.disengage(o);
        return;
    };
    if (!canAttackObject(w, o, target)) {
        _ = w.disengage(o);
        return;
    }

    const leader = w.findOpt(o.leader);
    const with_grenades = o.grenades > 0 or (leader != null and leader.?.grenades > 0);
    const center = Point{ .x = o.center_x, .y = o.center_y };

    if (o.damage_is_missile or with_grenades) {
        var aim = estimateMissileTarget(o, target) orelse Point{ .x = target.center_x, .y = target.center_y };
        var missile: DamageMissile = undefined;
        if (with_grenades) {
            aim.x += w.randInt(48) - 24;
            aim.y += w.randInt(48) - 24;
            missile = .{
                .x = aim.x,
                .y = aim.y,
                .damage = @intFromFloat(w.settings.grenade_damage * k.max_unit_health),
                .radius = w.settings.grenade_damage_radius,
                .team = o.owner,
                .attacker = o.ref_id,
                .attack_player_given = attack_player_given,
                .target = target.ref_id,
                .explode_time = explodeTime(center, aim, w.settings.grenade_missile_speed, t),
            };
            if (o.grenades > 0) {
                o.grenades -= 1;
                o.ev.updated_grenades = true;
            } else {
                leader.?.grenades -= 1;
                o.ev.updated_leader_grenades = true;
            }
            o.next_damage_time = t + w.settings.grenade_attack_speed;
        } else {
            aim.x += w.randInt(32) - 16;
            aim.y += w.randInt(32) - 16;
            missile = .{
                .x = aim.x,
                .y = aim.y,
                .damage = o.damage,
                .radius = o.damage_radius,
                .team = o.owner,
                .attacker = o.ref_id,
                .attack_player_given = attack_player_given,
                .target = target.ref_id,
                .explode_time = explodeTime(center, aim, o.missile_speed, t),
            };
        }
        try w.fireMissile(missile);
        o.ev.fired_missile = aim;
        try dodgeMissile(w, target, missile.explode_time - t);
        return;
    }

    if (randomChance(w) > o.damage_chance) return;
    // Hit the vehicle or its driver?
    if (o.can_snipe and target.canBeSniped() and randomChance(w) <= o.snipe_chance) {
        _ = w.damageDriverHealth(target, o.damage);
        o.ev.attack_target_driver_health = true;
    } else {
        w.damageHealth(target, o.damage);
        o.ev.attack_target_health = true;
    }
    // Victims of pyros melt.
    if (o.kind == .robot and o.kind.robot == .pyro) target.damaged_by_fire_time = t;
    if (target.isDestroyed() and attack_player_given) o.ev.portrait_anim = .target_destroyed;
}

/// Where to aim a missile so it meets a moving target.
fn estimateMissileTarget(o: *const Object, target: *const Object) ?Point {
    if (o.missile_speed <= 0) return null;
    if (obj.isZero(target.dx) and obj.isZero(target.dy)) return null;

    const dx: f64 = target.dx;
    const dy: f64 = target.dy;
    const xo: f64 = @floatFromInt(target.center_x);
    const yo: f64 = @floatFromInt(target.center_y);
    const speed: f64 = @floatFromInt(o.missile_speed);
    const cu = yo - @as(f64, @floatFromInt(o.center_y));
    const cd = xo - @as(f64, @floatFromInt(o.center_x));

    // Solve for the missile's velocity (dx2, dy2) with |v| = speed that
    // meets the target's line of travel.
    const a = cu * cu + cd * cd;
    const b = 2 * cu * cd * dy - 2 * cu * cu * dx;
    const c = cd * cd * dy * dy - 2 * cu * cd * dx + cu * cu * dx * dx - cd * cd * speed * speed;
    const d = b * b - 4 * a * c;
    if (d <= 0.00001 or obj.isZero(a)) return null;

    const roots = [2]f64{ (-b - @sqrt(d)) / (2 * a), (-b + @sqrt(d)) / (2 * a) };
    for (roots) |dx2| {
        const guts = speed * speed - dx2 * dx2;
        if (guts <= 0.00001) continue;
        const dy2 = @sqrt(guts);
        const time = if (!obj.isZero(dx - dx2))
            -cd / (dx - dx2)
        else if (!obj.isZero(dy - dy2))
            -cu / (dy - dy2)
        else
            continue;
        if (time < 0) continue;
        const tx = dx * time + xo;
        const ty = dy * time + yo;
        if (!std.math.isFinite(tx) or !std.math.isFinite(ty) or @abs(tx) > 1e6 or @abs(ty) > 1e6) return null;
        return .{ .x = @intFromFloat(tx), .y = @intFromFloat(ty) };
    }
    return null;
}

/// Step out of the way of an incoming missile.
fn dodgeMissile(w: *World, o: *Object, time_till_explode: f64) Error!void {
    if (!canOverwriteWaypoint(o)) return;
    if (o.move_speed <= 0 or o.real_move_speed <= 0) return;
    if (o.kind == .robot and o.attack_target != null) return;
    if (o.owner == .none) return;

    var distance = time_till_explode * o.real_move_speed;
    if (time_till_explode <= o.stamina) distance *= w.settings.run_unit_speed;
    const min: i32 = @intFromFloat(distance);
    const extra: i32 = @max(@as(i32, @intFromFloat(distance * 0.5)), 1);
    const move: f64 = @floatFromInt(min + w.randInt(extra));
    const theta = w.random().float(f64) * 2 * std.math.pi;
    const nx = o.center_x + @as(i32, @intFromFloat(move * @cos(theta)));
    const ny = o.center_y + @as(i32, @intFromFloat(move * @sin(theta)));

    if (o.waypoints.items.len > 0 and o.waypoints.items[0].mode == .dodge) {
        // Changing it makes it a new waypoint.
        o.waypoints.items[0].x = nx;
        o.waypoints.items[0].y = ny;
    } else {
        try o.waypoints.insert(w.gpa, 0, .{ .mode = .dodge, .ref_id = -1, .x = nx, .y = ny });
    }
}

// ---------------------------------------------------------------------------
// Applying and reporting the results
// ---------------------------------------------------------------------------

fn report(w: *World, o: *Object) Error!void {
    const ev = o.ev;

    if (ev.entered_target) |id| if (w.find(id)) |target| try w.robotEnterObject(o, target);
    if (ev.auto_repaired) {
        // Revive it on the clients.
        o.processed_death = false;
        try w.updateObjectHealth(o, null);
    }
    if (ev.updated_velocity) try w.relayLocation(o);
    if (ev.updated_waypoints) {
        try w.relayWaypoints(o);
        try w.cloneMinionWaypoints(o);
    }
    if (ev.updated_attack_target) try w.relayAttackTarget(o);
    if (ev.attack_target_health) if (w.findOpt(o.attack_target)) |t| try w.updateObjectHealth(t, o.ref_id);
    if (ev.attack_target_driver_health) if (w.findOpt(o.attack_target)) |t| try w.updateObjectDriverHealth(t);
    if (ev.destroy_fort) |id| if (w.find(id)) |fort| {
        w.setHealth(fort, 0);
        try w.updateObjectHealth(fort, null);
    };
    if (ev.fired_missile) |p| try w.sendPacket(.all, .fire_missile, protocol.FireMissile{ .ref_id = o.ref_id, .x = p.x, .y = p.y });
    if (ev.build_unit) |u| {
        _ = try w.buildingCreateUnit(o, u);
        w.resetProduction(o);
        try w.relayBuildingState(o, .all);
    }
    if (ev.repair_done) {
        const b = o.building().?;
        var job = b.repair.?;
        b.repair = null;
        defer job.deinit(w.gpa);
        _ = try w.buildingRepairUnit(o, &job);
        try w.relayBuildingState(o, .all);
    }
    if (ev.crane_anim) |a| try w.sendPacket(.all, .do_crane_anim, protocol.CraneAnim{ .ref_id = o.ref_id, .rep_ref_id = a.building, .on = a.on });
    if (ev.entered_repair) |id| if (w.find(id)) |station| try w.unitEnterRepairBuilding(o, station);
    if (ev.updated_lid) switch (o.kind) {
        .vehicle => |v| try w.sendPacket(.all, .set_lid_open, protocol.SetLidState{ .ref_id = o.ref_id, .lid_open = v.lid_open }),
        else => {},
    };
    if (ev.updated_grenades) try w.relayGrenadeAmount(o, .all);
    if (ev.pickup_grenade_anim) try w.sendPacket(.all, .pickup_grenade_anim, protocol.Int{ .value = o.ref_id });
    if (ev.updated_leader_grenades) if (w.findOpt(o.leader)) |l| try w.relayGrenadeAmount(l, .all);
    if (ev.delete_grenade_box) |id| if (w.find(id)) |box| {
        w.setHealth(box, 0);
        try w.updateObjectHealth(box, null);
    };
    if (ev.portrait_anim) |a| try w.relayPortraitAnim(o.ref_id, a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const mapfmt = @import("map.zig");

test "missile lead and distances" {
    try testing.expect(withinDistance(0, 0, 3, 4, 5));
    try testing.expect(!withinDistance(0, 0, 3, 4, 4));

    var shooter = Object.init(0, .cannon, @intFromEnum(k.Cannon.gatling), &@import("settings.zig").Settings.defaults, .{}).?;
    defer shooter.deinit(testing.allocator);
    var target = Object.init(1, .vehicle, @intFromEnum(k.Vehicle.jeep), &@import("settings.zig").Settings.defaults, .{}).?;
    defer target.deinit(testing.allocator);
    shooter.missile_speed = 100;
    shooter.setPosition(0, 0);
    target.setPosition(200, 0);
    // A still target is aimed at directly.
    try testing.expect(estimateMissileTarget(&shooter, &target) == null);
    // One moving down is led.
    target.dy = 30;
    const aim = estimateMissileTarget(&shooter, &target).?;
    try testing.expectEqual(target.center_x, aim.x);
    try testing.expect(aim.y > target.center_y);
}

test "a game runs: units move, fight and production continues" {
    const io = testing.io;
    const gpa = testing.allocator;
    const terrain = try gpa.create(mapfmt.Terrain);
    defer gpa.destroy(terrain);
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    terrain.* = try mapfmt.Terrain.load(io, assets);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "Data/Campaing/Z_original/p02_bb_orig01.map", gpa, .limited(1 << 20));
    defer gpa.free(bytes);

    var w = World.init(gpa, terrain, 42);
    defer w.deinit();
    try w.loadMap(bytes);

    // Send every unit of one team to the other team's fort.
    var red_fort: ?*Object = null;
    var blue_fort: ?*Object = null;
    for (w.objects.items) |o| if (o.isFort()) {
        if (o.owner == .red) red_fort = o;
        if (o.owner == .blue) blue_fort = o;
    };
    const goal = blue_fort orelse red_fort.?;
    const attacker_team: k.Team = if (goal.owner == .blue) .red else .blue;
    var ordered: usize = 0;
    for (w.objects.items) |o| {
        if (o.owner != attacker_team or !o.canMove() or o.leader != null) continue;
        const orders = [_]Waypoint{.{ .mode = .move, .x = goal.center_x, .y = goal.center_y + 64, .attack_to = true, .player_given = true }};
        if (try setOrders(&w, o, attacker_team, &orders)) ordered += 1;
    }
    try testing.expect(ordered > 0);

    // Two minutes of game time in 10ms steps.
    var moved = false;
    var fired = false;
    for (0..12000) |_| {
        w.clock.ztime += 0.01;
        try step(&w);
        for (w.outbox.items) |m| {
            if (m.id == .send_loc) moved = true;
            if (m.id == .fire_missile or m.id == .update_health) fired = true;
            gpa.free(m.payload);
        }
        w.outbox.clearRetainingCapacity();
    }
    try testing.expect(moved);
    try testing.expect(fired);
    // Lookups still work after deletions and additions.
    for (w.objects.items, 0..) |o, i| {
        if (i > 0) try testing.expect(o.ref_id > w.objects.items[i - 1].ref_id);
    }
}
