//! Game objects: units, buildings and map items (from the ZObject class
//! hierarchy in QZod_DnObjects).
//!
//! The C++ code used ~30 classes with ~150 virtual methods. Here every
//! object is one `Object` with a tagged union for the per-kind state, and
//! the per-kind behaviour is a `switch`. Objects refer to each other by
//! ref id (never by pointer), so deleting one can't leave dangling
//! references behind.

const std = @import("std");
const k = @import("constants.zig");
const Settings = @import("settings.zig").Settings;
const UnitSettings = @import("settings.zig").UnitSettings;
const buildlist = @import("buildlist.zig");
const protocol = @import("../net/protocol.zig");
const pathfinding = @import("pathfinding.zig");

pub const Waypoint = protocol.Waypoint;
pub const WaypointMode = protocol.WaypointMode;
pub const Driver = protocol.DriverInfo;
pub const Point = pathfinding.Point;
pub const Unit = buildlist.Unit;

pub const max_queue_items = 5;

/// Production state of a factory or fort (wire values).
pub const BuildState = enum(i32) {
    place,
    select,
    building,
    paused,
};

pub const Building = struct {
    type: k.Building,
    level: u8 = 0,
    /// Extra length of bridges.
    extra_links: u16 = 0,
    state: BuildState = .select,
    /// What is being produced.
    unit: ?Unit = null,
    init_time: f64 = 0,
    final_time: f64 = 0,
    queue: std.ArrayList(Unit) = .empty,
    /// Share of the map's zones the owner holds (speeds up production).
    zone_ownage: f32 = 0,
    /// Cannons built and waiting to be placed.
    cannons: std.ArrayList(k.Cannon) = .empty,
    /// Where new units appear / walk to, relative to the building.
    create_x: i32 = 32,
    create_y: i32 = 32,
    move_x: i32 = 32,
    move_y: i32 = 112,
    /// Repair station: the unit being repaired.
    repair: ?Repair = null,

    pub const Repair = struct {
        unit: Unit,
        driver_type: u8,
        drivers: std.ArrayList(Driver),
        waypoints: std.ArrayList(Waypoint),
        done_time: f64,

        pub fn deinit(r: *Repair, gpa: std.mem.Allocator) void {
            r.drivers.deinit(gpa);
            r.waypoints.deinit(gpa);
        }
    };

    pub fn producesUnits(b: *const Building) bool {
        return switch (b.type) {
            .fort_front, .fort_back, .robot_factory, .vehicle_factory => true,
            else => false,
        };
    }

    pub fn isFort(b: *const Building) bool {
        return b.type == .fort_front or b.type == .fort_back;
    }

    pub fn isBridge(b: *const Building) bool {
        return b.type == .bridge_vert or b.type == .bridge_horz;
    }
};

pub const Kind = union(enum) {
    robot: k.Robot,
    vehicle: struct {
        type: k.Vehicle,
        lid_open: bool = false,
        /// When a pending lid close happens.
        close_lid_time: ?f64 = null,
    },
    cannon: struct {
        type: k.Cannon,
        /// Fort turrets can't be abandoned.
        ejectable: bool = true,
    },
    building: Building,
    flag: struct {
        /// Buildings in the flag's zone (they change hands with it).
        linked: std.ArrayList(i32) = .empty,
    },
    /// Rocks, grenade boxes, rockets, huts and decorative map objects.
    item: k.Item,
};

/// State of the waypoint currently being followed (`waypoint_information`).
pub const WaypointState = struct {
    stage: u8 = 0,
    /// Current movement target (center coordinates) and where it started.
    x: i32 = 0,
    y: i32 = 0,
    sx: i32 = 0,
    sy: i32 = 0,
    adx: i32 = 0,
    ady: i32 = 0,
    crane_exit_x: i32 = 0,
    crane_exit_y: i32 = 0,
    agro_center_x: i32 = 0,
    agro_center_y: i32 = 0,
    fort_exit_x: i32 = 0,
    fort_exit_y: i32 = 0,
    init_attack_x: i32 = 0,
    init_attack_y: i32 = 0,
    /// A path has been planned (possibly empty = go straight).
    got_path: bool = false,
    /// Remaining path points after the current target.
    path: std.ArrayList(Point) = .empty,

    /// Forget the current waypoint's progress (keeps the path buffer).
    pub fn reset(s: *WaypointState) void {
        var path = s.path;
        path.clearRetainingCapacity();
        s.* = .{ .path = path };
    }
};

pub const Object = struct {
    ref_id: i32,
    kind: Kind,
    owner: k.Team = .none,

    // Position (top-left) and velocity in pixels (per second).
    x: i32 = 0,
    y: i32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    /// Sub-pixel movement carried over between steps.
    xover: f64 = 0,
    yover: f64 = 0,
    center_x: i32 = 0,
    center_y: i32 = 0,
    /// Size in tiles and pixels.
    width: i32 = 1,
    height: i32 = 1,
    width_pix: i32 = 16,
    height_pix: i32 = 16,

    health: i32 = 1,
    max_health: i32 = 1,
    initial_health_percent: i32 = 100,

    // Unit stats (from the settings).
    move_speed: i32 = 0,
    real_move_speed: f64 = 0,
    attack_radius: i32 = 0,
    damage: i32 = 0,
    damage_chance: f64 = 0,
    damage_radius: i32 = 1,
    missile_speed: i32 = 0,
    snipe_chance: f64 = 0,
    damage_interval: f64 = 0,
    max_stamina: f64 = 0,
    stamina: f64 = 0,
    is_running: bool = false,

    // Properties set per kind (see `init`).
    can_be_destroyed: bool = true,
    has_explosives_base: bool = false,
    attacked_by_explosives: bool = false,
    damage_is_missile: bool = false,
    can_snipe: bool = false,
    can_be_sniped_base: bool = false,
    has_lid: bool = false,
    selectable: bool = false,

    // Orders.
    waypoints: std.ArrayList(Waypoint) = .empty,
    rallypoints: std.ArrayList(Waypoint) = .empty,
    last_wp: Waypoint = .{},
    wp: WaypointState = .{},
    attack_target: ?i32 = null,

    // Timers (game time).
    last_process_time: f64 = 0,
    next_damage_time: f64 = 0,
    next_passive_check_time: f64 = 0,
    next_loc_update_time: f64 = 0,
    loc_update_interval: f64 = 0.8,
    damaged_by_fire_time: f64 = 0,
    damaged_by_missile_time: f64 = 0,
    /// Buildings repair themselves at this time after being destroyed.
    auto_repair_time: ?f64 = null,
    /// Delete the object once game time reaches this.
    kill_time: ?f64 = null,
    processed_death: bool = false,

    // Robot groups: minions follow their leader.
    leader: ?i32 = null,
    minions: std.ArrayList(i32) = .empty,

    // Vehicles and cannons carry drivers (robots).
    driver_type: k.Robot = .grunt,
    drivers: std.ArrayList(Driver) = .empty,
    /// Robots that just left a cannon don't jump right back in.
    just_left_cannon: bool = false,

    /// Robots and grenade boxes.
    grenades: i32 = 0,

    /// Index of the zone the object sits in.
    zone: ?usize = null,

    /// Changes made while simulating that clients must hear about.
    ev: Events = .{},

    /// What happened to an object during a simulation step that the
    /// server must act on or tell clients about (the original's sflags).
    pub const Events = struct {
        updated_velocity: bool = false,
        updated_waypoints: bool = false,
        updated_attack_target: bool = false,
        /// Damage was done to the attack target (or its driver).
        attack_target_health: bool = false,
        attack_target_driver_health: bool = false,
        updated_lid: bool = false,
        /// A missile was fired at this point.
        fired_missile: ?Point = null,
        /// The robot (squad) climbed into this vehicle or cannon.
        entered_target: ?i32 = null,
        /// This building finished producing a unit.
        build_unit: ?Unit = null,
        /// This repair station finished its job.
        repair_done: bool = false,
        /// This building rebuilt itself.
        auto_repaired: bool = false,
        crane_anim: ?struct { on: bool, building: i32 } = null,
        /// The unit drove into this repair station.
        entered_repair: ?i32 = null,
        /// A fort was entered by this unit and blows up.
        destroy_fort: ?i32 = null,
        updated_grenades: bool = false,
        updated_leader_grenades: bool = false,
        pickup_grenade_anim: bool = false,
        /// The grenade box that was picked up.
        delete_grenade_box: ?i32 = null,
        portrait_anim: ?protocol.PortraitAnim = null,
    };

    pub fn deinit(o: *Object, gpa: std.mem.Allocator) void {
        o.waypoints.deinit(gpa);
        o.rallypoints.deinit(gpa);
        o.wp.path.deinit(gpa);
        o.minions.deinit(gpa);
        o.drivers.deinit(gpa);
        switch (o.kind) {
            .building => |*b| {
                b.queue.deinit(gpa);
                b.cannons.deinit(gpa);
                if (b.repair) |*r| r.deinit(gpa);
            },
            .flag => |*f| f.linked.deinit(gpa),
            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // Identity
    // -----------------------------------------------------------------------

    pub fn objectType(o: *const Object) k.ObjectType {
        return switch (o.kind) {
            .robot => .robot,
            .vehicle => .vehicle,
            .cannon => .cannon,
            .building => .building,
            .flag, .item => .map_item,
        };
    }

    pub fn objectId(o: *const Object) u8 {
        return switch (o.kind) {
            .robot => |r| @intFromEnum(r),
            .vehicle => |v| @intFromEnum(v.type),
            .cannon => |c| @intFromEnum(c.type),
            .building => |b| @intFromEnum(b.type),
            .flag => @intFromEnum(k.Item.flag),
            .item => |i| @intFromEnum(i),
        };
    }

    pub fn isUnit(o: *const Object) bool {
        return switch (o.kind) {
            .robot, .vehicle, .cannon => true,
            else => false,
        };
    }

    pub fn isMobile(o: *const Object) bool {
        return o.kind == .robot or o.kind == .vehicle;
    }

    pub fn isRobot(o: *const Object) bool {
        return o.kind == .robot;
    }

    pub fn building(o: *Object) ?*Building {
        return switch (o.kind) {
            .building => |*b| b,
            else => null,
        };
    }

    pub fn isFort(o: *const Object) bool {
        return switch (o.kind) {
            .building => |b| b.isFort(),
            else => false,
        };
    }

    pub fn isVehicle(o: *const Object, v: k.Vehicle) bool {
        return switch (o.kind) {
            .vehicle => |veh| veh.type == v,
            else => false,
        };
    }

    pub fn isItem(o: *const Object, item: k.Item) bool {
        return switch (o.kind) {
            .item => |i| i == item,
            else => false,
        };
    }

    // -----------------------------------------------------------------------
    // Creation
    // -----------------------------------------------------------------------

    pub const InitOptions = struct {
        planet: k.Planet = .desert,
        level: u8 = 0,
        extra_links: u16 = 0,
    };

    /// A new object of the given wire type/id, with stats from `settings`.
    /// Null for ids that don't exist.
    pub fn init(ref_id: i32, ot: k.ObjectType, oid: u8, settings: *const Settings, opts: InitOptions) ?Object {
        var o: Object = .{ .ref_id = ref_id, .kind = undefined };
        switch (ot) {
            .robot => {
                if (oid >= k.Robot.count) return null;
                const r: k.Robot = @enumFromInt(oid);
                o.kind = .{ .robot = r };
                o.selectable = true;
                o.can_snipe = r != .tough;
                if (r == .tough) {
                    o.has_explosives_base = true;
                    o.damage_is_missile = true;
                }
                o.setUnitStats(settings.robot[oid]);
            },
            .vehicle => {
                if (oid >= k.Vehicle.count) return null;
                const v: k.Vehicle = @enumFromInt(oid);
                o.kind = .{ .vehicle = .{ .type = v } };
                o.setSize(2, 2);
                o.selectable = true;
                switch (v) {
                    .jeep => {
                        o.can_snipe = true;
                        o.can_be_sniped_base = true;
                    },
                    .light, .medium, .heavy => {
                        o.can_be_sniped_base = true;
                        o.has_explosives_base = true;
                        o.damage_is_missile = true;
                        o.has_lid = true;
                    },
                    .missile_launcher => {
                        o.has_explosives_base = true;
                        o.damage_is_missile = true;
                    },
                    .apc, .crane => {},
                }
                o.setUnitStats(settings.vehicle[oid]);
            },
            .cannon => {
                if (oid >= k.Cannon.count) return null;
                const c: k.Cannon = @enumFromInt(oid);
                o.kind = .{ .cannon = .{ .type = c } };
                o.setSize(2, 2);
                o.selectable = true;
                o.can_be_sniped_base = true;
                if (c == .gatling) {
                    o.can_snipe = true;
                } else {
                    o.has_explosives_base = true;
                    o.damage_is_missile = true;
                }
                o.setUnitStats(settings.cannon[oid]);
            },
            .building => {
                if (oid >= k.Building.count) return null;
                const bt: k.Building = @enumFromInt(oid);
                var b: Building = .{ .type = bt, .level = opts.level, .extra_links = opts.extra_links };
                o.can_be_destroyed = false;
                o.attacked_by_explosives = true;
                const health: f64 = switch (bt) {
                    .fort_front => blk: {
                        // The jungle fort graphics are one row shorter.
                        o.setSize(10, if (opts.planet == .jungle) 11 else 12);
                        b.create_x = 80;
                        b.create_y = 128;
                        b.move_x = 80;
                        b.move_y = 192 + 16;
                        break :blk settings.fort_building_health;
                    },
                    .fort_back => blk: {
                        o.setSize(10, 11);
                        b.create_x = 80;
                        b.create_y = 32;
                        b.move_x = 80;
                        b.move_y = -16;
                        break :blk settings.fort_building_health;
                    },
                    .radar => blk: {
                        o.setSize(4, 3);
                        break :blk settings.radar_building_health;
                    },
                    .repair => blk: {
                        o.setSize(5, 4);
                        break :blk settings.repair_building_health;
                    },
                    .robot_factory => blk: {
                        o.setSize(4, 5);
                        b.create_x = 43;
                        b.create_y = 53;
                        b.move_x = 43;
                        b.move_y = 80 + 16;
                        break :blk settings.robot_building_health;
                    },
                    .vehicle_factory => blk: {
                        o.setSize(4, 5);
                        b.create_x = 32;
                        b.create_y = 48;
                        b.move_x = 32;
                        b.move_y = 80 + 16;
                        break :blk settings.vehicle_building_health;
                    },
                    .bridge_vert => blk: {
                        o.setSize(4, 5 + @as(i32, opts.extra_links));
                        break :blk settings.bridge_building_health;
                    },
                    .bridge_horz => blk: {
                        o.setSize(5 + @as(i32, opts.extra_links), 4);
                        break :blk settings.bridge_building_health;
                    },
                };
                o.kind = .{ .building = b };
                o.setMaxHealth(health);
            },
            .map_item => {
                if (oid >= k.Item.count) return null;
                const item: k.Item = @enumFromInt(oid);
                if (item == .flag) {
                    o.kind = .{ .flag = .{} };
                    o.can_be_destroyed = false;
                    return o;
                }
                o.kind = .{ .item = item };
                o.attacked_by_explosives = true;
                const health: f64 = switch (item) {
                    .rock => blk: {
                        o.setSize(1, 3);
                        break :blk settings.rock_item_health;
                    },
                    .grenades => blk: {
                        o.grenades = settings.grenades_per_box;
                        break :blk settings.grenades_item_health;
                    },
                    .rockets => settings.rockets_item_health,
                    .hut => settings.hut_item_health,
                    else => settings.map_item_health,
                };
                o.setMaxHealth(health);
            },
            else => return null,
        }
        return o;
    }

    fn setSize(o: *Object, w: i32, h: i32) void {
        o.width = w;
        o.height = h;
        o.width_pix = w * k.tile_size;
        o.height_pix = h * k.tile_size;
    }

    fn setMaxHealth(o: *Object, fraction: f64) void {
        o.max_health = @intFromFloat(fraction * k.max_unit_health);
        o.health = o.max_health;
    }

    fn setUnitStats(o: *Object, u: UnitSettings) void {
        o.move_speed = u.move_speed;
        o.attack_radius = u.attack_radius;
        o.damage = @intFromFloat(u.attack_damage * k.max_unit_health);
        o.damage_chance = u.attack_damage_chance;
        o.damage_radius = u.attack_damage_radius;
        o.missile_speed = u.attack_missile_speed;
        o.snipe_chance = u.attack_snipe_chance;
        o.damage_interval = u.attack_speed;
        o.max_stamina = u.max_run_time;
        o.stamina = u.max_run_time;
        o.setMaxHealth(u.health);
    }

    // -----------------------------------------------------------------------
    // Position
    // -----------------------------------------------------------------------

    pub fn setPosition(o: *Object, x: i32, y: i32) void {
        o.x = x;
        o.y = y;
        o.center_x = x + (o.width_pix >> 1);
        o.center_y = y + (o.height_pix >> 1);
    }

    pub fn location(o: *const Object) protocol.Location {
        return .{ .x = o.x, .y = o.y, .dx = o.dx, .dy = o.dy };
    }

    pub fn isMoving(o: *const Object) bool {
        return !(isZero(o.dx) and isZero(o.dy));
    }

    /// Whether the two objects' rectangles overlap.
    pub fn intersects(a: *const Object, b: *const Object) bool {
        return !(b.x >= a.x + a.width_pix or b.x + b.width_pix <= a.x or
            b.y >= a.y + a.height_pix or b.y + b.height_pix <= a.y);
    }

    /// Whether pixel (px, py) lies on the object (edges included).
    pub fn underPoint(o: *const Object, px: i32, py: i32) bool {
        return px >= o.x and py >= o.y and px <= o.x + o.width_pix and py <= o.y + o.height_pix;
    }

    /// Whether the rectangle [left, right) x [top, bottom) touches the object.
    pub fn withinSelection(o: *const Object, left: i32, right: i32, top: i32, bottom: i32) bool {
        return !(left >= o.x + o.width_pix or right <= o.x or top >= o.y + o.height_pix or bottom <= o.y);
    }

    pub fn distanceTo(o: *const Object, x: i32, y: i32) f64 {
        const dx: f64 = @floatFromInt(o.x - x);
        const dy: f64 = @floatFromInt(o.y - y);
        return @sqrt(dx * dx + dy * dy);
    }

    pub fn distanceToObject(o: *const Object, other: *const Object) f64 {
        return o.distanceTo(other.x, other.y);
    }

    // -----------------------------------------------------------------------
    // Health
    // -----------------------------------------------------------------------

    pub fn isDestroyed(o: *const Object) bool {
        return o.health <= 0 and o.max_health > 0;
    }

    /// Relative health 0..1.
    pub fn healthRatio(o: *const Object) f64 {
        return @as(f64, @floatFromInt(o.health)) / @as(f64, @floatFromInt(o.max_health));
    }

    /// Vehicles slow down when damaged.
    pub fn showDamaged(o: *const Object) bool {
        return o.kind == .vehicle and o.healthRatio() < 0.4;
    }

    pub fn showPartiallyDamaged(o: *const Object) bool {
        if (o.kind != .vehicle) return false;
        const r = o.healthRatio();
        return r < 0.7 and r > 0.4;
    }

    // -----------------------------------------------------------------------
    // Capabilities
    // -----------------------------------------------------------------------

    pub fn hasExplosives(o: *const Object, leader: ?*const Object) bool {
        if (o.has_explosives_base or o.grenades > 0) return true;
        if (leader) |l| return l.grenades > 0;
        return false;
    }

    pub fn canAttack(o: *const Object) bool {
        return o.damage != 0 and !o.isDestroyed();
    }

    pub fn canMove(o: *const Object) bool {
        return o.move_speed != 0;
    }

    pub fn canSetWaypoints(o: *const Object) bool {
        return o.isUnit();
    }

    pub fn canSetRallypoints(o: *const Object) bool {
        return switch (o.kind) {
            .building => |b| b.producesUnits(),
            else => false,
        };
    }

    pub fn producesUnits(o: *const Object) bool {
        return o.canSetRallypoints();
    }

    /// A vehicle or cannon without a team can be taken over by robots.
    pub fn canBeEntered(o: *const Object) bool {
        return o.owner == .none and !o.isDestroyed() and (o.kind == .vehicle or o.kind == .cannon);
    }

    pub fn canEjectDrivers(o: *const Object) bool {
        return switch (o.kind) {
            .vehicle => |v| v.type == .apc,
            .cannon => |c| c.ejectable,
            else => false,
        };
    }

    pub fn canBeSniped(o: *const Object) bool {
        if (!o.can_be_sniped_base or o.drivers.items.len == 0) return false;
        return switch (o.kind) {
            .vehicle => |v| !o.has_lid or v.lid_open,
            .cannon => |c| c.ejectable,
            else => true,
        };
    }

    pub fn canBeRepaired(o: *const Object) bool {
        return o.kind == .vehicle and !o.isDestroyed() and o.health < o.max_health;
    }

    pub fn canBeRepairedByCrane(o: *const Object, team: k.Team) bool {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return false,
        };
        if (b.isFort()) return false;
        if (o.owner != .none and team != o.owner) return false;
        return o.isDestroyed();
    }

    pub fn canRepairUnit(o: *const Object, team: k.Team) bool {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return false,
        };
        return b.type == .repair and o.owner != .none and team == o.owner and !o.isDestroyed();
    }

    pub fn repairingAUnit(o: *const Object) bool {
        return switch (o.kind) {
            .building => |b| b.repair != null,
            else => false,
        };
    }

    pub fn canEnterFort(o: *const Object, team: k.Team) bool {
        return o.isFort() and team != o.owner and !o.isDestroyed();
    }

    pub fn canPickupGrenades(o: *const Object) bool {
        return switch (o.kind) {
            .robot => |r| r != .tough and o.grenades <= 0,
            else => false,
        };
    }

    pub fn canHaveGrenades(o: *const Object) bool {
        return switch (o.kind) {
            .robot => |r| r != .tough,
            else => false,
        };
    }

    /// Obstacles units with explosives can blow up (rocks, huts, map items).
    pub fn isDestroyableImpass(o: *const Object) bool {
        return switch (o.kind) {
            .item => |i| i == .rock or i == .hut or i.mapObjectIndex() != null,
            else => false,
        };
    }

    /// Whether this obstacle blocks the tile at pixel (x, y).
    pub fn causesImpassAt(o: *const Object, x: i32, y: i32) bool {
        return switch (o.kind) {
            .item => |i| switch (i) {
                .rock => x == o.x and y == o.y + 32,
                .hut => x == o.x and y == o.y,
                else => i.mapObjectIndex() != null and x == o.x and y == o.y,
            },
            else => false,
        };
    }

    /// Cannons may not be placed where they would overlap this object
    /// (fort turret spots excepted).
    pub fn cannonNotPlacable(o: *const Object, left: i32, right: i32, top: i32, bottom: i32) bool {
        if (o.isFort()) {
            const lx = left - o.x;
            const ly = top - o.y;
            if ((lx == 16 or lx == 112) and (ly == 0 or ly == 48)) return false;
        }
        return o.withinSelection(left, right, top, bottom);
    }

    /// Where a crane parks to repair this building (up to two entrances).
    pub fn craneEntrance(o: *const Object) ?[2]Point {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return null,
        };
        const below = o.y + o.height_pix + 32;
        return switch (b.type) {
            .radar => .{ .{ .x = o.x + 28, .y = below }, .{ .x = o.x + 28, .y = below } },
            .repair => .{ .{ .x = o.x + 32, .y = below }, .{ .x = o.x + 32, .y = below } },
            .robot_factory => .{ .{ .x = o.x + 35, .y = below }, .{ .x = o.x + 35, .y = below } },
            .vehicle_factory => .{ .{ .x = o.x + 31, .y = below }, .{ .x = o.x + 31, .y = below } },
            .bridge_vert => .{ .{ .x = o.x + 32, .y = o.y - 32 }, .{ .x = o.x + 32, .y = below } },
            .bridge_horz => .{ .{ .x = o.x - 31, .y = o.y + 31 }, .{ .x = o.x + o.width_pix + 32, .y = o.y + 32 } },
            .fort_front, .fort_back => null,
        };
    }

    pub fn craneCenter(o: *const Object) ?Point {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return null,
        };
        return switch (b.type) {
            .radar => .{ .x = o.x + 28, .y = o.y + 24 },
            .repair => .{ .x = o.x + 32, .y = o.y + 32 },
            .robot_factory => .{ .x = o.x + 35, .y = o.y + 32 },
            .vehicle_factory => .{ .x = o.x + 31, .y = o.y + 32 },
            .bridge_vert, .bridge_horz => .{ .x = o.x + (o.width_pix >> 1), .y = o.y + (o.height_pix >> 1) },
            .fort_front, .fort_back => null,
        };
    }

    pub fn repairEntrance(o: *const Object) ?Point {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return null,
        };
        if (b.type != .repair) return null;
        return .{ .x = o.x + 32, .y = o.y + o.height_pix + 32 };
    }

    pub fn repairCenter(o: *const Object) ?Point {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return null,
        };
        if (b.type != .repair) return null;
        return .{ .x = o.x + 32, .y = o.y + 32 };
    }

    pub fn creationPoint(o: *const Object) ?Point {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return null,
        };
        return .{ .x = o.x + b.create_x, .y = o.y + b.create_y };
    }

    pub fn creationMovePoint(o: *const Object) ?Point {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return null,
        };
        return .{ .x = o.x + b.move_x, .y = o.y + b.move_y };
    }

    // -----------------------------------------------------------------------
    // Drivers
    // -----------------------------------------------------------------------

    /// Vehicles and cannons that start with a team get one grunt driver.
    pub fn setInitialDrivers(o: *Object, gpa: std.mem.Allocator, settings: *const Settings) !void {
        if (o.kind != .vehicle and o.kind != .cannon) return;
        o.driver_type = .grunt;
        o.drivers.clearRetainingCapacity();
        if (o.owner != .none) {
            try o.addDriver(gpa, settings, @intFromFloat(settings.robot[@intFromEnum(k.Robot.grunt)].health * k.max_unit_health));
        } else {
            o.resetDamageInfo(settings);
        }
    }

    pub fn addDriver(o: *Object, gpa: std.mem.Allocator, settings: *const Settings, health: i32) !void {
        try o.drivers.append(gpa, .{ .health = health });
        o.resetDamageInfo(settings);
    }

    pub fn clearDrivers(o: *Object, settings: *const Settings) void {
        o.drivers.clearRetainingCapacity();
        o.resetDamageInfo(settings);
    }

    pub fn setDriverType(o: *Object, settings: *const Settings, t: k.Robot) void {
        o.driver_type = t;
        o.resetDamageInfo(settings);
    }

    /// An APC fights with the weapons of the robots inside it.
    pub fn resetDamageInfo(o: *Object, settings: *const Settings) void {
        if (!o.isVehicle(.apc)) return;
        o.attack_radius = 0;
        o.damage = 0;
        o.damage_chance = 0;
        o.damage_interval = 0;
        o.damage_is_missile = false;
        o.damage_radius = 0;
        o.missile_speed = 0;
        o.has_explosives_base = false;
        if (o.drivers.items.len == 0) return;
        const u = settings.robot[@intFromEnum(o.driver_type)];
        o.attack_radius = u.attack_radius;
        o.damage = @as(i32, @intFromFloat(u.attack_damage * k.max_unit_health)) * @as(i32, @intCast(o.drivers.items.len));
        o.damage_chance = u.attack_damage_chance;
        o.damage_interval = u.attack_speed;
        o.damage_radius = u.attack_damage_radius;
        o.missile_speed = u.attack_missile_speed;
        if (o.driver_type == .tough) {
            o.has_explosives_base = true;
            o.damage_is_missile = true;
        }
    }

    // -----------------------------------------------------------------------
    // Map obstacles
    // -----------------------------------------------------------------------

    /// Mark the tiles this object blocks (called when it is created).
    pub fn setImpassables(o: *const Object, grid: *pathfinding.Grid) void {
        const tx = @divTrunc(o.x, 16);
        const ty = @divTrunc(o.y, 16);
        switch (o.kind) {
            .building => |b| switch (b.type) {
                .fort_front, .fort_back => setFortImpassables(grid, tx, ty, b.type == .fort_front),
                .radar => {
                    fillImpassable(grid, tx, ty, o.width, o.height);
                    grid.setImpassable(tx + 3, ty + 2, false, false);
                },
                .repair, .robot_factory, .vehicle_factory => fillImpassable(grid, tx, ty, o.width, o.height),
                // Only the railings; the deck is passable while the bridge stands.
                .bridge_vert, .bridge_horz => bridgeLines(grid, o, b.type == .bridge_vert, tx, ty, &.{ 0, 3 }, true),
            },
            .item => |i| switch (i) {
                .rock => grid.setImpassable(tx, ty + 2, true, true),
                .hut => grid.setImpassable(tx, ty, true, true),
                else => if (i.mapObjectIndex() != null) grid.setImpassable(tx, ty, true, true),
            },
            else => {},
        }
    }

    /// Undo `setImpassables` for objects that can be removed.
    pub fn unsetImpassables(o: *const Object, grid: *pathfinding.Grid) void {
        const tx = @divTrunc(o.x, 16);
        const ty = @divTrunc(o.y, 16);
        switch (o.kind) {
            .item => |i| switch (i) {
                .rock => grid.setImpassable(tx, ty + 2, false, true),
                .hut => grid.setImpassable(tx, ty, false, true),
                else => if (i.mapObjectIndex() != null) grid.setImpassable(tx, ty, false, true),
            },
            else => {},
        }
    }

    /// A destroyed bridge blocks its deck (and frees it when rebuilt).
    pub fn setDestroyedImpassables(o: *const Object, grid: *pathfinding.Grid, destroyed: bool) void {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return,
        };
        const tx = @divTrunc(o.x, 16);
        const ty = @divTrunc(o.y, 16);
        switch (b.type) {
            .bridge_vert, .bridge_horz => bridgeLines(grid, o, b.type == .bridge_vert, tx, ty, &.{ 1, 2 }, destroyed),
            else => {},
        }
    }
};

/// Lines along a bridge (columns of a vertical one, rows of a horizontal
/// one), at the given offsets across it.
fn bridgeLines(grid: *pathfinding.Grid, o: *const Object, vertical: bool, tx: i32, ty: i32, lines: []const i32, impassable: bool) void {
    const length = if (vertical) o.height else o.width;
    var i: i32 = 0;
    while (i < length) : (i += 1) for (lines) |l| {
        if (vertical) grid.setImpassable(tx + l, ty + i, impassable, false) else grid.setImpassable(tx + i, ty + l, impassable, false);
    };
}

fn fillImpassable(grid: *pathfinding.Grid, tx: i32, ty: i32, w: i32, h: i32) void {
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        var j: i32 = 0;
        while (j < h) : (j += 1) grid.setImpassable(tx + i, ty + j, true, false);
    }
}

/// The fort's walls: its corners, gates and inner yard are passable.
fn setFortImpassables(grid: *pathfinding.Grid, tx: i32, ty: i32, is_front: bool) void {
    fillImpassable(grid, tx, ty, 10, 9);
    const open = [_][2]i32{
        .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 7 }, .{ 0, 8 }, .{ 0, 9 },
        .{ 9, 0 }, .{ 9, 1 }, .{ 9, 2 }, .{ 9, 7 }, .{ 9, 8 }, .{ 9, 9 },
        .{ 3, 0 }, .{ 4, 0 }, .{ 5, 0 }, .{ 6, 0 }, .{ 1, 8 }, .{ 3, 8 },
        .{ 4, 8 }, .{ 5, 8 }, .{ 6, 8 }, .{ 8, 8 },
    };
    for (open) |p| grid.setImpassable(tx + p[0], ty + p[1], false, false);
    if (is_front) {
        for ([_][2]i32{ .{ 3, 8 }, .{ 3, 9 }, .{ 6, 8 }, .{ 6, 9 } }) |p| grid.setImpassable(tx + p[0], ty + p[1], true, false);
        for ([_][2]i32{ .{ 4, 7 }, .{ 5, 7 }, .{ 4, 6 }, .{ 5, 6 } }) |p| grid.setImpassable(tx + p[0], ty + p[1], false, false);
    } else {
        for ([_][2]i32{ .{ 4, 1 }, .{ 5, 1 }, .{ 4, 2 }, .{ 5, 2 } }) |p| grid.setImpassable(tx + p[0], ty + p[1], false, false);
    }
}

pub fn isZero(v: anytype) bool {
    return v < 0.00001 and v > -0.00001;
}

test "creating objects" {
    const s = &Settings.defaults;
    const grunt = Object.init(1, .robot, @intFromEnum(k.Robot.grunt), s, .{}).?;
    try std.testing.expectEqual(@as(i32, 16), grunt.width_pix);
    try std.testing.expectEqual(@as(i32, @intFromFloat(8.0 / 74.0 * 10000)), grunt.max_health);
    try std.testing.expect(grunt.can_snipe and grunt.canHaveGrenades());

    const fort = Object.init(2, .building, @intFromEnum(k.Building.fort_front), s, .{ .planet = .jungle }).?;
    try std.testing.expectEqual(@as(i32, 11), fort.height);
    try std.testing.expect(fort.producesUnits() and !fort.can_be_destroyed);

    const bridge = Object.init(3, .building, @intFromEnum(k.Building.bridge_horz), s, .{ .extra_links = 2 }).?;
    try std.testing.expectEqual(@as(i32, 7), bridge.width);

    const rock = Object.init(4, .map_item, @intFromEnum(k.Item.rock), s, .{}).?;
    try std.testing.expect(rock.isDestroyableImpass());
    try std.testing.expectEqual(@as(i32, 48), rock.height_pix);

    try std.testing.expect(Object.init(5, .robot, 99, s, .{}) == null);
}

test "APC fights with its passengers' weapons" {
    const gpa = std.testing.allocator;
    const s = &Settings.defaults;
    var apc = Object.init(1, .vehicle, @intFromEnum(k.Vehicle.apc), s, .{}).?;
    defer apc.deinit(gpa);
    try std.testing.expect(!apc.canAttack());
    apc.setDriverType(s, .psycho);
    try apc.addDriver(gpa, s, 100);
    try apc.addDriver(gpa, s, 100);
    try std.testing.expect(apc.canAttack());
    try std.testing.expectEqual(@as(i32, 2 * @as(i32, @intFromFloat(0.002617 * 10000))), apc.damage);
}

test {
    std.testing.refAllDecls(Object);
    std.testing.refAllDecls(pathfinding.Grid);
}
