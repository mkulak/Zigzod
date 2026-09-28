//! Units each building can produce, per building level (generated from
//! QZod_DnSettings/zbuildlist.cpp).

const k = @import("constants.zig");

/// A producible unit: object type and id.
pub const Unit = struct { kind: k.ObjectType, id: u8 };

fn r(id: k.Robot) Unit {
    return .{ .kind = .robot, .id = @intFromEnum(id) };
}
fn v(id: k.Vehicle) Unit {
    return .{ .kind = .vehicle, .id = @intFromEnum(id) };
}
fn c(id: k.Cannon) Unit {
    return .{ .kind = .cannon, .id = @intFromEnum(id) };
}

const fort = [k.max_building_levels][]const Unit{
    &.{ r(.grunt), v(.jeep), v(.crane), c(.gatling) },
    &.{ r(.grunt), r(.psycho), v(.jeep), v(.light), v(.crane), c(.gatling), c(.gun) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), v(.jeep), v(.light), v(.medium), v(.crane), c(.gatling), c(.gun), c(.howitzer) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), r(.pyro), v(.jeep), v(.light), v(.medium), v(.apc), v(.crane), c(.gatling), c(.gun), c(.howitzer) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), r(.pyro), r(.laser), v(.jeep), v(.light), v(.medium), v(.heavy), v(.apc), v(.crane), c(.gatling), c(.gun), c(.howitzer), c(.missile_cannon) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), r(.pyro), r(.laser), v(.jeep), v(.light), v(.medium), v(.heavy), v(.apc), v(.missile_launcher), v(.crane), c(.gatling), c(.gun), c(.howitzer), c(.missile_cannon) },
};

const robot_factory = [k.max_building_levels][]const Unit{
    &.{ r(.grunt), c(.gatling) },
    &.{ r(.grunt), r(.psycho), c(.gatling) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), c(.gatling), c(.gun) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), r(.pyro), c(.gatling), c(.gun), c(.howitzer) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), r(.pyro), r(.laser), c(.gatling), c(.gun), c(.howitzer) },
    &.{ r(.grunt), r(.psycho), r(.sniper), r(.tough), r(.pyro), r(.laser), c(.gatling), c(.gun), c(.howitzer), c(.missile_cannon) },
};

const vehicle_factory = [k.max_building_levels][]const Unit{
    &.{ v(.jeep), c(.gatling) },
    &.{ v(.jeep), v(.light), c(.gatling), c(.gun) },
    &.{ v(.jeep), v(.light), v(.medium), c(.gatling), c(.gun) },
    &.{ v(.jeep), v(.light), v(.medium), v(.apc), c(.gatling), c(.gun), c(.howitzer) },
    &.{ v(.jeep), v(.light), v(.medium), v(.heavy), v(.apc), c(.gatling), c(.gun), c(.howitzer) },
    &.{ v(.jeep), v(.light), v(.medium), v(.heavy), v(.apc), v(.missile_launcher), c(.gatling), c(.gun), c(.howitzer), c(.missile_cannon) },
};
/// What `building` can produce at `level` (empty for buildings that don't
/// produce). The back of a fort uses the fort's list.
pub fn forBuilding(building: k.Building, level: u8) []const Unit {
    const lv = @min(level, k.max_building_levels - 1);
    return switch (building) {
        .fort_front, .fort_back => fort[lv],
        .robot_factory => robot_factory[lv],
        .vehicle_factory => vehicle_factory[lv],
        else => &.{},
    };
}

pub fn first(building: k.Building, level: u8) ?Unit {
    const list = forBuilding(building, level);
    return if (list.len > 0) list[0] else null;
}

pub fn contains(building: k.Building, level: u8, unit: Unit) bool {
    for (forBuilding(building, level)) |u| {
        if (u.kind == unit.kind and u.id == unit.id) return true;
    }
    return false;
}

test "build lists" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 4), forBuilding(.fort_front, 0).len);
    try std.testing.expectEqual(forBuilding(.fort_front, 3).len, forBuilding(.fort_back, 3).len);
    try std.testing.expect(contains(.vehicle_factory, 5, v(.missile_launcher)));
    try std.testing.expect(!contains(.robot_factory, 0, r(.laser)));
    try std.testing.expectEqual(k.ObjectType.robot, first(.robot_factory, 0).?.kind);
    try std.testing.expect(first(.radar, 0) == null);
}
