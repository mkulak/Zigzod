//! Drawing the map: the ground (prerendered from the planet's tile sheet),
//! animated water and lava tiles, and the zone border markers in their
//! owner's color (from ZMap in QZod_DnMap).

const std = @import("std");
const k = @import("../game/constants.zig");
const mapfmt = @import("../game/map.zig");
const gfx = @import("gfx.zig");

const Image = gfx.Image;
const tile = k.tile_size;
const sheet_columns = 20;

/// Images shared by all maps.
pub const Sheets = struct {
    planets: [k.Planet.count]?Image = @splat(null),
    zone_marker: gfx.TeamImages = @splat(null),
    zone_marker_water: gfx.TeamImages = @splat(null),

    pub fn load(assets: []const u8, palettes: *const gfx.TeamPalettes) Sheets {
        var s: Sheets = .{};
        for (&s.planets, 0..) |*p, i| {
            var buf: [256]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/planets/{s}.bmp", .{ assets, @tagName(@as(k.Planet, @enumFromInt(i))) }) catch continue;
            p.* = Image.load(path);
        }
        s.zone_marker = gfx.loadTeamImages(palettes, "{s}/planets/zone_marker_{s}.png", .{assets});
        s.zone_marker_water = gfx.loadTeamImages(palettes, "{s}/planets/zone_marker_water_{s}.png", .{assets});
        return s;
    }

    pub fn deinit(s: *Sheets) void {
        for (s.planets) |p| if (p) |img| img.deinit();
        gfx.freeTeamImages(&s.zone_marker);
        gfx.freeTeamImages(&s.zone_marker_water);
    }
};

const Animated = struct {
    tile: u32,
    next_time: f64 = 0,
};

const Marker = struct {
    x: i32,
    y: i32,
    zone: usize,
    water: bool,
    bob: bool = false,
    next_time: f64 = 0,
};

pub const Terrain = struct {
    gpa: std.mem.Allocator,
    sheets: *const Sheets,
    sheet: Image,
    palette: *const mapfmt.Palette,
    planet: k.Planet,
    width: u32,
    height: u32,
    /// The whole map; craters are stamped onto it.
    ground: Image,
    /// Current tile of each map tile (animations change them).
    tiles: []u16,
    /// Tiles in the middle of an animation, drawn over `ground`.
    animating: std.ArrayList(Animated) = .empty,
    /// Still water, which now and then starts to ripple.
    water: std.ArrayList(Animated) = .empty,
    /// Sheet tiles of still water and of ripples.
    water_tiles: std.ArrayList(u16) = .empty,
    ripple_tiles: std.ArrayList(u16) = .empty,
    markers: std.ArrayList(Marker) = .empty,

    pub fn init(gpa: std.mem.Allocator, sheets: *const Sheets, terrain: *const mapfmt.Terrain, m: *const mapfmt.Map, rng: std.Random) !Terrain {
        const sheet = sheets.planets[m.header.terrain] orelse return error.MissingTileSheet;
        const ground = Image.create(m.widthPixels(), m.heightPixels()) orelse return error.OutOfMemory;
        errdefer ground.deinit();
        // Blits keep the target's alpha, so start opaque.
        ground.fill(null, .{ .r = 0, .g = 0, .b = 0 });
        const palette = terrain.palette(m.planet());

        var t: Terrain = .{
            .gpa = gpa,
            .sheets = sheets,
            .sheet = sheet,
            .palette = palette,
            .planet = m.planet(),
            .width = m.header.width,
            .height = m.header.height,
            .ground = ground,
            .tiles = try gpa.dupe(u16, m.tiles),
        };
        errdefer t.deinit();

        for (palette, 0..) |info, i| {
            if (!info.is_usable) continue;
            if (info.is_water and !info.is_effect) try t.water_tiles.append(gpa, @intCast(i));
            if (info.is_water_effect) try t.ripple_tiles.append(gpa, @intCast(i));
        }

        for (t.tiles, 0..) |*tl, i| {
            const info = palette[tl.*];
            if (!info.is_usable) continue;
            // Desert maps start with calm water.
            if (t.planet == .desert and info.is_water and info.is_effect and t.water_tiles.items.len > 0) {
                tl.* = t.water_tiles.items[rng.uintLessThan(usize, t.water_tiles.items.len)];
                try t.water.append(gpa, .{ .tile = @intCast(i) });
                continue;
            }
            if (info.is_effect) try t.animating.append(gpa, .{ .tile = @intCast(i) });
            if (info.is_water and !info.is_effect) try t.water.append(gpa, .{ .tile = @intCast(i) });
        }

        for (t.tiles, 0..) |_, i| t.drawTile(ground, @intCast(i), 0, 0);
        try t.findMarkers(m);
        return t;
    }

    pub fn deinit(t: *Terrain) void {
        const gpa = t.gpa;
        t.ground.deinit();
        gpa.free(t.tiles);
        t.animating.deinit(gpa);
        t.water.deinit(gpa);
        t.water_tiles.deinit(gpa);
        t.ripple_tiles.deinit(gpa);
        t.markers.deinit(gpa);
    }

    fn sheetRect(index: u16) gfx.Rect {
        return .{ .x = (index % sheet_columns) * tile, .y = (index / sheet_columns) * tile, .w = tile, .h = tile };
    }

    fn tilePos(t: *const Terrain, i: u32) [2]i32 {
        return .{ @intCast((i % t.width) * tile), @intCast((i / t.width) * tile) };
    }

    fn drawTile(t: *const Terrain, dst: Image, i: u32, dx: i32, dy: i32) void {
        const p = t.tilePos(i);
        dst.draw(t.sheet, sheetRect(t.tiles[i]), p[0] + dx, p[1] + dy);
    }

    /// Markers along each zone's border, on passable tiles.
    fn findMarkers(t: *Terrain, m: *const mapfmt.Map) !void {
        for (m.zones, 0..) |z, zi| {
            var edge: std.ArrayList([2]u32) = .empty;
            defer edge.deinit(t.gpa);
            var j: u32 = 1;
            while (j + 1 < z.w) : (j += 1) {
                try edge.append(t.gpa, .{ z.x + j, z.y });
                try edge.append(t.gpa, .{ z.x + j, z.y + z.h - 1 });
            }
            j = 0;
            while (j < z.h) : (j += 1) {
                try edge.append(t.gpa, .{ z.x, z.y + j });
                try edge.append(t.gpa, .{ z.x + z.w - 1, z.y + j });
            }
            for (edge.items) |e| {
                if (e[0] >= t.width or e[1] >= t.height) continue;
                const info = t.palette[t.tiles[e[1] * t.width + e[0]]];
                if (!info.is_passable) continue;
                try t.markers.append(t.gpa, .{
                    .x = @intCast(e[0] * tile + 6),
                    .y = @intCast(e[1] * tile + 6),
                    .zone = zi,
                    .water = info.is_water,
                });
            }
        }
    }

    /// Draw the visible part of the map. `cv` maps map coordinates to the
    /// screen; `view` is the visible map area.
    pub fn draw(t: *Terrain, cv: gfx.Canvas, view: gfx.Rect, time: f64, zones: []const mapfmt.Zone, rng: std.Random) void {
        cv.drawPart(t.ground, view, view.x, view.y);
        t.animate(cv, view, time, rng);
        for (t.markers.items) |*mk| {
            const owner = if (mk.zone < zones.len) zones[mk.zone].owner else .none;
            const images = if (mk.water) &t.sheets.zone_marker_water else &t.sheets.zone_marker;
            const img = images[@intFromEnum(owner)] orelse continue;
            if (!view.contains(mk.x, mk.y) and !view.contains(mk.x + img.width(), mk.y + img.height())) continue;
            var y = mk.y;
            if (mk.water) {
                // Markers on water bob up and down.
                if (time > mk.next_time) {
                    mk.bob = !mk.bob;
                    mk.next_time = time + 0.5 + 0.3 * rng.float(f64);
                }
                if (mk.bob) y += 1;
            }
            cv.draw(img, mk.x, y);
        }
    }

    fn animate(t: *Terrain, cv: gfx.Canvas, view: gfx.Rect, time: f64, rng: std.Random) void {
        const interval: f64 = switch (t.planet) {
            .volcanic => 0.5,
            .arctic => 0.4,
            else => 0.2,
        };
        var i: usize = 0;
        while (i < t.animating.items.len) {
            const a = &t.animating.items[i];
            if (time >= a.next_time) {
                a.next_time = time + interval + @as(f64, @floatFromInt(rng.uintLessThan(u32, 4))) * 0.033;
                t.tiles[a.tile] = t.palette[t.tiles[a.tile]].next_tile_in_effect;
                // A ripple ends in calm water again.
                if (t.palette[t.tiles[a.tile]].is_water_effect and t.water_tiles.items.len > 0) {
                    t.tiles[a.tile] = t.water_tiles.items[rng.uintLessThan(usize, t.water_tiles.items.len)];
                    t.drawTile(t.ground, a.tile, 0, 0);
                    _ = t.animating.swapRemove(i);
                    continue;
                }
            }
            const p = t.tilePos(a.tile);
            if ((gfx.Rect{ .x = p[0], .y = p[1], .w = tile, .h = tile }).intersect(view) != null) {
                cv.drawPart(t.sheet, sheetRect(t.tiles[a.tile]), p[0], p[1]);
            }
            i += 1;
        }

        if (t.ripple_tiles.items.len == 0) return;
        for (t.water.items) |*wt| {
            if (time < wt.next_time) continue;
            wt.next_time = time + interval + @as(f64, @floatFromInt(rng.uintLessThan(u32, 4))) * 0.033;
            if (t.palette[t.tiles[wt.tile]].is_effect) continue;
            if (rng.uintLessThan(u32, 40) != 0) continue;
            t.animating.append(t.gpa, .{ .tile = wt.tile }) catch return;
            t.tiles[wt.tile] = t.ripple_tiles.items[rng.uintLessThan(usize, t.ripple_tiles.items.len)];
        }
    }

    /// Paint an image permanently onto the ground (craters, wreckage).
    pub fn stamp(t: *Terrain, img: Image, x: i32, y: i32) void {
        t.ground.draw(img, null, x, y);
    }
};

test "render a map and animate it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    const info = try gpa.create(mapfmt.Terrain);
    defer gpa.destroy(info);
    info.* = try mapfmt.Terrain.load(io, assets);
    var m = try mapfmt.Map.load(io, std.Io.Dir.cwd(), "Data/Campaing/Z_original/p02_bb_orig01.map", gpa);
    defer m.deinit(gpa);

    const palettes = gfx.TeamPalettes.load("bin/assets");
    var sheets = Sheets.load("bin/assets", &palettes);
    defer sheets.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    var t = try Terrain.init(gpa, &sheets, info, &m, prng.random());
    defer t.deinit();
    try std.testing.expect(t.markers.items.len > 0);

    // The first tile of the ground is the sheet's tile.
    const first = Terrain.sheetRect(t.tiles[0]);
    try std.testing.expectEqual(sheets.planets[m.header.terrain].?.pixel(first.x + 3, first.y + 5), t.ground.pixel(3, 5));

    const screen = Image.create(640, 480).?;
    defer screen.deinit();
    screen.fill(null, .{ .r = 0, .g = 0, .b = 0 });
    var zones = [_]mapfmt.Zone{mapfmt.Zone.fromRect(0, m.zones[0])};
    zones[0].owner = .blue;
    const view = gfx.Rect{ .x = 100, .y = 50, .w = 540, .h = 444 };
    const cv: gfx.Canvas = .{ .target = screen, .clip = .{ .x = 0, .y = 0, .w = 540, .h = 444 }, .dx = -view.x, .dy = -view.y };
    var time: f64 = 0;
    while (time < 5) : (time += 0.05) t.draw(cv, view, time, &zones, prng.random());
    try std.testing.expectEqual(t.ground.pixel(100, 50), screen.pixel(0, 0));
}
