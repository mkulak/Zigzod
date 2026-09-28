//! Tile positions and the tiles of a map, numbered row by row.
//!
//! Positions are signed (a point next to the map is a valid question to
//! ask); tile numbers are unsigned and always on the map. Conversions
//! between the two happen here, checked, instead of at every use.

const std = @import("std");
const k = @import("constants.zig");

/// A tile's position (column, row); may be off the map.
pub const Tile = struct {
    x: i32,
    y: i32,

    /// The tile a map pixel is in.
    pub fn at(px: i32, py: i32) Tile {
        return .{ .x = @divFloor(px, k.tile_size), .y = @divFloor(py, k.tile_size) };
    }

    /// The pixel at the tile's center.
    pub fn center(t: Tile) [2]i32 {
        return .{ t.x * k.tile_size + k.tile_size / 2, t.y * k.tile_size + k.tile_size / 2 };
    }

    pub fn plus(t: Tile, dx: i32, dy: i32) Tile {
        return .{ .x = t.x + dx, .y = t.y + dy };
    }
};

/// The tiles of a w x h map.
pub const Area = struct {
    w: u16,
    h: u16,

    /// How many tiles.
    pub fn count(a: Area) u32 {
        return @as(u32, a.w) * a.h;
    }

    pub fn contains(a: Area, t: Tile) bool {
        return t.x >= 0 and t.y >= 0 and t.x < a.w and t.y < a.h;
    }

    /// The number of a tile; null when it is off the map.
    pub fn index(a: Area, t: Tile) ?u32 {
        if (!a.contains(t)) return null;
        return @as(u32, @intCast(t.y)) * a.w + @as(u32, @intCast(t.x));
    }

    /// The tile with number `i` (which must be on the map).
    pub fn tile(a: Area, i: usize) Tile {
        std.debug.assert(i < a.count());
        return .{ .x = @intCast(i % a.w), .y = @intCast(i / a.w) };
    }

    /// The nearest tile on the map.
    pub fn clamp(a: Area, t: Tile) Tile {
        return .{ .x = std.math.clamp(t.x, 0, @as(i32, a.w) - 1), .y = std.math.clamp(t.y, 0, @as(i32, a.h) - 1) };
    }
};

test "tile numbers" {
    const a: Area = .{ .w = 4, .h = 3 };
    try std.testing.expectEqual(12, a.count());
    try std.testing.expectEqual(@as(?u32, 6), a.index(.{ .x = 2, .y = 1 }));
    try std.testing.expectEqual(@as(?u32, null), a.index(.{ .x = 4, .y = 0 }));
    try std.testing.expectEqual(@as(?u32, null), a.index(.{ .x = 0, .y = -1 }));
    try std.testing.expectEqual(Tile{ .x = 3, .y = 2 }, a.tile(11));
    try std.testing.expectEqual(Tile{ .x = -1, .y = 0 }, Tile.at(-1, 15));
    try std.testing.expectEqual(Tile{ .x = 3, .y = 0 }, a.clamp(.{ .x = 9, .y = -2 }));
}
