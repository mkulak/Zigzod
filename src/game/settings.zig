//! Game balance settings: unit stats and global tunables (from
//! QZod_DnSettings/qzod_settings_old.cpp).
//!
//! `Settings` is also the SET_SETTINGS network message: the server sends it
//! to clients byte for byte, so its layout matches the packed C++ struct
//! (1420 bytes, no padding).

const std = @import("std");
const k = @import("constants.zig");

/// Stats of one unit type. Field names are the keys used in settings files
/// (`unit.<name>.<field>=<value>`).
pub const UnitSettings = extern struct {
    group_amount: i32 align(1) = 0,
    move_speed: i32 align(1) = 0,
    attack_radius: i32 align(1) = 0,
    attack_damage: f64 align(1) = 0,
    attack_damage_chance: f64 align(1) = 0,
    attack_damage_radius: i32 align(1) = 0,
    attack_missile_speed: i32 align(1) = 0,
    attack_speed: f64 align(1) = 0,
    attack_snipe_chance: f64 align(1) = 0,
    health: f64 align(1) = 0,
    build_time: i32 align(1) = 0,
    max_run_time: f64 align(1) = 0,

    comptime {
        std.debug.assert(@sizeOf(UnitSettings) == 72);
    }

    /// Units that hit directly: no splash damage, no projectile.
    fn censorNonMissile(u: *UnitSettings) void {
        u.attack_damage_radius = 0;
        u.attack_missile_speed = 0;
    }

    /// Units that fire projectiles: damage comes from the explosion.
    fn censorMissile(u: *UnitSettings) void {
        u.attack_damage_chance = 0;
    }

    fn censorNegatives(u: *UnitSettings) void {
        inline for (@typeInfo(UnitSettings).@"struct".fields) |f| {
            @field(u, f.name) = @max(@field(u, f.name), 0);
        }
        u.attack_damage_chance = @min(u.attack_damage_chance, 1.0);
        u.attack_snipe_chance = @min(u.attack_snipe_chance, 1.0);
    }
};

pub const Settings = extern struct {
    robot: [k.Robot.count]UnitSettings align(1),
    vehicle: [k.Vehicle.count]UnitSettings align(1),
    cannon: [k.Cannon.count]UnitSettings align(1),

    fort_building_health: f64 align(1),
    robot_building_health: f64 align(1),
    vehicle_building_health: f64 align(1),
    repair_building_health: f64 align(1),
    radar_building_health: f64 align(1),
    bridge_building_health: f64 align(1),
    rock_item_health: f64 align(1),
    grenades_item_health: f64 align(1),
    rockets_item_health: f64 align(1),
    hut_item_health: f64 align(1),
    map_item_health: f64 align(1),
    grenade_damage: f64 align(1),
    grenade_damage_radius: i32 align(1),
    grenade_missile_speed: i32 align(1),
    grenade_attack_speed: f64 align(1),
    map_item_turrent_damage: f64 align(1),
    agro_distance: i32 align(1),
    auto_grab_vehicle_distance: i32 align(1),
    auto_grab_flag_distance: i32 align(1),
    building_auto_repair_time: i32 align(1),
    building_auto_repair_random_additional_time: i32 align(1),
    max_turrent_horizontal_distance: i32 align(1),
    max_turrent_vertical_distance: i32 align(1),
    grenades_per_box: i32 align(1),
    partially_damaged_unit_speed: f64 align(1),
    damaged_unit_speed: f64 align(1),
    run_unit_speed: f64 align(1),
    run_recharge_rate: f64 align(1),
    hut_animal_max: i32 align(1),
    hut_animal_min: i32 align(1),
    hut_animal_roam_distance: i32 align(1),

    comptime {
        std.debug.assert(@sizeOf(Settings) == 1420);
    }

    /// Stats of a unit, or null for object types that have none.
    pub fn unit(s: *const Settings, object_type: k.ObjectType, id: u8) ?UnitSettings {
        return switch (object_type) {
            .robot => if (id < k.Robot.count) s.robot[id] else null,
            .vehicle => if (id < k.Vehicle.count) s.vehicle[id] else null,
            .cannon => if (id < k.Cannon.count) s.cannon[id] else null,
            else => null,
        };
    }

    // -----------------------------------------------------------------------
    // Defaults
    // -----------------------------------------------------------------------

    pub const defaults: Settings = blk: {
        // Units may run this far past their attack radius.
        const run_past_radius = 1.3;
        const U = UnitSettings;

        var s: Settings = undefined;
        s.robot = .{
            .{ .group_amount = 3, .move_speed = 14, .attack_radius = 120, .attack_damage = 0.0011046, .attack_damage_chance = 0.7, .attack_speed = 0.5, .attack_snipe_chance = 0.3, .health = 8.0 / 74.0, .build_time = 1 * 60 + 12 },
            .{ .group_amount = 3, .move_speed = 12, .attack_radius = 120, .attack_damage = 0.002617, .attack_damage_chance = 0.65, .attack_speed = 0.1, .attack_snipe_chance = 0.3, .health = 13.0 / 74.0, .build_time = 1 * 60 + 38 },
            .{ .group_amount = 3, .move_speed = 14, .attack_radius = 144, .attack_damage = 0.007008, .attack_damage_chance = 0.8, .attack_speed = 0.4, .attack_snipe_chance = 0.8, .health = 13.0 / 74.0, .build_time = 2 * 60 + 28 },
            .{ .group_amount = 2, .move_speed = 12, .attack_radius = 120, .attack_damage = 40.0 / 240.0, .attack_damage_radius = 40, .attack_missile_speed = 150, .attack_speed = 1.442, .health = 25.0 / 74.0, .build_time = 1 * 60 + 56 },
            .{ .group_amount = 4, .move_speed = 12, .attack_radius = 120, .attack_damage = 0.010486, .attack_damage_chance = 0.7, .attack_speed = 0.1, .health = 20.0 / 74.0, .build_time = 2 * 60 + 41 },
            .{ .group_amount = 4, .move_speed = 14, .attack_radius = 136, .attack_damage = 0.017799, .attack_damage_chance = 0.7, .attack_speed = 0.4, .attack_snipe_chance = 0.6, .health = 15.0 / 74.0, .build_time = 2 * 60 + 59 },
        };
        // The tough runs half as far as the others.
        const robot_run_factor = [_]f64{ 1, 1, 1, 0.5, 1, 1 };
        for (&s.robot, robot_run_factor) |*r, f| {
            r.max_run_time = f * run_past_radius * @as(f64, @floatFromInt(r.attack_radius)) / @as(f64, @floatFromInt(r.move_speed));
        }

        s.vehicle = .{
            .{ .move_speed = 17, .attack_radius = 120, .attack_damage = 0.0027067, .attack_damage_chance = 0.65, .attack_speed = 0.1, .attack_snipe_chance = 0.4, .health = 13.0 / 74.0, .build_time = 1 * 60 + 21 },
            .{ .move_speed = 14, .attack_radius = 120, .attack_damage = 50.0 / 240.0, .attack_damage_radius = 40, .attack_missile_speed = 225, .attack_speed = 1.128, .health = 25.0 / 74.0, .build_time = 2 * 60 + 17 },
            .{ .move_speed = 12, .attack_radius = 128, .attack_damage = 80.0 / 240.0, .attack_damage_radius = 45, .attack_missile_speed = 160, .attack_speed = 2.336, .health = 50.0 / 74.0, .build_time = 3 * 60 + 45 },
            .{ .move_speed = 9, .attack_radius = 144, .attack_damage = 120.0 / 240.0, .attack_damage_radius = 50, .attack_missile_speed = 135, .attack_speed = 4.088, .health = 62.0 / 74.0, .build_time = 5 * 60 + 9 },
            .{ .move_speed = 14, .health = 50.0 / 74.0, .build_time = 1 * 60 + 58 },
            .{ .move_speed = 6, .attack_radius = 160, .attack_damage = 62.0 / 74.0, .attack_damage_radius = 80, .attack_missile_speed = 70, .attack_speed = 4.454, .health = 50.0 / 74.0, .build_time = 6 * 60 + 13 },
            .{ .move_speed = 14, .health = 1.0, .build_time = 1 * 60 + 37 },
        };
        // Run factors per vehicle; the APC uses a fixed 120 pixel radius.
        const vehicle_run_factor = [_]f64{ 1, 1, 1, 0.7, 1, 0.5, 0.7 };
        for (&s.vehicle, vehicle_run_factor, 0..) |*v, f, i| {
            const radius: f64 = if (i == @intFromEnum(k.Vehicle.apc)) 120 else @floatFromInt(v.attack_radius);
            v.max_run_time = f * run_past_radius * radius / @as(f64, @floatFromInt(v.move_speed));
        }

        s.cannon = .{
            U{ .attack_radius = 120, .attack_damage = 0.00397566, .attack_damage_chance = 0.65, .attack_speed = 0.1, .attack_snipe_chance = 0.4, .health = 13.0 / 74.0, .build_time = 1 * 60 + 36 },
            U{ .attack_radius = 128, .attack_damage = 75.0 / 240.0, .attack_damage_radius = 40, .attack_missile_speed = 225, .attack_speed = 2.254, .health = 25.0 / 74.0, .build_time = 2 * 60 + 5 },
            U{ .attack_radius = 200, .attack_damage = 100.0 / 240.0, .attack_damage_radius = 40, .attack_missile_speed = 95, .attack_speed = 4.86, .health = 25.0 / 74.0, .build_time = 2 * 60 + 59 },
            U{ .attack_radius = 144, .attack_damage = 200.0 / 240.0, .attack_damage_radius = 50, .attack_missile_speed = 128, .attack_speed = 1.124, .health = 25.0 / 74.0, .build_time = 3 * 60 + 2 },
        };

        s.fort_building_health = 10000.0 / 240.0;
        s.robot_building_health = 2000.0 / 240.0;
        s.vehicle_building_health = 2000.0 / 240.0;
        s.repair_building_health = 2000.0 / 240.0;
        s.radar_building_health = 2000.0 / 240.0;
        s.bridge_building_health = 2000.0 / 240.0;
        s.rock_item_health = 30.0 / 240.0;
        s.grenades_item_health = 40.0 / 240.0;
        s.rockets_item_health = 40.0 / 240.0;
        s.hut_item_health = 40.0 / 240.0;
        s.map_item_health = 40.0 / 240.0;
        s.grenade_damage = 40.0 / 240.0;
        s.grenade_damage_radius = 30;
        s.grenade_missile_speed = 40;
        s.grenade_attack_speed = 2.254;
        s.map_item_turrent_damage = 50.0 / 240.0;
        s.agro_distance = 40;
        s.auto_grab_vehicle_distance = 220;
        s.auto_grab_flag_distance = 220;
        s.building_auto_repair_time = 10 * 60;
        s.building_auto_repair_random_additional_time = 60;
        s.max_turrent_horizontal_distance = 300;
        s.max_turrent_vertical_distance = 300;
        s.grenades_per_box = 20;
        s.partially_damaged_unit_speed = 0.9;
        s.damaged_unit_speed = 0.8;
        s.run_unit_speed = 1.8;
        s.run_recharge_rate = 0.3;
        s.hut_animal_max = 5;
        s.hut_animal_min = 3;
        s.hut_animal_roam_distance = 7 * 16;
        break :blk s;
    };

    // -----------------------------------------------------------------------
    // Settings files: "<type>.<element>.<variable>=<value>" lines
    // -----------------------------------------------------------------------

    /// Settings file keys that aren't unit stats: (type.element.variable, field).
    const global_keys = [_]struct { []const u8, []const u8 }{
        .{ "building.fort.health", "fort_building_health" },
        .{ "building.robot.health", "robot_building_health" },
        .{ "building.vehicle.health", "vehicle_building_health" },
        .{ "building.repair.health", "repair_building_health" },
        .{ "building.radar.health", "radar_building_health" },
        .{ "building.bridge.health", "bridge_building_health" },
        .{ "map_item.rock.health", "rock_item_health" },
        .{ "map_item.grenades.health", "grenades_item_health" },
        .{ "map_item.rockets.health", "rockets_item_health" },
        .{ "map_item.hut.health", "hut_item_health" },
        .{ "map_item.map_item.health", "map_item_health" },
        .{ "map_item.grenades.grenade_damage", "grenade_damage" },
        .{ "map_item.grenades.grenade_damage_radius", "grenade_damage_radius" },
        .{ "map_item.grenades.grenade_missile_speed", "grenade_missile_speed" },
        .{ "map_item.grenades.grenade_attack_speed", "grenade_attack_speed" },
        .{ "map_item.map_item.map_item_turrent_damage", "map_item_turrent_damage" },
        .{ "global.global.agro_distance", "agro_distance" },
        .{ "global.global.auto_grab_vehicle_distance", "auto_grab_vehicle_distance" },
        .{ "global.global.auto_grab_flag_distance", "auto_grab_flag_distance" },
        .{ "global.global.building_auto_repair_time", "building_auto_repair_time" },
        .{ "global.global.building_auto_repair_random_additional_time", "building_auto_repair_random_additional_time" },
        .{ "global.global.max_turrent_horizontal_distance", "max_turrent_horizontal_distance" },
        .{ "global.global.max_turrent_vertical_distance", "max_turrent_vertical_distance" },
        .{ "global.global.grenades_per_box", "grenades_per_box" },
        .{ "global.global.partially_damaged_unit_speed", "partially_damaged_unit_speed" },
        .{ "global.global.damaged_unit_speed", "damaged_unit_speed" },
        .{ "global.global.run_unit_speed", "run_unit_speed" },
        .{ "global.global.run_recharge_rate", "run_recharge_rate" },
        .{ "global.global.hut_animal_max", "hut_animal_max" },
        .{ "global.global.hut_animal_min", "hut_animal_min" },
        .{ "global.global.hut_animal_roam_distance", "hut_animal_roam_distance" },
    };

    /// Apply the settings in `text` on top of the current values (unknown
    /// keys are ignored). Returns whether any setting line was found.
    pub fn parse(s: *Settings, text: []const u8) bool {
        var found = false;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw_line| {
            if (raw_line.len == 0 or raw_line[0] == '#') continue;
            found = true;
            const eq = std.mem.indexOfScalar(u8, raw_line, '=') orelse continue;
            var key_buf: [128]u8 = undefined;
            if (eq > key_buf.len) continue;
            const key = std.ascii.lowerString(&key_buf, raw_line[0..eq]);
            // Values end at a further '=' like the C++ split() did.
            const rest = raw_line[eq + 1 ..];
            const value = rest[0 .. std.mem.indexOfScalar(u8, rest, '=') orelse rest.len];
            s.set(key, value);
        }
        s.censor();
        return found;
    }

    fn set(s: *Settings, key: []const u8, value: []const u8) void {
        if (std.mem.startsWith(u8, key, "unit.")) {
            var parts = std.mem.splitScalar(u8, key["unit.".len..], '.');
            const name = parts.next() orelse return;
            const variable = parts.rest();
            const u: *UnitSettings = if (std.meta.stringToEnum(k.Robot, name)) |r|
                &s.robot[@intFromEnum(r)]
            else if (std.meta.stringToEnum(k.Vehicle, name)) |v|
                &s.vehicle[@intFromEnum(v)]
            else if (std.meta.stringToEnum(k.Cannon, name)) |c|
                &s.cannon[@intFromEnum(c)]
            else
                return;
            inline for (@typeInfo(UnitSettings).@"struct".fields) |f| {
                if (std.mem.eql(u8, variable, f.name)) @field(u, f.name) = parseNumber(f.type, value);
            }
            return;
        }
        inline for (global_keys) |entry| {
            if (std.mem.eql(u8, key, entry[0])) {
                const T = @FieldType(Settings, entry[1]);
                @field(s, entry[1]) = parseNumber(T, value);
            }
        }
    }

    /// Clamp values into the ranges the game logic expects.
    pub fn censor(s: *Settings) void {
        for ([_]k.Robot{ .grunt, .psycho, .sniper, .pyro, .laser }) |r| s.robot[@intFromEnum(r)].censorNonMissile();
        s.vehicle[@intFromEnum(k.Vehicle.jeep)].censorNonMissile();
        s.cannon[@intFromEnum(k.Cannon.gatling)].censorNonMissile();

        s.robot[@intFromEnum(k.Robot.tough)].censorMissile();
        for ([_]k.Vehicle{ .light, .medium, .heavy, .missile_launcher, .apc, .crane }) |v| s.vehicle[@intFromEnum(v)].censorMissile();
        for (&s.cannon) |*c| c.censorMissile();

        for (&s.cannon) |*c| c.move_speed = 0;
        for (&s.robot) |*u| u.censorNegatives();
        for (&s.vehicle) |*u| u.censorNegatives();
        for (&s.cannon) |*u| u.censorNegatives();

        inline for (global_keys) |entry| {
            @field(s, entry[1]) = @max(@field(s, entry[1]), 0);
        }
        s.grenades_per_box = @min(s.grenades_per_box, 99);
        s.run_recharge_rate = @min(s.run_recharge_rate, 1);
    }

    /// Write the settings in the settings file format.
    pub fn write(s: *const Settings, w: *std.Io.Writer) std.Io.Writer.Error!void {
        inline for (.{ .{ k.Robot, "robot" }, .{ k.Vehicle, "vehicle" }, .{ k.Cannon, "cannon" } }) |group| {
            for (@field(s, group[1]), 0..) |u, i| {
                try w.print("\n", .{});
                const name = @tagName(@as(group[0], @enumFromInt(i)));
                inline for (@typeInfo(UnitSettings).@"struct".fields) |f| {
                    try w.print("unit.{s}.{s}=", .{ name, f.name });
                    try writeNumber(w, @field(u, f.name));
                }
            }
        }
        var last_type: []const u8 = "unit";
        inline for (global_keys) |entry| {
            const this_type = entry[0][0..std.mem.indexOfScalar(u8, entry[0], '.').?];
            if (!std.mem.eql(u8, this_type, last_type) or std.mem.eql(u8, entry[1], "grenade_damage")) try w.print("\n", .{});
            last_type = this_type;
            try w.print("{s}=", .{entry[0]});
            try writeNumber(w, @field(s, entry[1]));
        }
    }

    /// Load settings from a file on top of the defaults.
    pub fn load(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) !Settings {
        const text = try dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var s = defaults;
        _ = s.parse(text);
        return s;
    }
};

/// atoi/atof-like: parse the leading number, 0 if there is none.
fn parseNumber(comptime T: type, text: []const u8) T {
    const t = std.mem.trim(u8, text, " \t");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isDigit(t[end]) or std.mem.indexOfScalar(u8, "+-.eE", t[end]) != null)) end += 1;
    const num = t[0..end];
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, num, 10) catch @intFromFloat(std.fmt.parseFloat(f64, num) catch 0),
        .float => std.fmt.parseFloat(T, num) catch 0,
        else => @compileError("unsupported setting type"),
    };
}

fn writeNumber(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(v))) {
        .int => try w.print("{d}\n", .{v}),
        // Same as printf("%lf"): six decimals.
        .float => try w.print("{d:.6}\n", .{v}),
        else => unreachable,
    }
}

test "defaults" {
    const s = Settings.defaults;
    try std.testing.expectEqual(@as(i32, 3), s.robot[@intFromEnum(k.Robot.grunt)].group_amount);
    try std.testing.expectApproxEqAbs(@as(f64, 11.142857), s.robot[0].max_run_time, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 6.5), s.robot[@intFromEnum(k.Robot.tough)].max_run_time, 1e-9);
    try std.testing.expectEqual(@as(i32, 40), s.agro_distance);
    try std.testing.expect(s.unit(.building, 0) == null);
    try std.testing.expectEqual(@as(i32, 9), s.unit(.vehicle, @intFromEnum(k.Vehicle.heavy)).?.move_speed);
}

test "parse overrides and censors" {
    var s = Settings.defaults;
    const found = s.parse(
        \\# comment
        \\unit.Grunt.move_speed=20
        \\unit.gatling.attack_damage_radius=99
        \\building.fort.health=5.5
        \\global.global.grenades_per_box=500
        \\global.global.run_recharge_rate=0.5
        \\bogus.line
    );
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(i32, 20), s.robot[0].move_speed);
    try std.testing.expectEqual(@as(i32, 0), s.cannon[0].attack_damage_radius); // censored
    try std.testing.expectEqual(@as(f64, 5.5), s.fort_building_health);
    try std.testing.expectEqual(@as(i32, 99), s.grenades_per_box); // clamped
    try std.testing.expectEqual(@as(f64, 0.5), s.run_recharge_rate);
}

test "write/parse round trip" {
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Settings.defaults.write(&w);
    var s: Settings = std.mem.zeroes(Settings);
    try std.testing.expect(s.parse(w.buffered()));
    var expected = Settings.defaults;
    expected.censor();
    // Written with 6 decimals, so compare approximately.
    inline for (@typeInfo(UnitSettings).@"struct".fields) |f| {
        for (s.robot, expected.robot) |a, b| {
            if (f.type == f64) try std.testing.expectApproxEqAbs(@field(b, f.name), @field(a, f.name), 1e-6) else try std.testing.expectEqual(@field(b, f.name), @field(a, f.name));
        }
    }
    try std.testing.expectEqual(expected.hut_animal_roam_distance, s.hut_animal_roam_distance);
}

test "the shipped settings file matches the defaults" {
    // Tests run from the repository root (see build.zig).
    const s = try Settings.load(std.testing.io, std.Io.Dir.cwd(), "bin/default_settings.txt", std.testing.allocator);
    var expected = Settings.defaults;
    expected.censor();
    for (s.robot, expected.robot) |a, b| {
        try std.testing.expectEqual(b.move_speed, a.move_speed);
        try std.testing.expectApproxEqAbs(b.attack_damage, a.attack_damage, 1e-6);
    }
    try std.testing.expectEqual(expected.grenades_per_box, s.grenades_per_box);
}
