//! Passability grid, regions and A* path finding (from
//! QZod_DnMap/finding/zpath_finding_old.cpp).
//!
//! Robots are one tile wide and may walk through water; vehicles cover 2x2
//! tiles and may not. Objects such as buildings and rocks mark tiles
//! impassable; rocks and similar obstacles are "destroyable", and units
//! carrying explosives plan paths as if those were passable (the "no rocks"
//! layers).
//!
//! Unlike the original, paths are computed synchronously (maps are small, a
//! search takes well under a millisecond), with a proper A* (binary heap,
//! closed set).

const std = @import("std");
const k = @import("constants.zig");
const mapfmt = @import("map.zig");

pub const Point = struct { x: i32, y: i32 };

/// Terrain kind of a tile for path finding.
pub const TileKind = enum { normal, impassable, water, road };

const Layer = enum(u2) { robot, vehicle, robot_norocks, vehicle_norocks };

const Tile = struct {
    /// Passability per layer (bit index = Layer).
    passable: std.EnumSet(Layer) = .initEmpty(),
    /// Movement cost to enter this tile straight / diagonally (robots).
    side_weight: u32 = 0,
    diag_weight: u32 = 0,
    /// The same for vehicles, which cover 2x2 tiles.
    wide_side_weight: u32 = 0,
    wide_diag_weight: u32 = 0,
};

pub const Grid = struct {
    w: u16,
    h: u16,
    tiles: []Tile,
    /// Connected areas per unit kind; paths never cross regions.
    robot_region: []i32,
    vehicle_region: []i32,
    /// Scratch space for rebuildRegions.
    flood_queue: []u32,

    pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !Grid {
        const n = @as(usize, w) * h;
        const tiles = try gpa.alloc(Tile, n);
        errdefer gpa.free(tiles);
        @memset(tiles, .{});
        const robot_region = try gpa.alloc(i32, n);
        errdefer gpa.free(robot_region);
        const vehicle_region = try gpa.alloc(i32, n);
        errdefer gpa.free(vehicle_region);
        const flood_queue = try gpa.alloc(u32, n);
        @memset(robot_region, 0);
        @memset(vehicle_region, 0);
        return .{ .w = w, .h = h, .tiles = tiles, .robot_region = robot_region, .vehicle_region = vehicle_region, .flood_queue = flood_queue };
    }

    /// Grid for a map's terrain (before any objects are placed).
    pub fn fromMap(gpa: std.mem.Allocator, map: *const mapfmt.Map, terrain: *const mapfmt.Terrain) !Grid {
        var g = try init(gpa, map.header.width, map.header.height);
        const palette = terrain.palette(map.planet());
        for (map.tiles, 0..) |t, i| {
            const info = palette[t];
            const kind: TileKind = if (!info.is_passable) .impassable else if (info.is_water) .water else if (info.is_road) .road else .normal;
            g.setTileKind(@intCast(i % g.w), @intCast(i / g.w), kind);
        }
        g.computeWideWeights();
        g.rebuildRegions();
        return g;
    }

    pub fn deinit(g: *Grid, gpa: std.mem.Allocator) void {
        gpa.free(g.tiles);
        gpa.free(g.robot_region);
        gpa.free(g.vehicle_region);
        gpa.free(g.flood_queue);
        g.* = undefined;
    }

    fn index(g: *const Grid, tx: i32, ty: i32) ?usize {
        if (!g.onMap(tx, ty)) return null;
        return @as(usize, @intCast(ty)) * g.w + @as(usize, @intCast(tx));
    }

    pub fn onMap(g: *const Grid, tx: i32, ty: i32) bool {
        return tx >= 0 and ty >= 0 and tx < g.w and ty < g.h;
    }

    pub fn setTileKind(g: *Grid, tx: i32, ty: i32, kind: TileKind) void {
        const i = g.index(tx, ty) orelse return;
        const t = &g.tiles[i];
        const cost: f64 = switch (kind) {
            .normal, .impassable => 1.0,
            .water => 1.0 / k.water_speed,
            .road => 1.0 / (k.road_speed + 0.5),
        };
        const robot_ok = kind != .impassable;
        const vehicle_ok = kind == .normal or kind == .road;
        t.passable = .initEmpty();
        t.passable.setPresent(.robot, robot_ok);
        t.passable.setPresent(.robot_norocks, robot_ok);
        t.passable.setPresent(.vehicle, vehicle_ok);
        t.passable.setPresent(.vehicle_norocks, vehicle_ok);
        t.side_weight = @intFromFloat(100 * cost);
        t.diag_weight = @intFromFloat(1.414 * 100 * cost);
    }

    /// Vehicles occupy 2x2 tiles: their costs are the sum over that area.
    pub fn computeWideWeights(g: *Grid) void {
        for (0..g.h) |ty| for (0..g.w) |tx| {
            var side: u32 = 0;
            var diag: u32 = 0;
            for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |d| {
                const i = g.index(@intCast(tx + d[0]), @intCast(ty + d[1])) orelse continue;
                side += g.tiles[i].side_weight;
                diag += g.tiles[i].diag_weight;
            }
            const t = &g.tiles[ty * g.w + tx];
            t.wide_side_weight = side;
            t.wide_diag_weight = diag;
        };
    }

    /// Mark a tile blocked (or free again) by an object. `destroyable`
    /// obstacles can be blown up, so units with explosives ignore them.
    /// This overrides the terrain, which is how bridges make water passable.
    pub fn setImpassable(g: *Grid, tx: i32, ty: i32, impassable: bool, destroyable: bool) void {
        const i = g.index(tx, ty) orelse return;
        const t = &g.tiles[i];
        t.passable.setPresent(.robot, !impassable);
        t.passable.setPresent(.vehicle, !impassable);
        t.passable.setPresent(.robot_norocks, !impassable or destroyable);
        t.passable.setPresent(.vehicle_norocks, !impassable or destroyable);
    }

    fn passableIn(g: *const Grid, layer: Layer, tx: i32, ty: i32) bool {
        const i = g.index(tx, ty) orelse return false;
        return g.tiles[i].passable.contains(layer);
    }

    pub fn tilePassable(g: *const Grid, tx: i32, ty: i32, is_robot: bool) bool {
        return g.passableIn(if (is_robot) .robot else .vehicle, tx, ty);
    }

    /// A tile blocked only by something that can be destroyed.
    pub fn hasDestroyableBarrier(g: *const Grid, tx: i32, ty: i32) bool {
        return g.passableIn(.robot_norocks, tx, ty) and !g.passableIn(.robot, tx, ty);
    }

    /// If the pixel rectangle overlaps a blocked tile (or leaves the map),
    /// return that tile's top-left pixel.
    pub fn withinImpassable(g: *const Grid, x: i32, y: i32, w: i32, h: i32, is_robot: bool) ?Point {
        const width_pix = @as(i32, g.w) * k.tile_size;
        const height_pix = @as(i32, g.h) * k.tile_size;
        // Off the map counts as blocked (with no particular tile).
        if (x < 0 or y < 0 or x + w >= width_pix or y + h >= height_pix) return .{ .x = x, .y = y };

        const layer: Layer = if (is_robot) .robot else .vehicle;
        const tx = x >> 4;
        const ty = y >> 4;
        const tex = @min(tx + (w >> 4) + @intFromBool(@mod(w, 16) != 0), g.w - 1);
        const tey = @min(ty + (h >> 4) + @intFromBool(@mod(h, 16) != 0), g.h - 1);
        var i = tx;
        while (i <= tex) : (i += 1) {
            var j = ty;
            while (j <= tey) : (j += 1) {
                if (g.passableIn(layer, i, j)) continue;
                const px = i << 4;
                const py = j << 4;
                if (x >= px + 16 or y >= py + 16 or x + w <= px or y + h <= py) continue;
                return .{ .x = px, .y = py };
            }
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Regions
    // -----------------------------------------------------------------------

    /// Recompute the connected areas (after passability changed).
    pub fn rebuildRegions(g: *Grid) void {
        g.floodRegions(.robot, g.robot_region);
        g.floodRegions(.vehicle, g.vehicle_region);
    }

    fn floodRegions(g: *Grid, layer: Layer, region: []i32) void {
        for (region, g.tiles) |*r, t| r.* = if (t.passable.contains(layer)) -1 else -2;
        var next_region: i32 = 0;
        for (0..region.len) |start| {
            if (region[start] != -1) continue;
            // Breadth-first fill; every tile is queued at most once.
            region[start] = next_region;
            g.flood_queue[0] = @intCast(start);
            var head: usize = 0;
            var tail: usize = 1;
            while (head < tail) : (head += 1) {
                const i = g.flood_queue[head];
                const tx: i32 = @intCast(i % g.w);
                const ty: i32 = @intCast(i / g.w);
                for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
                    const ni = g.index(tx + d[0], ty + d[1]) orelse continue;
                    if (region[ni] != -1) continue;
                    region[ni] = next_region;
                    g.flood_queue[tail] = @intCast(ni);
                    tail += 1;
                }
            }
            next_region += 1;
        }
    }

    /// Whether two pixel positions are connected (positions off the map
    /// count as connected, like the original).
    pub fn inSameRegion(g: *const Grid, sx: i32, sy: i32, ex: i32, ey: i32, is_robot: bool) bool {
        const si = g.index(sx >> 4, sy >> 4) orelse return true;
        const ei = g.index(ex >> 4, ey >> 4) orelse return true;
        const region = if (is_robot) g.robot_region else g.vehicle_region;
        return region[si] == region[ei];
    }

    /// Whether a unit at (sx, sy) could reach (ex, ey) at all.
    pub fn shouldBeAbleToMoveTo(g: *const Grid, sx: i32, sy: i32, ex: i32, ey: i32, is_robot: bool) bool {
        if (!g.inSameRegion(sx, sy, ex, ey, is_robot)) return false;
        const tx = ex >> 4;
        const ty = ey >> 4;
        if (is_robot) return g.tilePassable(tx, ty, true);
        return g.tilePassable(tx, ty, false) and g.tilePassable(tx + 1, ty, false) and
            g.tilePassable(tx, ty + 1, false) and g.tilePassable(tx + 1, ty + 1, false);
    }

    // -----------------------------------------------------------------------
    // Paths
    // -----------------------------------------------------------------------

    fn layerFor(is_robot: bool, has_explosives: bool) Layer {
        return if (is_robot)
            (if (has_explosives) .robot_norocks else .robot)
        else
            (if (has_explosives) .vehicle_norocks else .vehicle);
    }

    /// Whether a unit can move in a straight line: checks the tiles within
    /// its half-width of the line (8 px robots, 16 px vehicles, plus margin).
    pub fn directPathPossible(g: *const Grid, sx: i32, sy: i32, ex: i32, ey: i32, is_robot: bool, has_explosives: bool) bool {
        if (sx == ex and sy == ey) return true;
        const crawl_dist = 4;
        const layer = layerFor(is_robot, has_explosives);

        var dx: f64 = @floatFromInt(ex - sx);
        var dy: f64 = @floatFromInt(ey - sy);
        var dist_left: i32 = @intFromFloat(@sqrt(dx * dx + dy * dy));
        const angle = std.math.atan2(@abs(dy), @abs(dx));
        const hyp = if (@abs(dx) > @abs(dy)) 1 / @cos(angle) else 1 / @sin(angle);
        const half: f64 = if (is_robot) 8 + 8 + 1 else 16 + 8 + 1;
        const bc: i32 = if (is_robot) 1 else 2;

        // Line through start and end: A*x + B*y + C = 0.
        const a: i64 = -(sy - ey);
        const b: i64 = sx - ex;
        const cc: i64 = -(a * sx + b * sy);
        const dist_check = half * hyp * @sqrt(@as(f64, @floatFromInt(a * a + b * b)));

        const len: f64 = @floatFromInt(@max(dist_left, 1));
        dx = dx / len * crawl_dist;
        dy = dy / len * crawl_dist;
        var x: f64 = @floatFromInt(sx);
        var y: f64 = @floatFromInt(sy);
        while (dist_left > 0) : (dist_left -= crawl_dist) {
            const ctx: i32 = @intFromFloat(@trunc(x / 16));
            const cty: i32 = @intFromFloat(@trunc(y / 16));
            var tx = ctx - bc;
            while (tx <= ctx + bc) : (tx += 1) {
                var ty = cty - bc;
                while (ty <= cty + bc) : (ty += 1) {
                    if (!g.onMap(tx, ty) or g.passableIn(layer, tx, ty)) continue;
                    const cx: i64 = tx * 16 + 8;
                    const cy: i64 = ty * 16 + 8;
                    if (dist_check >= @as(f64, @floatFromInt(@abs(a * cx + b * cy + cc)))) return false;
                }
            }
            x += dx;
            y += dy;
        }
        return true;
    }

    /// Whether a unit on tile (sx, sy) may step to tile (ex, ey).
    fn stepOk(g: *const Grid, layer: Layer, is_robot: bool, sx: i32, sy: i32, ex: i32, ey: i32) bool {
        const p = struct {
            fn ok(grid: *const Grid, l: Layer, x: i32, y: i32) bool {
                return grid.passableIn(l, x, y);
            }
        }.ok;
        if (is_robot) {
            if (!p(g, layer, ex, ey)) return false;
            if (ex == sx or ey == sy) return true;
            // No cutting corners diagonally.
            return p(g, layer, ex, sy) and p(g, layer, sx, ey);
        }
        if (ex + 1 >= g.w or ey + 1 >= g.h) return false;
        if (!(p(g, layer, ex, ey) and p(g, layer, ex + 1, ey) and p(g, layer, ex, ey + 1) and p(g, layer, ex + 1, ey + 1))) return false;
        if (ex == sx or ey == sy) return true;
        // The 2x2 body must not clip the corner tiles it sweeps past.
        if (ex > sx and ey < sy) return p(g, layer, sx, sy - 1) and p(g, layer, sx + 2, sy + 1);
        if (ex < sx and ey < sy) return p(g, layer, sx + 1, sy - 1) and p(g, layer, sx - 1, sy + 1);
        if (ex > sx and ey > sy) return p(g, layer, sx + 2, sy) and p(g, layer, sx, sy + 2);
        return p(g, layer, sx - 1, sy) and p(g, layer, sx + 1, sy + 2);
    }

    const Open = struct {
        f: u32,
        tile: u32,

        fn order(_: void, a: Open, b: Open) std.math.Order {
            return std.math.order(a.f, b.f);
        }
    };

    /// Path from pixel (sx, sy) to (ex, ey) as pixel waypoints ending exactly
    /// at the destination, or null when the unit should just move straight
    /// there (a direct line is free, or no path exists). The caller owns the
    /// returned slice.
    pub fn findPath(g: *const Grid, gpa: std.mem.Allocator, sx: i32, sy: i32, ex: i32, ey: i32, is_robot: bool, has_explosives: bool) !?[]Point {
        if (g.directPathPossible(sx, sy, ex, ey, is_robot, has_explosives)) return null;
        if (!g.inSameRegion(sx, sy, ex, ey, is_robot)) return null;

        const layer = layerFor(is_robot, has_explosives);
        const start_x = @divTrunc(sx, 16);
        const start_y = @divTrunc(sy, 16);
        const end_x = @divTrunc(ex, 16);
        const end_y = @divTrunc(ey, 16);

        var path: std.ArrayList(Point) = .empty;
        errdefer path.deinit(gpa);

        if (g.stepOk(layer, is_robot, start_x, start_y, start_x, start_y) and
            g.stepOk(layer, is_robot, end_x, end_y, end_x, end_y))
        {
            try g.astar(gpa, layer, is_robot, start_x, start_y, end_x, end_y, &path);
        }
        // Tile centers for robots; vehicles steer by their 2x2 center.
        const offset: i32 = if (is_robot) 8 else 16;
        for (path.items) |*pt| pt.* = .{ .x = pt.x * 16 + offset, .y = pt.y * 16 + offset };
        try path.append(gpa, .{ .x = ex, .y = ey });
        return try path.toOwnedSlice(gpa);
    }

    /// A* over tiles; appends the path's turning points (tile coordinates,
    /// start included, end tile last) or nothing if there is no path.
    fn astar(g: *const Grid, gpa: std.mem.Allocator, layer: Layer, is_robot: bool, start_x: i32, start_y: i32, end_x: i32, end_y: i32, path: *std.ArrayList(Point)) !void {
        const n = g.tiles.len;
        const cost = try gpa.alloc(u32, n);
        defer gpa.free(cost);
        const parent = try gpa.alloc(u32, n);
        defer gpa.free(parent);
        var closed = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n);
        defer closed.deinit(gpa);
        @memset(cost, std.math.maxInt(u32));

        var open: std.PriorityQueue(Open, void, Open.order) = .empty;
        defer open.deinit(gpa);

        const start = g.index(start_x, start_y).?;
        const goal = g.index(end_x, end_y).?;
        cost[start] = 0;
        parent[start] = @intCast(start);
        try open.push(gpa, .{ .f = heuristic(start_x, start_y, end_x, end_y), .tile = @intCast(start) });

        while (open.pop()) |cur| {
            if (closed.isSet(cur.tile)) continue;
            if (cur.tile == goal) break;
            closed.set(cur.tile);
            const cx: i32 = @intCast(cur.tile % g.w);
            const cy: i32 = @intCast(cur.tile / g.w);
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const nx = cx + dx;
                    const ny = cy + dy;
                    if (!g.stepOk(layer, is_robot, cx, cy, nx, ny)) continue;
                    const ni = g.index(nx, ny).?;
                    if (closed.isSet(ni)) continue;
                    const t = g.tiles[ni];
                    const straight = dx == 0 or dy == 0;
                    const step = if (is_robot)
                        (if (straight) t.side_weight else t.diag_weight)
                    else
                        (if (straight) t.wide_side_weight else t.wide_diag_weight);
                    const new_cost = cost[cur.tile] + step;
                    if (new_cost >= cost[ni]) continue;
                    cost[ni] = new_cost;
                    parent[ni] = cur.tile;
                    try open.push(gpa, .{ .f = new_cost + heuristic(nx, ny, end_x, end_y), .tile = @intCast(ni) });
                }
            }
        }
        if (cost[goal] == std.math.maxInt(u32)) return;

        // Walk back from the goal, keeping only the points where the
        // direction changes.
        var tiles: std.ArrayList(u32) = .empty;
        defer tiles.deinit(gpa);
        var i: u32 = @intCast(goal);
        while (true) {
            try tiles.append(gpa, i);
            if (i == start) break;
            i = parent[i];
        }
        std.mem.reverse(u32, tiles.items);
        for (tiles.items, 0..) |ti, j| {
            if (j > 0 and j + 1 < tiles.items.len) {
                const prev = tiles.items[j - 1];
                const next = tiles.items[j + 1];
                if (@as(i64, ti) - prev == @as(i64, next) - ti) continue; // straight on
            }
            try path.append(gpa, .{ .x = @intCast(ti % g.w), .y = @intCast(ti / g.w) });
        }
    }

    fn heuristic(x: i32, y: i32, ex: i32, ey: i32) u32 {
        // Manhattan distance in tiles, as in the original (the edge costs
        // are ~100 per tile, so it guides the search without dominating).
        return @abs(x - ex) + @abs(y - ey);
    }

    /// Whether a destroyable obstacle lies on the line between two pixel
    /// positions (units don't engage through rocks and the like).
    pub fn engageBarrierBetween(g: *const Grid, x1: i32, y1: i32, x2: i32, y2: i32) bool {
        inline for (.{ .{ x1, y1, x2, y2 }, .{ x2, y2, x1, y1 } }) |l| {
            var line = Line.init(l[0] >> 4, l[1] >> 4, l[2] >> 4, l[3] >> 4, g.w, g.h);
            while (line.next()) |p| if (g.hasDestroyableBarrier(p.x, p.y)) return true;
        }
        return false;
    }
};

/// Bresenham line over tiles, excluding the start tile.
pub const Line = struct {
    valid: bool = false,
    ex: i32 = 0,
    ey: i32 = 0,
    nx: i32 = 0,
    ny: i32 = 0,
    dx: i32 = 0,
    dy: i32 = 0,
    step_x: i32 = 0,
    step_y: i32 = 0,
    fraction: i32 = 0,

    /// An empty line if either end is off the (w x h) map.
    pub fn init(sx: i32, sy: i32, ex: i32, ey: i32, w: i32, h: i32) Line {
        if (sx < 0 or sy < 0 or sx >= w or sy >= h or ex < 0 or ey < 0 or ex >= w or ey >= h) return .{};
        const dx = @abs(ex - sx) * 2;
        const dy = @abs(ey - sy) * 2;
        const dxi: i32 = @intCast(dx);
        const dyi: i32 = @intCast(dy);
        return .{
            .valid = true,
            .ex = ex,
            .ey = ey,
            .nx = sx,
            .ny = sy,
            .dx = dxi,
            .dy = dyi,
            .step_x = if (ex < sx) -1 else 1,
            .step_y = if (ey < sy) -1 else 1,
            .fraction = if (dyi > dxi) dxi * 2 - dyi else dyi * 2 - dxi,
        };
    }

    pub fn next(l: *Line) ?Point {
        if (!l.valid) return null;
        if (l.dy > l.dx) {
            if (l.ny == l.ey) return null;
            if (l.fraction >= 0) {
                l.nx += l.step_x;
                l.fraction -= l.dy;
            }
            l.ny += l.step_y;
            l.fraction += l.dx;
        } else {
            if (l.nx == l.ex) return null;
            if (l.fraction >= 0) {
                l.ny += l.step_y;
                l.fraction -= l.dx;
            }
            l.nx += l.step_x;
            l.fraction += l.dy;
        }
        return .{ .x = l.nx, .y = l.ny };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a grid from ASCII art: '.' normal, '#' impassable, '~' water, '='
/// road, 'r' destroyable rock.
fn testGrid(comptime rows: []const []const u8) !Grid {
    var g = try Grid.init(testing.allocator, @intCast(rows[0].len), @intCast(rows.len));
    for (rows, 0..) |row, y| for (row, 0..) |ch, x| {
        const tx: i32 = @intCast(x);
        const ty: i32 = @intCast(y);
        g.setTileKind(tx, ty, switch (ch) {
            '#' => .impassable,
            '~' => .water,
            '=' => .road,
            else => .normal,
        });
        if (ch == 'r') g.setImpassable(tx, ty, true, true);
    };
    g.computeWideWeights();
    g.rebuildRegions();
    return g;
}

test "robots path around a wall" {
    var g = try testGrid(&.{
        "..........",
        "....#.....",
        "....#.....",
        "..........",
        "..........",
    });
    defer g.deinit(testing.allocator);

    // Direct line blocked by the wall: a path is needed.
    const path = (try g.findPath(testing.allocator, 1 * 16 + 8, 2 * 16 + 8, 8 * 16 + 8, 2 * 16 + 8, true, false)).?;
    defer testing.allocator.free(path);
    try testing.expectEqual(Point{ .x = 8 * 16 + 8, .y = 2 * 16 + 8 }, path[path.len - 1]);
    // No waypoint lies inside the wall.
    for (path) |p| try testing.expect(g.tilePassable(p.x >> 4, p.y >> 4, true));

    // An open straight line needs no path (the check keeps 17 px of
    // clearance from blocked tiles, so use the bottom row).
    try testing.expect((try g.findPath(testing.allocator, 8, 4 * 16 + 8, 9 * 16 + 8, 4 * 16 + 8, true, false)) == null);
}

test "water blocks vehicles but not robots" {
    var g = try testGrid(&.{
        "..~~..",
        "..~~..",
        "..~~..",
        "..~~..",
    });
    defer g.deinit(testing.allocator);
    try testing.expect(g.inSameRegion(8, 8, 5 * 16, 8, true));
    try testing.expect(!g.inSameRegion(8, 8, 5 * 16, 8, false));
    try testing.expect(!g.shouldBeAbleToMoveTo(8, 8, 5 * 16, 8, false));
}

test "units with explosives plan through rocks" {
    var g = try testGrid(&.{
        "#####",
        ".....",
        "..r..",
        ".....",
        "#####",
    });
    defer g.deinit(testing.allocator);
    try testing.expect(!g.directPathPossible(8, 40, 4 * 16 + 8, 40, true, false));
    try testing.expect(g.directPathPossible(8, 40, 4 * 16 + 8, 40, true, true));
    try testing.expect(g.hasDestroyableBarrier(2, 2));
    try testing.expect(g.engageBarrierBetween(8, 40, 4 * 16 + 8, 40));
}

test "impassable rectangle check" {
    var g = try testGrid(&.{
        "......",
        "..#...",
        "......",
    });
    defer g.deinit(testing.allocator);
    try testing.expect(g.withinImpassable(0, 0, 16, 16, true) == null);
    try testing.expectEqual(Point{ .x = 32, .y = 16 }, g.withinImpassable(20, 10, 16, 16, true).?);
    try testing.expect(g.withinImpassable(-1, 0, 8, 8, true) != null); // off the map
}

test "bresenham line" {
    var l = Line.init(0, 0, 3, 1, 10, 10);
    var pts: [8]Point = undefined;
    var n: usize = 0;
    while (l.next()) |p| : (n += 1) pts[n] = p;
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Point{ .x = 3, .y = 1 }, pts[2]);
}

test "every shipped map builds a grid" {
    const io = testing.io;
    const gpa = testing.allocator;
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    const terrain = try gpa.create(mapfmt.Terrain);
    defer gpa.destroy(terrain);
    terrain.* = try mapfmt.Terrain.load(io, assets);
    var m = try mapfmt.Map.load(io, std.Io.Dir.cwd(), "Data/Campaing/Z_original/p02_bb_orig01.map", gpa);
    defer m.deinit(gpa);
    var g = try Grid.fromMap(gpa, &m, terrain);
    defer g.deinit(gpa);
    // Find some path between the two most distant passable robot tiles.
    var first: ?usize = null;
    var last: ?usize = null;
    for (g.tiles, 0..) |t, i| if (t.passable.contains(.robot)) {
        if (first == null) first = i;
        last = i;
    };
    const a = first.?;
    const b = last.?;
    if (g.robot_region[a] == g.robot_region[b]) {
        const path = try g.findPath(gpa, @intCast(a % g.w * 16 + 8), @intCast(a / g.w * 16 + 8), @intCast(b % g.w * 16 + 8), @intCast(b / g.w * 16 + 8), true, false);
        if (path) |p| gpa.free(p);
    }
}
