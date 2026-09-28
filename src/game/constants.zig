//! Game-wide enums and constants (from QZod_DnSeparate/constants.h and
//! QZod_DnMap/zmap_structures_old.h).
//!
//! The numeric values are part of the network protocol and the map file
//! format, so the order of every enum here must not change.

const std = @import("std");

pub const game_version = "2011-09-06";

pub const max_player_name_size = 30;
pub const max_building_levels = 6;
pub const max_stored_cannons = 4;
pub const default_max_units_per_team = 70;
pub const max_unit_health = 10000;
pub const max_bot_bypass_size = 512;

/// Map tiles are 16x16 pixels.
pub const tile_size = 16;

/// Walking speed multipliers for special terrain.
pub const road_speed = 1.689;
pub const water_speed = 0.7;

pub const Team = enum(u8) {
    none,
    red,
    blue,
    green,
    yellow,
    purple,
    teal,
    white,
    black,

    pub const count = @typeInfo(Team).@"enum".fields.len;

    /// Lower-case name as used in asset file names and on the command line.
    pub fn name(t: Team) []const u8 {
        return if (t == .none) "null" else @tagName(t);
    }

    pub fn fromName(s: []const u8) ?Team {
        if (std.mem.eql(u8, s, "null")) return .none;
        return std.meta.stringToEnum(Team, s);
    }

    /// Wire/map-file value, which is a signed char where -1 or out of range
    /// values mean "no team".
    pub fn fromByte(b: i8) Team {
        return if (b >= 0 and b < count) @enumFromInt(b) else .none;
    }
};

pub const Planet = enum(u8) {
    desert,
    volcanic,
    arctic,
    jungle,
    city,

    pub const count = @typeInfo(Planet).@"enum".fields.len;
};

/// Kind of object; `map_object_type` in the C++ code.
pub const ObjectType = enum(u8) {
    rock,
    bridge,
    building,
    cannon,
    vehicle,
    robot,
    animal,
    map_item,
    _,
};

pub const Robot = enum(u8) {
    grunt,
    psycho,
    sniper,
    tough,
    pyro,
    laser,

    pub const count = @typeInfo(Robot).@"enum".fields.len;
};

pub const Cannon = enum(u8) {
    gatling,
    gun,
    howitzer,
    missile_cannon,

    pub const count = @typeInfo(Cannon).@"enum".fields.len;
};

pub const Vehicle = enum(u8) {
    jeep,
    light,
    medium,
    heavy,
    apc,
    missile_launcher,
    crane,

    pub const count = @typeInfo(Vehicle).@"enum".fields.len;
};

pub const Building = enum(u8) {
    fort_front,
    fort_back,
    radar,
    repair,
    robot_factory,
    vehicle_factory,
    bridge_vert,
    bridge_horz,

    pub const count = @typeInfo(Building).@"enum".fields.len;
};

pub const Item = enum(u8) {
    flag,
    rock,
    grenades,
    rockets,
    hut,
    /// Decorative map objects map_object0 .. map_object21 follow.
    map_object0,
    _,

    pub const map_object_count = 22;
    pub const count = 5 + map_object_count;

    /// Index of a decorative map object (0..21), if this is one.
    pub fn mapObjectIndex(i: Item) ?u8 {
        const v = @intFromEnum(i);
        const first = @intFromEnum(Item.map_object0);
        return if (v >= first and v < count) v - first else null;
    }
};

pub const Animal = enum(u8) {
    bird,
    hut_animal,
};

pub const PlayerMode = enum(u8) {
    nobody,
    player,
    bot,
    spectator,
    tray,
};

pub const VoteChoice = enum(u8) {
    none,
    yes,
    no,
    pass,
};

/// The eight directions units face; the value times 45 is the angle.
pub const Direction = enum(u3) {
    r0,
    r45,
    r90,
    r135,
    r180,
    r225,
    r270,
    r315,

    pub fn degrees(d: Direction) u16 {
        return @as(u16, @intFromEnum(d)) * 45;
    }
};

test "enum values match the C++ constants" {
    try std.testing.expectEqual(@as(usize, 9), Team.count);
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(ObjectType.robot));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Item.map_object0));
    try std.testing.expectEqual(@as(?u8, 21), @as(Item, @enumFromInt(26)).mapObjectIndex());
    try std.testing.expectEqual(@as(?u8, null), Item.hut.mapObjectIndex());
    try std.testing.expectEqualStrings("null", Team.none.name());
    try std.testing.expectEqual(Team.teal, Team.fromName("teal").?);
    try std.testing.expectEqual(Team.none, Team.fromByte(-1));
}
