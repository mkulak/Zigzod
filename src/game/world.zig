//! The game world as the server runs it: objects, map, zones, missiles and
//! the rules that tie them together (from ZServer/ZCore in
//! QZod_DnClientServer).
//!
//! Every change other peers must hear about is encoded as a protocol
//! message and queued in `outbox`; the server sends them (to everyone, a
//! team or one player) after each step.

const std = @import("std");
const fit = @import("../text.zig").fit;
const k = @import("constants.zig");
const Settings = @import("settings.zig").Settings;
const mapfmt = @import("map.zig");
const pathfinding = @import("pathfinding.zig");
const buildlist = @import("buildlist.zig");
const obj = @import("object.zig");
const protocol = @import("../net/protocol.zig");
const Clock = @import("clock.zig").Clock;
const damage = @import("world/damage.zig");
const missiles = @import("world/missiles.zig");
const production = @import("world/production.zig");
const relay = @import("world/relay.zig");

pub const Error = std.mem.Allocator.Error;
pub const Object = obj.Object;
pub const Waypoint = obj.Waypoint;
pub const Point = pathfinding.Point;

pub const CompSound = protocol.CompSound;
pub const PortraitAnim = protocol.PortraitAnim;

pub const Audience = union(enum) {
    all,
    team: k.Team,
    /// A connection id (see server.zig).
    player: i32,
};

pub const Outgoing = struct {
    to: Audience,
    id: protocol.Message,
    payload: []u8,
};

/// An explosion that will happen at `explode_time`.
pub const DamageMissile = struct {
    x: i32,
    y: i32,
    damage: i32,
    radius: i32,
    /// Units of this team are not hurt (none: everyone is).
    team: k.Team = .none,
    explode_time: f64,
    attacker: ?i32 = null,
    attack_player_given: bool = false,
    target: ?i32 = null,
};

pub const World = struct {
    gpa: std.mem.Allocator,
    settings: Settings = Settings.defaults,
    terrain: *const mapfmt.Terrain,
    /// Currently loaded map and its file contents (sent to clients).
    map: ?mapfmt.Map = null,
    map_bytes: []u8 = &.{},
    grid: ?pathfinding.Grid = null,
    zones: std.ArrayList(mapfmt.Zone) = .empty,

    /// All objects, sorted by ref id.
    objects: std.ArrayList(*Object) = .empty,
    /// Units produced during a step, added after it.
    new_objects: std.ArrayList(*Object) = .empty,
    next_ref_id: i32 = 0,

    clock: Clock = .{},
    missiles: std.ArrayList(DamageMissile) = .empty,
    new_missiles: std.ArrayList(DamageMissile) = .empty,
    outbox: std.ArrayList(Outgoing) = .empty,
    rng: std.Random.DefaultPrng,

    max_units_per_team: i32 = k.default_max_units_per_team,
    unit_limit_reached: [k.Team.count]bool = @splat(false),
    team_zone_percentage: [k.Team.count]f32 = @splat(0),

    next_scuffle_time: f64 = 0,
    next_flag_check_time: f64 = 0,

    pub fn init(gpa: std.mem.Allocator, terrain: *const mapfmt.Terrain, seed: u64) World {
        return .{ .gpa = gpa, .terrain = terrain, .rng = .init(seed) };
    }

    pub fn deinit(w: *World) void {
        w.clear();
        w.objects.deinit(w.gpa);
        w.new_objects.deinit(w.gpa);
        w.zones.deinit(w.gpa);
        w.missiles.deinit(w.gpa);
        w.new_missiles.deinit(w.gpa);
        for (w.outbox.items) |m| w.gpa.free(m.payload);
        w.outbox.deinit(w.gpa);
    }

    /// Remove the map and all objects.
    pub fn clear(w: *World) void {
        for (w.objects.items) |o| w.destroyObject(o);
        w.objects.clearRetainingCapacity();
        for (w.new_objects.items) |o| w.destroyObject(o);
        w.new_objects.clearRetainingCapacity();
        w.missiles.clearRetainingCapacity();
        w.new_missiles.clearRetainingCapacity();
        w.zones.clearRetainingCapacity();
        if (w.map) |*m| m.deinit(w.gpa);
        w.map = null;
        w.gpa.free(w.map_bytes);
        w.map_bytes = &.{};
        if (w.grid) |*g| g.deinit(w.gpa);
        w.grid = null;
    }

    fn destroyObject(w: *World, o: *Object) void {
        o.deinit(w.gpa);
        w.gpa.destroy(o);
    }

    pub fn random(w: *World) std.Random {
        return w.rng.random();
    }

    /// `rand() % n` (0 for n <= 0).
    pub fn randInt(w: *World, n: i32) i32 {
        if (n <= 0) return 0;
        return w.random().intRangeLessThan(i32, 0, n);
    }

    pub fn now(w: *const World) f64 {
        return w.clock.ztime;
    }

    // -----------------------------------------------------------------------
    // Loading a map
    // -----------------------------------------------------------------------

    /// Replace the world with the map in `bytes` and its objects.
    pub fn loadMap(w: *World, bytes: []const u8) !void {
        try w.setMap(bytes);
        try w.placeObjects();
    }

    /// Replace the world with the map in `bytes`, without objects (clients
    /// get those from the server).
    pub fn setMap(w: *World, bytes: []const u8) !void {
        w.clear();
        var m = try mapfmt.Map.parse(w.gpa, bytes);
        errdefer m.deinit(w.gpa);
        w.map_bytes = try w.gpa.dupe(u8, bytes);
        w.grid = try pathfinding.Grid.fromMap(w.gpa, &m, w.terrain);
        for (m.zones, 0..) |z, i| try w.zones.append(w.gpa, mapfmt.Zone.fromRect(@intCast(i), z));
        w.map = m;
    }

    /// Create the objects the map places, and set up zones and production.
    fn placeObjects(w: *World) !void {
        for (w.map.?.placements) |p| {
            if (!placementOk(p)) continue;
            const x = @as(i32, p.x) * 16;
            const y = @as(i32, p.y) * 16;
            const team = p.team();
            const ot: k.ObjectType = @enumFromInt(p.object_type);
            if (ot == .robot) {
                _ = try w.createRobotGroup(@enumFromInt(p.object_id), x, y, team, .direct, null, p.health_percent);
            } else {
                _ = try w.createObject(ot, p.object_id, x, y, team, .direct, .{
                    .level = @intCast(@max(p.blevel, 0)),
                    .extra_links = p.extra_links,
                    .health_percent = p.health_percent,
                });
            }
        }
        w.makeFortTurretsUnejectable();
        try w.initZones();
    }

    fn placementOk(p: mapfmt.Placement) bool {
        const ot = p.object_type;
        const max: u8 = switch (@as(k.ObjectType, @enumFromInt(ot))) {
            .building => k.Building.count,
            .cannon => k.Cannon.count,
            .vehicle => k.Vehicle.count,
            .robot => k.Robot.count,
            .map_item => k.Item.count,
            else => return false,
        };
        if (p.object_id >= max) return false;
        if (p.owner < 0 or p.owner >= k.Team.count) return false;
        if (ot == @intFromEnum(k.ObjectType.building) and (p.blevel < 0 or p.blevel >= k.max_building_levels)) return false;
        return true;
    }

    /// Forts give their team the zone and its buildings; flags link to
    /// the buildings in their zone.
    fn initZones(w: *World) Error!void {
        for (w.objects.items) |o| {
            if (o.isFort()) {
                const zi = w.zoneIndexAt(o.x, o.y) orelse continue;
                w.zones.items[zi].owner = o.owner;
                for (w.objects.items) |other| {
                    if (other.kind == .building and w.zoneIndexAt(other.x, other.y) == zi) other.owner = o.owner;
                }
            } else if (o.kind == .flag) {
                const zi = w.zoneIndexAt(o.x, o.y) orelse continue;
                try w.linkFlag(o, zi);
            }
        }
        for (w.objects.items) |o| _ = try w.setDefaultProduction(o);
        try w.resetZoneOwnership(false);
    }

    fn linkFlag(w: *World, flag: *Object, zi: usize) Error!void {
        const f = &flag.kind.flag;
        f.linked.clearRetainingCapacity();
        w.zones.items[zi].owner = flag.owner;
        for (w.objects.items) |o| {
            if (o.kind != .building or w.zoneIndexAt(o.x, o.y) != zi) continue;
            try f.linked.append(w.gpa, o.ref_id);
            o.owner = flag.owner;
        }
    }

    pub fn zoneIndexAt(w: *const World, x: i32, y: i32) ?usize {
        for (w.zones.items, 0..) |z, i| if (z.contains(x, y)) return i;
        return null;
    }

    // -----------------------------------------------------------------------
    // Objects
    // -----------------------------------------------------------------------

    /// The object with this ref id.
    pub fn find(w: *const World, ref_id: i32) ?*Object {
        const S = struct {
            fn order(id: i32, o: *Object) std.math.Order {
                return std.math.order(id, o.ref_id);
            }
        };
        const i = std.sort.binarySearch(*Object, w.objects.items, ref_id, S.order) orelse return null;
        return w.objects.items[i];
    }

    pub fn findOpt(w: *const World, ref_id: ?i32) ?*Object {
        return if (ref_id) |id| w.find(id) else null;
    }

    pub const Placement = enum {
        /// Add to the object list right away.
        direct,
        /// Created during a step: added after it (see `step`).
        deferred,
    };

    pub const CreateOptions = struct {
        level: u8 = 0,
        extra_links: u16 = 0,
        health_percent: i32 = 100,
    };

    pub fn createObject(w: *World, ot: k.ObjectType, oid: u8, x: i32, y: i32, owner: k.Team, placement: Placement, opts: CreateOptions) Error!?*Object {
        const o = try w.createObjectWithId(w.next_ref_id, ot, oid, x, y, owner, placement, opts) orelse return null;
        w.next_ref_id += 1;
        return o;
    }

    /// Create an object with a given ref id (clients use the server's ids).
    pub fn createObjectWithId(w: *World, ref_id: i32, ot: k.ObjectType, oid: u8, x: i32, y: i32, owner: k.Team, placement: Placement, opts: CreateOptions) Error!?*Object {
        const planet = if (w.map) |m| m.planet() else .desert;
        var template = Object.init(ref_id, ot, oid, &w.settings, .{
            .planet = planet,
            .level = opts.level,
            .extra_links = opts.extra_links,
        }) orelse return null;

        const o = try w.gpa.create(Object);
        errdefer w.gpa.destroy(o);
        o.* = template;
        template = undefined;
        o.owner = owner;
        o.setPosition(x, y);
        o.zone = w.zoneIndexAt(x, y);
        o.loc_update_interval = 0.8 + 0.001 * @as(f64, @floatFromInt(w.randInt(25)));
        o.last_process_time = w.now();
        if (w.grid) |*g| o.setImpassables(g);
        try o.setInitialDrivers(w.gpa, &w.settings);
        w.setHealthPercent(o, opts.health_percent);
        o.real_move_speed = @as(f64, @floatFromInt(o.move_speed)) * w.walkSpeed(o.center_x, o.center_y);

        switch (placement) {
            .direct => {
                // Keep the list sorted by ref id.
                var i = w.objects.items.len;
                while (i > 0 and w.objects.items[i - 1].ref_id > o.ref_id) i -= 1;
                try w.objects.insert(w.gpa, i, o);
            },
            .deferred => try w.new_objects.append(w.gpa, o),
        }
        w.checkUnitLimitReached();
        return o;
    }

    /// A robot squad: a leader and its minions (group size from settings
    /// unless `amount` is given).
    pub fn createRobotGroup(w: *World, r: k.Robot, x: i32, y: i32, owner: k.Team, placement: Placement, amount: ?usize, health_percent: i32) Error!?*Object {
        const n = amount orelse @as(usize, @intCast(@max(w.settings.robot[@intFromEnum(r)].group_amount, 0)));
        if (n == 0) return null;
        const leader = try w.createObject(.robot, @intFromEnum(r), x, y, owner, placement, .{ .health_percent = health_percent }) orelse return null;
        for (1..n) |_| {
            const minion = try w.createObject(.robot, @intFromEnum(r), x, y, owner, placement, .{ .health_percent = health_percent }) orelse continue;
            try leader.minions.append(w.gpa, minion.ref_id);
            minion.leader = leader.ref_id;
        }
        return leader;
    }

    /// Add objects created during the step to the world.
    pub fn addNewObjects(w: *World) Error!void {
        if (w.new_objects.items.len == 0) return;
        try w.objects.appendSlice(w.gpa, w.new_objects.items);
        w.new_objects.clearRetainingCapacity();
        w.checkUnitLimitReached();
    }

    /// Remove an object for good (the world's copy of ZServer::DeleteObject).
    pub fn deleteObject(w: *World, index: usize) Error!void {
        const o = w.objects.items[index];
        try w.removeFromGroup(o);
        if (w.grid) |*g| o.unsetImpassables(g);
        for (w.objects.items) |other| {
            if (other.attack_target == o.ref_id) other.attack_target = null;
            removeId(&other.minions, o.ref_id);
            if (other.leader == o.ref_id) other.leader = null;
        }
        _ = w.objects.orderedRemove(index);
        const ref_id = o.ref_id;
        w.destroyObject(o);
        w.checkUnitLimitReached();
        try w.send(.all, .delete_object, std.mem.asBytes(&ref_id));
    }

    fn removeId(list: *std.ArrayList(i32), id: i32) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i] == id) _ = list.orderedRemove(i) else i += 1;
        }
    }

    /// Take a robot out of its squad; minions of a removed leader follow a
    /// new leader.
    fn removeFromGroup(w: *World, o: *Object) Error!void {
        if (o.leader == null and o.minions.items.len == 0) return;
        if (w.findOpt(o.leader)) |leader| {
            removeId(&leader.minions, o.ref_id);
            try w.relayGroupInfo(leader, .all);
        } else if (o.minions.items.len > 0) {
            // First minion still around becomes the leader.
            var new_leader: ?*Object = null;
            for (o.minions.items) |id| {
                if (w.find(id)) |m| {
                    new_leader = m;
                    break;
                }
            }
            if (new_leader) |nl| {
                nl.leader = null;
                nl.minions.clearRetainingCapacity();
                for (o.minions.items) |id| {
                    if (id == nl.ref_id) continue;
                    const m = w.find(id) orelse continue;
                    m.leader = nl.ref_id;
                    try nl.minions.append(w.gpa, id);
                }
                try w.relayGroupInfo(nl, .all);
                for (nl.minions.items) |id| if (w.find(id)) |m| try w.relayGroupInfo(m, .all);
                if (o.grenades > 0) {
                    nl.grenades = o.grenades;
                    try w.relayGrenadeAmount(nl, .all);
                }
            }
        }
        o.leader = null;
        o.minions.clearRetainingCapacity();
        try w.relayGroupInfo(o, .all);
    }

    /// Give all minions the leader's orders.
    pub fn cloneMinionWaypoints(w: *World, leader: *Object) Error!void {
        for (leader.minions.items) |id| {
            const m = w.find(id) orelse continue;
            m.waypoints.clearRetainingCapacity();
            try m.waypoints.appendSlice(w.gpa, leader.waypoints.items);
            w.setVelocity(m);
            m.just_left_cannon = leader.just_left_cannon;
        }
    }

    pub fn walkSpeed(w: *const World, x: i32, y: i32) f64 {
        const m = w.map orelse return 0;
        return m.walkSpeed(w.terrain, x, y);
    }

    // -----------------------------------------------------------------------
    // Movement helpers shared with the simulation
    // -----------------------------------------------------------------------

    pub fn stopMove(w: *World, o: *Object) bool {
        _ = w;
        if (!o.isMoving()) return false;
        o.dx = 0;
        o.dy = 0;
        o.ev.updated_velocity = true;
        return true;
    }

    /// Head for the current target at the unit's speed (or stop without
    /// orders). Small changes are ignored to avoid flooding the network.
    pub fn setVelocity(w: *World, o: *Object) void {
        const old_dx = o.dx;
        const old_dy = o.dy;
        if (o.waypoints.items.len > 0) {
            var dx: f32 = @floatFromInt(o.wp.x - o.center_x);
            var dy: f32 = @floatFromInt(o.wp.y - o.center_y);
            if (!obj.isZero(dx) or !obj.isZero(dy)) {
                const mag = @sqrt(dx * dx + dy * dy);
                const speed: f32 = @floatCast(o.real_move_speed);
                dx = dx / mag * speed;
                dy = dy / mag * speed;
            }
            o.dx = dx;
            o.dy = dy;
        } else {
            _ = w.stopMove(o);
        }
        if (@abs(o.dx - old_dx) < 0.1) o.dx = old_dx;
        if (@abs(o.dy - old_dy) < 0.1) o.dy = old_dy;
        if (o.dx != old_dx or o.dy != old_dy) o.ev.updated_velocity = true;
    }

    pub fn disengage(w: *World, o: *Object) bool {
        if (o.attack_target == null) return false;
        o.attack_target = null;
        o.ev.updated_attack_target = true;
        w.signalLidShouldClose(o);
        return true;
    }

    pub fn engage(w: *World, o: *Object, target: *Object) void {
        if (o.attack_target == target.ref_id) return;
        o.attack_target = target.ref_id;
        o.ev.updated_attack_target = true;
        if (target.can_snipe) w.signalLidShouldOpen(o);
    }

    fn signalLidShouldOpen(w: *World, o: *Object) void {
        if (!o.has_lid) return;
        if (w.randInt(5) == 0) return;
        o.ev.updated_lid = true;
        o.kind.vehicle.lid_open = true;
        o.kind.vehicle.close_lid_time = null;
    }

    fn signalLidShouldClose(w: *World, o: *Object) void {
        if (!o.has_lid) return;
        const v = &o.kind.vehicle;
        if (v.lid_open and v.close_lid_time == null) {
            v.close_lid_time = w.now() + 0.1 * @as(f64, @floatFromInt(w.randInt(15)));
        }
    }

    // -----------------------------------------------------------------------
    // Teams, zones and flags
    // -----------------------------------------------------------------------

    pub fn resetObjectTeam(w: *World, o: *Object, team: k.Team) Error!void {
        o.owner = team;
        try w.relayTeam(o);
        w.checkUnitLimitReached();
    }

    /// Hand a flag's zone (and its buildings) to a team.
    pub fn awardZone(w: *World, flag: *Object, team: k.Team, conqueror: ?*Object) Error!void {
        if (conqueror) |c| try w.relayPortraitAnim(c.ref_id, .territory_taken);
        const zi = flag.zone orelse return;
        const old_team = w.zones.items[zi].owner;
        try w.resetObjectTeam(flag, team);
        var has_radar = false;
        for (flag.kind.flag.linked.items) |id| {
            const b = w.find(id) orelse continue;
            try w.resetObjectTeam(b, team);
            if (try w.setDefaultProduction(b)) try w.relayBuildingState(b, .all);
            if (b.building().?.type == .radar) has_radar = true;
        }
        w.zones.items[zi].owner = team;
        try w.sendPacket(.all, .set_zone_info, protocol.ZoneInfo{ .zone_number = @intCast(zi), .owner = @intCast(@intFromEnum(team)) });
        if (old_team != .none) try w.compMessage(old_team, -1, .territory_lost);
        if (has_radar) try w.compMessage(team, -1, .radar_activated);
        try w.resetZoneOwnership(true);
    }

    /// Units walking over an enemy flag capture it (checked 5x a second).
    pub fn checkFlagCaptures(w: *World) Error!void {
        const t = w.now();
        if (t <= w.next_flag_check_time) return;
        w.next_flag_check_time = t + 0.2;
        for (w.objects.items) |f| {
            if (f.kind != .flag) continue;
            for (w.objects.items) |o| {
                if (!o.isMobile() or o.owner == .none or o.owner == f.owner) continue;
                if (!f.intersects(o)) continue;
                try w.awardZone(f, o.owner, o);
                break;
            }
        }
    }

    /// Recompute each team's share of zones, which speeds up production.
    pub fn resetZoneOwnership(w: *World, notify: bool) Error!void {
        var flags: u32 = 0;
        var owned: [k.Team.count]u32 = @splat(0);
        for (w.objects.items) |o| if (o.kind == .flag) {
            owned[@intFromEnum(o.owner)] += 1;
            flags += 1;
        };
        for (&w.team_zone_percentage, owned) |*p, n| {
            p.* = if (flags == 0) 0 else @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(flags));
        }
        if (flags == 0) return;
        for (w.objects.items) |o| {
            if (w.resetBuildTime(o, w.team_zone_percentage[@intFromEnum(o.owner)]) and notify) {
                try w.relayBuildingState(o, .all);
            }
        }
    }

    pub fn checkUnitLimitReached(w: *World) void {
        var units: [k.Team.count]i32 = @splat(0);
        for (w.objects.items) |o| if (o.isUnit()) {
            units[@intFromEnum(o.owner)] += 1;
        };
        for (1..k.Team.count) |i| w.unit_limit_reached[i] = units[i] >= w.max_units_per_team;
    }

    /// Teams that still have units (robots, vehicles or cannons).
    pub fn teamsWithUnits(w: *const World) [k.Team.count]bool {
        var has: [k.Team.count]bool = @splat(false);
        for (w.objects.items) |o| if (o.isUnit()) {
            has[@intFromEnum(o.owner)] = true;
        };
        return has;
    }

    /// At most one team left.
    pub fn endGameRequirementsMet(w: *const World) bool {
        const has = w.teamsWithUnits();
        var teams: u32 = 0;
        for (has[1..]) |h| teams += @intFromBool(h);
        return teams <= 1;
    }

    /// Units that sit on each other spread out a little (once a second).
    pub fn scuffleUnits(w: *World) Error!void {
        const t = w.now();
        if (t < w.next_scuffle_time) return;
        w.next_scuffle_time = t + 1.0;
        for (w.objects.items) |a| {
            if (!a.isMobile() or a.owner == .none or a.waypoints.items.len > 0) continue;
            for (w.objects.items) |b| {
                if (a == b or b.owner != a.owner or !b.isMobile() or b.waypoints.items.len > 0) continue;
                if (@abs(a.center_x - b.center_x) >= 6 or @abs(a.center_y - b.center_y) >= 6) continue;
                const sx = w.randInt((b.width_pix >> 1) + (a.width_pix >> 1));
                const sy = w.randInt((b.height_pix >> 1) + (a.height_pix >> 1));
                try a.waypoints.append(w.gpa, .{
                    .mode = .move,
                    .ref_id = -1,
                    .x = if (w.randInt(2) == 1) a.center_x - sx else a.center_x + sx,
                    .y = if (w.randInt(2) == 1) a.center_y - sy else a.center_y + sy,
                });
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Cannons
    // -----------------------------------------------------------------------

    /// Whether a cannon may be placed at tile (tx, ty) for `building`.
    pub fn cannonPlacable(w: *const World, building: *const Object, tx: i32, ty: i32) bool {
        const m = w.map orelse return false;
        if (tx < 0 or ty < 0 or tx > m.header.width or ty > m.header.height) return false;
        const zi = building.zone orelse return false;
        const z = w.zones.items[zi];
        const x = tx * 16;
        const y = ty * 16;
        if (x < z.x + 16 or y < z.y + 16) return false;
        if (x + 32 > z.x + z.w - 16 or y + 32 > z.y + z.h - 16) return false;
        for (w.objects.items) |o| {
            if (o.isMobile()) continue;
            if (o.cannonNotPlacable(x, x + 32, y, y + 32)) return false;
        }
        return true;
    }

    /// Cannons in fort turret spots can't be abandoned.
    pub fn areaIsFortTurret(w: *const World, tx: i32, ty: i32) bool {
        const x = tx * 16;
        const y = ty * 16;
        for (w.objects.items) |o| {
            if (!o.isFort()) continue;
            if (o.withinSelection(x, x + 32, y, y + 32) and !o.cannonNotPlacable(x, x + 32, y, y + 32)) return true;
        }
        return false;
    }

    fn makeFortTurretsUnejectable(w: *World) void {
        for (w.objects.items) |o| switch (o.kind) {
            .cannon => |*c| if (w.areaIsFortTurret(@divTrunc(o.x, 16), @divTrunc(o.y, 16))) {
                c.ejectable = false;
            },
            else => {},
        };
    }

    /// Cannons in the building's zone, placed or waiting to be placed.
    pub fn cannonsInZone(w: *const World, building: *const Object) usize {
        var n: usize = switch (building.kind) {
            .building => |b| b.cannons.items.len,
            else => 0,
        };
        for (w.objects.items) |o| {
            if (o == building or o.zone != building.zone) continue;
            switch (o.kind) {
                .building => |b| n += b.cannons.items.len,
                .cannon => n += 1,
                else => {},
            }
        }
        return n;
    }

    // Health and damage (world/damage.zig)
    pub const setHealthPercent = damage.setHealthPercent;
    pub const setHealth = damage.setHealth;
    pub const damageHealth = damage.damageHealth;
    pub const damageDriverHealth = damage.damageDriverHealth;
    pub const updateObjectHealth = damage.updateObjectHealth;
    pub const updateObjectDriverHealth = damage.updateObjectDriverHealth;

    // Missiles (world/missiles.zig)
    pub const fireMissile = missiles.fireMissile;
    pub const processMissiles = missiles.processMissiles;

    // Production (world/production.zig)
    pub const setDefaultProduction = production.setDefaultProduction;
    pub const setProduction = production.setProduction;
    pub const addToQueue = production.addToQueue;
    pub const cancelQueued = production.cancelQueued;
    pub const stopProduction = production.stopProduction;
    pub const resetProduction = production.resetProduction;
    const resetBuildTime = production.resetBuildTime;
    pub const recalcBuildTime = production.recalcBuildTime;
    pub const buildingState = production.buildingState;
    pub const storeBuiltCannon = production.storeBuiltCannon;
    pub const buildingCreateUnit = production.buildingCreateUnit;
    pub const findNew = production.findNew;
    pub const announceNewUnit = production.announceNewUnit;
    pub const buildingRepairUnit = production.buildingRepairUnit;
    pub const unitEnterRepairBuilding = production.unitEnterRepairBuilding;
    pub const robotEnterObject = production.robotEnterObject;
    pub const ejectDrivers = production.ejectDrivers;

    // Outgoing messages (world/relay.zig)
    pub const send = relay.send;
    pub const sendPacket = relay.sendPacket;
    pub const news = relay.news;
    pub const compMessage = relay.compMessage;
    pub const relayPortraitAnim = relay.relayPortraitAnim;
    pub const relayNewObject = relay.relayNewObject;
    pub const relayHealth = relay.relayHealth;
    pub const relayLocation = relay.relayLocation;
    pub const relayAttackTarget = relay.relayAttackTarget;
    pub const relayWaypoints = relay.relayWaypoints;
    pub const relayRallypoints = relay.relayRallypoints;
    pub const relayTeam = relay.relayTeam;
    pub const relayGroupInfo = relay.relayGroupInfo;
    pub const relayGrenadeAmount = relay.relayGrenadeAmount;
    pub const relayBuiltCannons = relay.relayBuiltCannons;
    pub const relayQueue = relay.relayQueue;
    pub const relayRepairAnim = relay.relayRepairAnim;
    pub const relayBuildingState = relay.relayBuildingState;
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testWorld(terrain: *mapfmt.Terrain) !World {
    const io = testing.io;
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    terrain.* = try mapfmt.Terrain.load(io, assets);
    var w = World.init(testing.allocator, terrain, 1);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "Data/Campaing/Z_original/p02_bb_orig01.map", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try w.loadMap(bytes);
    return w;
}

test "loading a map creates its objects, zones and production" {
    const terrain = try testing.allocator.create(mapfmt.Terrain);
    defer testing.allocator.destroy(terrain);
    var w = try testWorld(terrain);
    defer w.deinit();

    try testing.expect(w.objects.items.len > 10);
    // Ref ids are sorted and lookups work.
    for (w.objects.items, 0..) |o, i| {
        if (i > 0) try testing.expect(o.ref_id > w.objects.items[i - 1].ref_id);
        try testing.expectEqual(o, w.find(o.ref_id).?);
    }
    var forts: usize = 0;
    for (w.objects.items) |o| if (o.isFort()) {
        forts += 1;
        // Forts start producing and own their zone.
        try testing.expect(o.building().?.state == .building);
        try testing.expectEqual(o.owner, w.zones.items[o.zone.?].owner);
    };
    try testing.expect(forts >= 2);
    try testing.expect(!w.endGameRequirementsMet());
}

test "damage kills and eliminations" {
    const terrain = try testing.allocator.create(mapfmt.Terrain);
    defer testing.allocator.destroy(terrain);
    var w = try testWorld(terrain);
    defer w.deinit();

    // Destroy one team's fort: all its units die and it is eliminated.
    var fort: *Object = undefined;
    for (w.objects.items) |o| if (o.isFort() and o.owner != .none) {
        fort = o;
        break;
    };
    const team = fort.owner;
    w.damageHealth(fort, fort.health);
    try w.updateObjectHealth(fort, null);
    for (w.objects.items) |o| {
        if (o.owner == team and o.isUnit()) try testing.expect(o.isDestroyed());
    }
    var eliminated = false;
    for (w.outbox.items) |m| if (m.id == .team_ended) {
        eliminated = true;
    };
    try testing.expect(eliminated);
}

test {
    testing.refAllDecls(World);
}
