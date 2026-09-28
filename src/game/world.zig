//! The game world as the server runs it: objects, map, zones, missiles and
//! the rules that tie them together (from ZServer/ZCore in
//! QZod_DnClientServer).
//!
//! Every change other peers must hear about is encoded as a protocol
//! message and queued in `outbox`; the server sends them (to everyone, a
//! team or one player) after each step.

const std = @import("std");
const k = @import("constants.zig");
const Settings = @import("settings.zig").Settings;
const mapfmt = @import("map.zig");
const pathfinding = @import("pathfinding.zig");
const buildlist = @import("buildlist.zig");
const obj = @import("object.zig");
const protocol = @import("../net/protocol.zig");
const ZTime = @import("../ztime.zig").ZTime;

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
    player: u32,
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

    clock: ZTime = .{},
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
        w.clear();
        var m = try mapfmt.Map.parse(w.gpa, bytes);
        errdefer m.deinit(w.gpa);
        w.map_bytes = try w.gpa.dupe(u8, bytes);
        w.grid = try pathfinding.Grid.fromMap(w.gpa, &m, w.terrain);
        for (m.zones, 0..) |z, i| try w.zones.append(w.gpa, mapfmt.Zone.fromRect(@intCast(i), z));
        w.map = m;

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
        for (w.objects.items) |o| _ = w.setDefaultProduction(o);
        w.resetZoneOwnership(false);
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
        const planet = if (w.map) |m| m.planet() else .desert;
        var template = Object.init(w.next_ref_id, ot, oid, &w.settings, .{
            .planet = planet,
            .level = opts.level,
            .extra_links = opts.extra_links,
        }) orelse return null;
        w.next_ref_id += 1;

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
            .direct => try w.objects.append(w.gpa, o),
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
    // Health and damage
    // -----------------------------------------------------------------------

    pub fn setHealthPercent(w: *World, o: *Object, percent: i32) void {
        const p = std.math.clamp(percent, 0, 100);
        o.initial_health_percent = p;
        w.setHealth(o, @divTrunc(p * o.max_health, 100));
    }

    pub fn setHealth(w: *World, o: *Object, new_health: i32) void {
        const was_destroyed = o.isDestroyed();
        o.health = std.math.clamp(new_health, 0, o.max_health);
        if (was_destroyed and !o.isDestroyed()) {
            if (w.grid) |*g| o.setDestroyedImpassables(g, false);
        } else if (!was_destroyed and o.isDestroyed()) {
            if (w.grid) |*g| o.setDestroyedImpassables(g, true);
            w.onKilled(o);
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
        if (b.producesUnits()) _ = stopProduction(o, true);
    }

    pub fn damageHealth(w: *World, o: *Object, amount: i32) void {
        if (o.health <= 0) return;
        w.setHealth(o, o.health - amount);
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
            try w.relayObjectDeath(o, attacker);
            try w.checkDestroyedFort(o);
            try w.checkDestroyedBridge(o);
            try w.checkNoUnitsDestroyFort(o.owner);
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
                const mh = w.settings.max_turrent_horizontal_distance;
                const mv = w.settings.max_turrent_vertical_distance;
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

        var header: protocol.DestroyObject = .{
            .ref_id = o.ref_id,
            .fire_missile_amount = @intCast(n),
            .killer_ref_id = killer orelse -1,
            .destroy_object = false,
            .do_fire_death = t - o.damaged_by_fire_time < 1.5,
            .do_missile_death = t - o.damaged_by_missile_time < 1.5,
        };
        if (o.can_be_destroyed) {
            if (o.kill_time == null) o.kill_time = t;
            header.destroy_object = true;
        }
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
            w.setHealth(other, 0);
            try w.relayObjectDeath(other, null);
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
            w.setHealth(other, 0);
            try w.relayObjectDeath(other, null);
        }
        for (w.objects.items) |f| {
            if (f.kind == .flag and f.owner == team) try w.awardZone(f, .none, null);
        }
        var buf: [96]u8 = undefined;
        try w.news(.all, std.fmt.bufPrint(&buf, "The {s} team has been eliminated", .{team.name()}) catch unreachable, .{});
    }

    /// A team without units loses its forts.
    fn checkNoUnitsDestroyFort(w: *World, team: k.Team) Error!void {
        if (team == .none) return;
        for (w.objects.items) |o| {
            if (o.owner == team and o.isUnit() and !o.isDestroyed()) return;
        }
        for (w.objects.items) |o| {
            if (o.owner != team or !o.isFort() or o.isDestroyed()) continue;
            w.setHealth(o, 0);
            try w.checkDestroyedFort(o);
            try w.relayObjectDeath(o, null);
        }
    }

    // -----------------------------------------------------------------------
    // Missiles
    // -----------------------------------------------------------------------

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
                try w.missileDamage(m);
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
            if (w.setDefaultProduction(b)) try w.relayBuildingState(b, .all);
            if (b.building().?.type == .radar) has_radar = true;
        }
        w.zones.items[zi].owner = team;
        try w.sendPacket(.all, .set_zone_info, protocol.ZoneInfo{ .zone_number = @intCast(zi), .owner = @intCast(@intFromEnum(team)) });
        if (old_team != .none) try w.compMessage(old_team, -1, .territory_lost);
        if (has_radar) try w.compMessage(team, -1, .radar_activated);
        w.resetZoneOwnership(true);
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
    pub fn resetZoneOwnership(w: *World, notify: bool) void {
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
                w.relayBuildingState(o, .all) catch {};
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

    // -----------------------------------------------------------------------
    // Production
    // -----------------------------------------------------------------------

    /// Start producing the first unit on the list if nothing is chosen.
    pub fn setDefaultProduction(w: *World, o: *Object) bool {
        const b = o.building() orelse return false;
        if (b.unit != null or b.state != .select) return false;
        const u = buildlist.first(b.type, b.level) orelse return false;
        return w.setProduction(o, u);
    }

    pub fn setProduction(w: *World, o: *Object, u: obj.Unit) bool {
        const b = o.building() orelse return false;
        if (o.owner == .none or !b.producesUnits()) return false;
        if (b.unit) |cur| if (cur.kind == u.kind and cur.id == u.id) return false;
        if (!buildlist.contains(b.type, b.level, u)) return false;
        b.unit = u;
        b.state = .building;
        b.init_time = w.now();
        _ = w.recalcBuildTime(o);
        if (b.queue.items.len == 0) _ = w.addToQueue(o, u, true);
        return true;
    }

    pub fn addToQueue(w: *World, o: *Object, u: obj.Unit, front: bool) bool {
        const b = o.building() orelse return false;
        if (o.owner == .none or !b.producesUnits()) return false;
        if (b.queue.items.len >= obj.max_queue_items) return false;
        if (!buildlist.contains(b.type, b.level, u)) return false;
        const pos: usize = if (front) 0 else b.queue.items.len;
        b.queue.insert(w.gpa, pos, u) catch return false;
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
    pub fn resetProduction(w: *World, o: *Object) void {
        const b = o.building() orelse return;
        if (b.queue.items.len > 0) {
            const next = b.queue.orderedRemove(0);
            _ = stopProduction(o, false);
            _ = w.setProduction(o, next);
        } else {
            _ = stopProduction(o, true);
        }
    }

    fn resetBuildTime(w: *World, o: *Object, zone_ownage: f32) bool {
        const b = o.building() orelse return false;
        if (zone_ownage == b.zone_ownage) return false;
        b.zone_ownage = std.math.clamp(zone_ownage, 0, 1);
        return w.recalcBuildTime(o);
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
    fn buildingState(w: *const World, o: *Object) ?protocol.SetBuildingState {
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
                if (try w.storeBuiltCannon(o, @enumFromInt(u.id))) {
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
        try w.launchNewUnit(new, p, o.creationMovePoint().?);
        try new.waypoints.appendSlice(w.gpa, o.rallypoints.items);
        try w.announceNewUnit(new);
        try w.compMessage(new.owner, new.ref_id, if (u.kind == .robot) .robot else .vehicle);
        return new;
    }

    /// Center a new unit (and its squad) on `at` and send it to `exit`.
    fn launchNewUnit(w: *World, new: *Object, at: Point, exit: Point) Error!void {
        const nx = at.x - (new.width_pix >> 1);
        const ny = at.y - (new.height_pix >> 1);
        new.setPosition(nx, ny);
        for (new.minions.items) |id| if (w.findNew(id)) |m| m.setPosition(nx, ny);
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
            const m = w.findNew(id) orelse continue;
            m.waypoints.clearRetainingCapacity();
            try m.waypoints.appendSlice(w.gpa, new.waypoints.items);
        }
        try w.relayNewObject(new, .all);
        for (new.minions.items) |id| if (w.findNew(id)) |m| try w.relayNewObject(m, .all);
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
        try w.launchNewUnit(new, p, o.repairEntrance().?);
        // The unit's orders from before the repair, minus the repair itself.
        if (job.waypoints.items.len > 1) try new.waypoints.appendSlice(w.gpa, job.waypoints.items[1..]);
        try w.announceNewUnit(new);
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

    // -----------------------------------------------------------------------
    // Outgoing messages
    // -----------------------------------------------------------------------

    pub fn send(w: *World, to: Audience, id: protocol.Message, payload: []const u8) Error!void {
        const copy = try w.gpa.dupe(u8, payload);
        errdefer w.gpa.free(copy);
        try w.outbox.append(w.gpa, .{ .to = to, .id = id, .payload = copy });
    }

    pub fn sendPacket(w: *World, to: Audience, id: protocol.Message, packet: anytype) Error!void {
        try w.send(to, id, protocol.bytesOf(&packet));
    }

    pub const Color = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 };

    /// A line in the players' news ticker.
    pub fn news(w: *World, to: Audience, text: []const u8, color: Color) Error!void {
        if (text.len == 0) return;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(w.gpa);
        try buf.appendSlice(w.gpa, &.{ color.r, color.g, color.b });
        try buf.appendSlice(w.gpa, text);
        try buf.append(w.gpa, 0);
        try w.send(to, .news, buf.items);
    }

    pub fn compMessage(w: *World, team: k.Team, ref_id: i32, sound: CompSound) Error!void {
        try w.sendPacket(.{ .team = team }, .comp_msg, protocol.ComputerMsg{ .ref_id = ref_id, .sound = @intFromEnum(sound) });
    }

    pub fn relayPortraitAnim(w: *World, ref_id: i32, anim: PortraitAnim) Error!void {
        try w.sendPacket(.all, .do_portrait_anim, protocol.DoPortraitAnim{ .ref_id = ref_id, .anim_id = @intFromEnum(anim) });
    }

    pub fn relayNewObject(w: *World, o: *Object, to: Audience) Error!void {
        try w.sendPacket(to, .add_new_object, protocol.ObjectInit{
            .x = o.x,
            .y = o.y,
            .ref_id = o.ref_id,
            .owner = @intCast(@intFromEnum(o.owner)),
            .object_type = @intFromEnum(o.objectType()),
            .object_id = o.objectId(),
            .blevel = switch (o.kind) {
                .building => |b| @intCast(b.level),
                else => 0,
            },
            .extra_links = switch (o.kind) {
                .building => |b| b.extra_links,
                else => 0,
            },
            .health = o.health,
        });
        try w.relayGroupInfo(o, to);
    }

    pub fn relayHealth(w: *World, o: *Object, to: Audience) Error!void {
        try w.sendPacket(to, .update_health, protocol.ObjectHealth{ .ref_id = o.ref_id, .health = o.health });
    }

    pub fn relayLocation(w: *World, o: *Object) Error!void {
        var buf: [4 + @sizeOf(protocol.Location)]u8 = undefined;
        std.mem.writeInt(i32, buf[0..4], o.ref_id, .little);
        @memcpy(buf[4..], std.mem.asBytes(&o.location()));
        try w.send(.all, .send_loc, &buf);
    }

    pub fn relayAttackTarget(w: *World, o: *Object) Error!void {
        try w.sendPacket(.all, .set_attack_object, protocol.AttackObject{ .ref_id = o.ref_id, .attack_object_ref_id = o.attack_target orelse -1 });
    }

    fn waypointData(w: *World, ref_id: i32, list: []const Waypoint) Error![]u8 {
        const data = try w.gpa.alloc(u8, 8 + list.len * @sizeOf(Waypoint));
        std.mem.writeInt(i32, data[0..4], ref_id, .little);
        std.mem.writeInt(i32, data[4..8], @intCast(list.len), .little);
        @memcpy(data[8..], std.mem.sliceAsBytes(list));
        return data;
    }

    /// Waypoints are only shown to the unit's own team.
    pub fn relayWaypoints(w: *World, o: *Object) Error!void {
        const data = try w.waypointData(o.ref_id, o.waypoints.items);
        defer w.gpa.free(data);
        try w.send(.{ .team = o.owner }, .send_waypoints, data);
    }

    pub fn relayRallypoints(w: *World, o: *Object, to: Audience) Error!void {
        if (!o.canSetRallypoints()) return;
        const data = try w.waypointData(o.ref_id, o.rallypoints.items);
        defer w.gpa.free(data);
        try w.send(to, .send_rallypoints, data);
    }

    pub fn relayTeam(w: *World, o: *Object) Error!void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(w.gpa);
        const header: protocol.ObjectTeam = .{
            .ref_id = o.ref_id,
            .owner = @intCast(@intFromEnum(o.owner)),
            .driver_type = @intCast(@intFromEnum(o.driver_type)),
            .driver_amount = @intCast(o.drivers.items.len),
        };
        try buf.appendSlice(w.gpa, std.mem.asBytes(&header));
        try buf.appendSlice(w.gpa, std.mem.sliceAsBytes(o.drivers.items));
        try w.send(.all, .set_object_team, buf.items);
    }

    /// OBJECT_GROUP_INFO: `i32 ref_id, i32 leader, i32 count, ids...`.
    /// NOTE: the original wrote the minion ids starting at the count's slot
    /// (and read them back the same way), so squads with minions never got
    /// through to C++ clients. These bytes reproduce that exactly while C++
    /// clients may connect.
    pub fn relayGroupInfo(w: *World, o: *Object, to: Audience) Error!void {
        if (o.kind != .robot) return;
        const n = o.minions.items.len;
        const data = try w.gpa.alloc(u8, 12 + 4 * n);
        defer w.gpa.free(data);
        @memset(data, 0);
        const ints: []align(1) i32 = std.mem.bytesAsSlice(i32, data);
        ints[0] = o.ref_id;
        ints[1] = o.leader orelse -1;
        ints[2] = @intCast(n);
        for (o.minions.items, 0..) |id, i| ints[2 + i] = id;
        try w.send(to, .object_group_info, data);
    }

    pub fn relayGrenadeAmount(w: *World, o: *Object, to: Audience) Error!void {
        if (!o.canHaveGrenades()) return;
        try w.sendPacket(to, .set_grenade_amount, protocol.GrenadeAmount{ .ref_id = o.ref_id, .grenade_amount = o.grenades });
    }

    pub fn relayBuiltCannons(w: *World, o: *Object) Error!void {
        const b = o.building() orelse return;
        const data = try w.gpa.alloc(u8, 8 + b.cannons.items.len);
        defer w.gpa.free(data);
        std.mem.writeInt(i32, data[0..4], o.ref_id, .little);
        std.mem.writeInt(i32, data[4..8], @intCast(b.cannons.items.len), .little);
        for (b.cannons.items, 0..) |c, i| data[8 + i] = @intFromEnum(c);
        try w.send(.all, .set_built_cannon_amount, data);
    }

    pub fn relayQueue(w: *World, o: *Object, to: Audience) Error!void {
        const b = o.building() orelse return;
        if (!b.producesUnits()) return;
        const data = try w.gpa.alloc(u8, 8 + 2 * b.queue.items.len);
        defer w.gpa.free(data);
        std.mem.writeInt(i32, data[0..4], o.ref_id, .little);
        std.mem.writeInt(i32, data[4..8], @intCast(b.queue.items.len), .little);
        for (b.queue.items, 0..) |u, i| {
            data[8 + 2 * i] = @intFromEnum(u.kind);
            data[9 + 2 * i] = u.id;
        }
        try w.send(to, .set_building_queue_list, data);
    }

    pub fn relayRepairAnim(w: *World, o: *Object, to: Audience, play_sound: bool) Error!void {
        const b = o.building() orelse return;
        if (b.type != .repair) return;
        try w.sendPacket(to, .set_repair_anim, protocol.RepairBuildingAnim{
            .ref_id = o.ref_id,
            .on = b.repair != null,
            .remaining_time = if (b.repair) |r| r.done_time - w.now() else 0,
            .play_sound = play_sound,
        });
    }

    /// Production state, repair animation and queue of a building.
    pub fn relayBuildingState(w: *World, o: *Object, to: Audience) Error!void {
        if (w.buildingState(o)) |state| try w.sendPacket(to, .set_building_state, state);
        try w.relayRepairAnim(o, to, true);
        try w.relayQueue(o, to);
    }
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
