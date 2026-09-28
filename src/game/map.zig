//! Maps: the .map file format, terrain tile properties and zones (from
//! QZod_DnMap/qzod_map.cpp and zmap_structures_old.h).
//!
//! A map file is: a Header, `zone_count` ZoneRects, `object_count`
//! Placements, then width*height tiles (u16 indexes into the planet's tile
//! palette). All little-endian C structs; the server also sends the file
//! as-is to clients (STORE_MAP).

const std = @import("std");
const k = @import("constants.zig");

pub const Header = extern struct {
    width: u16,
    height: u16,
    name: [50]u8,
    player_count: u8,
    object_count: u16,
    terrain: u8,
    zone_count: u16,

    comptime {
        std.debug.assert(@sizeOf(Header) == 62);
        std.debug.assert(@offsetOf(Header, "zone_count") == 60);
    }

    pub fn nameSlice(h: *const Header) []const u8 {
        return std.mem.sliceTo(&h.name, 0);
    }
};

/// A zone rectangle in tiles.
pub const ZoneRect = extern struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

/// An object placed on the map, position in tiles.
pub const Placement = extern struct {
    x: u16,
    y: u16,
    /// Team; -1 or out of range for none.
    owner: i8,
    object_type: u8,
    object_id: u8,
    /// Building level (factories) or similar.
    blevel: i8,
    /// Extra fort/factory connections.
    extra_links: u16,
    health_percent: i32,

    comptime {
        std.debug.assert(@sizeOf(Placement) == 16);
    }

    pub fn team(p: Placement) k.Team {
        return k.Team.fromByte(p.owner);
    }
};

/// Properties of one tile of a planet's palette (the .tileinfo files).
pub const TileInfo = extern struct {
    is_water: bool,
    is_passable: bool,
    is_usable: bool,
    is_road: bool,
    is_effect: bool,
    /// Randomly animated within water.
    is_water_effect: bool,
    next_tile_in_effect: u16 align(1),
    takes_tank_tracks: bool,
    crater_type: i16 align(1),
    is_starter_tile: bool,

    comptime {
        std.debug.assert(@sizeOf(TileInfo) == 12);
    }
};

/// Each planet palette is 20x24 tiles of 16x16 pixels.
pub const palette_width = 20;
pub const palette_height = 24;
pub const palette_tiles = palette_width * palette_height;

pub const Palette = [palette_tiles]TileInfo;

/// Tile properties of all planets, loaded from assets/planets/*.tileinfo.
pub const Terrain = struct {
    palettes: [k.Planet.count]Palette,

    pub fn load(io: std.Io, assets_dir: std.Io.Dir) !Terrain {
        var t: Terrain = undefined;
        for (&t.palettes, 0..) |*pal, i| {
            var path_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "planets/{s}.tileinfo", .{@tagName(@as(k.Planet, @enumFromInt(i)))});
            const bytes = std.mem.sliceAsBytes(pal);
            const file = try assets_dir.openFile(io, path, .{});
            defer file.close(io);
            var reader = file.reader(io, &.{});
            try reader.interface.readSliceAll(bytes);
        }
        return t;
    }

    pub fn palette(t: *const Terrain, planet: k.Planet) *const Palette {
        return &t.palettes[@intFromEnum(planet)];
    }
};

pub const ParseError = error{
    Truncated,
    BadTile,
    BadTerrain,
} || std.mem.Allocator.Error;

pub const Map = struct {
    header: Header,
    zones: []ZoneRect,
    placements: []Placement,
    tiles: []u16,

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Map {
        var r: std.Io.Reader = .fixed(bytes);
        const header = r.takeStruct(Header, .little) catch return error.Truncated;
        if (header.terrain >= k.Planet.count) return error.BadTerrain;

        const zones = try readArray(gpa, &r, ZoneRect, header.zone_count);
        errdefer gpa.free(zones);
        const placements = try readArray(gpa, &r, Placement, header.object_count);
        errdefer gpa.free(placements);
        const tiles = try readArray(gpa, &r, u16, @as(usize, header.width) * header.height);
        errdefer gpa.free(tiles);
        for (tiles) |t| if (t >= palette_tiles) return error.BadTile;

        return .{ .header = header, .zones = zones, .placements = placements, .tiles = tiles };
    }

    fn readArray(gpa: std.mem.Allocator, r: *std.Io.Reader, comptime T: type, n: usize) ParseError![]T {
        const items = try gpa.alloc(T, n);
        errdefer gpa.free(items);
        for (items) |*item| {
            item.* = if (T == u16)
                r.takeInt(u16, .little) catch return error.Truncated
            else
                r.takeStruct(T, .little) catch return error.Truncated;
        }
        return items;
    }

    pub fn load(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) !Map {
        const bytes = try dir.readFileAlloc(io, path, gpa, .limited(16 << 20));
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }

    pub fn deinit(m: *Map, gpa: std.mem.Allocator) void {
        gpa.free(m.zones);
        gpa.free(m.placements);
        gpa.free(m.tiles);
        m.* = undefined;
    }

    /// Write the map in the file format (also what STORE_MAP sends).
    pub fn write(m: *const Map, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var header = m.header;
        header.zone_count = @intCast(m.zones.len);
        header.object_count = @intCast(m.placements.len);
        try w.writeStruct(header, .little);
        for (m.zones) |z| try w.writeStruct(z, .little);
        for (m.placements) |p| try w.writeStruct(p, .little);
        for (m.tiles) |t| try w.writeInt(u16, t, .little);
    }

    pub fn planet(m: *const Map) k.Planet {
        return @enumFromInt(m.header.terrain);
    }

    pub fn widthPixels(m: *const Map) i32 {
        return @as(i32, m.header.width) * k.tile_size;
    }

    pub fn heightPixels(m: *const Map) i32 {
        return @as(i32, m.header.height) * k.tile_size;
    }

    /// Index into `tiles` of the tile under pixel (x, y), if on the map.
    pub fn tileIndexAt(m: *const Map, x: i32, y: i32) ?usize {
        if (x < 0 or y < 0 or x >= m.widthPixels() or y >= m.heightPixels()) return null;
        const tx: usize = @intCast(@divTrunc(x, k.tile_size));
        const ty: usize = @intCast(@divTrunc(y, k.tile_size));
        return ty * m.header.width + tx;
    }

    /// Properties of the tile under pixel (x, y), if on the map.
    pub fn tileInfoAt(m: *const Map, terrain: *const Terrain, x: i32, y: i32) ?TileInfo {
        const i = m.tileIndexAt(x, y) orelse return null;
        return terrain.palette(m.planet())[m.tiles[i]];
    }

    pub fn isRoad(m: *const Map, terrain: *const Terrain, x: i32, y: i32) bool {
        const info = m.tileInfoAt(terrain, x, y) orelse return false;
        return info.is_road;
    }

    /// Movement speed factor at pixel (x, y): 0 where impassable or off the
    /// map, faster on roads, slower in water.
    pub fn walkSpeed(m: *const Map, terrain: *const Terrain, x: i32, y: i32) f64 {
        const info = m.tileInfoAt(terrain, x, y) orelse return 0;
        if (!info.is_passable) return 0;
        if (info.is_road) return k.road_speed;
        if (info.is_water) return k.water_speed;
        return 1.0;
    }
};

/// A zone at runtime: the area a flag controls.
pub const Zone = struct {
    id: u32,
    owner: k.Team = .none,
    /// Area in pixels.
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn fromRect(id: u32, r: ZoneRect) Zone {
        return .{
            .id = id,
            .x = @as(i32, r.x) * k.tile_size,
            .y = @as(i32, r.y) * k.tile_size,
            .w = @as(i32, r.w) * k.tile_size,
            .h = @as(i32, r.h) * k.tile_size,
        };
    }

    /// Whether pixel (x, y) lies in the zone (edges included, as in the
    /// original).
    pub fn contains(z: Zone, x: i32, y: i32) bool {
        return x >= z.x and y >= z.y and x <= z.x + z.w and y <= z.y + z.h;
    }
};

/// The zone containing pixel (x, y), if any (first match wins).
pub fn zoneAt(zones: []Zone, x: i32, y: i32) ?*Zone {
    for (zones) |*z| if (z.contains(x, y)) return z;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every shipped map parses and writes back identically" {
    const io = testing.io;
    const gpa = testing.allocator;
    const roots = [_][]const u8{ "bin/blank_maps", "Data" };
    var count: usize = 0;
    for (roots) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".map")) continue;
            const bytes = try dir.readFileAlloc(io, entry.path, gpa, .limited(16 << 20));
            defer gpa.free(bytes);
            var m = Map.parse(gpa, bytes) catch |err| {
                std.debug.print("{s}/{s}: {t}\n", .{ root, entry.path, err });
                return err;
            };
            defer m.deinit(gpa);

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try m.write(&out.writer);
            try testing.expectEqualSlices(u8, bytes, out.written());
            count += 1;
        }
    }
    try testing.expect(count >= 130);
}

test "tile lookups and walk speed" {
    const io = testing.io;
    const gpa = testing.allocator;
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    const terrain = try gpa.create(Terrain);
    defer gpa.destroy(terrain);
    terrain.* = try Terrain.load(io, assets);

    var m = try Map.load(io, std.Io.Dir.cwd(), "Data/Campaing/Z_original/p02_bb_orig01.map", gpa);
    defer m.deinit(gpa);
    try testing.expect(m.header.width > 0 and m.placements.len > 0);
    try testing.expectEqual(@as(?usize, null), m.tileIndexAt(-1, 0));
    try testing.expectEqual(@as(?usize, null), m.tileIndexAt(m.widthPixels(), 0));
    try testing.expectEqual(@as(?usize, m.header.width + 2), m.tileIndexAt(2 * 16 + 5, 16 + 15));

    // Speeds are one of the known factors everywhere on the map.
    var y: i32 = 0;
    var roads: usize = 0;
    while (y < m.heightPixels()) : (y += 16) {
        var x: i32 = 0;
        while (x < m.widthPixels()) : (x += 16) {
            const s = m.walkSpeed(terrain, x, y);
            try testing.expect(s == 0 or s == 1 or s == k.road_speed or s == k.water_speed);
            if (s == k.road_speed) roads += 1;
        }
    }
    try testing.expect(roads > 0);
}

test "zones" {
    var zones = [_]Zone{ Zone.fromRect(0, .{ .x = 2, .y = 2, .w = 4, .h = 4 }), Zone.fromRect(1, .{ .x = 10, .y = 2, .w = 3, .h = 3 }) };
    try testing.expectEqual(@as(u32, 0), zoneAt(&zones, 32, 32).?.id);
    try testing.expectEqual(@as(u32, 0), zoneAt(&zones, 96, 96).?.id); // edge included
    try testing.expectEqual(@as(u32, 1), zoneAt(&zones, 170, 40).?.id);
    try testing.expect(zoneAt(&zones, 0, 0) == null);
}
