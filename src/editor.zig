//! The map editor (zod_map_editor): paints tiles, places buildings, guns,
//! vehicles, robots and items, draws zones, undoes and redoes, and saves
//! `.map` files.
//!
//! The map file's contents (tiles, placements, zones) are the model; after
//! each change the game world and its picture are rebuilt from them with
//! the game's own rules and the client's renderers, so the editor shows
//! exactly what a game on the map will look like.

const std = @import("std");
const fit = @import("text.zig").fit;
const c = @import("c");
const game = @import("game.zig");
const gfx = @import("client/gfx.zig");
const terrain_mod = @import("client/terrain.zig");
const font = @import("client/font.zig");
const Sprites = @import("client/sprites.zig").Sprites;
const Renderer = @import("client/objects.zig").Renderer;
const Effects = @import("client/effects.zig").Effects;
const Display = @import("client/display.zig").Display;

const k = game.constants;
const mapfmt = game.map;
const Placement = mapfmt.Placement;
const ZoneRect = mapfmt.ZoneRect;
const Object = game.object.Object;
const World = game.world.World;
const Image = gfx.Image;
const Assets = @import("client/assets.zig").Assets;
const Canvas = gfx.Canvas;
const Rect = gfx.Rect;
const tile = k.tile_size;

// Layout: the tile sheet at the top left, the minimap and information
// under it, a gap, the map on the right.
const panel_w = mapfmt.palette_width * tile;
const palette_h = mapfmt.palette_height * tile;
const map_x = panel_w + 16;
const minimap_x = 5;
const minimap_y = 400;
const minimap_size = 150;
const scroll_speed = 800.0;
const max_undo = 5000;
/// Ref id of the object shown under the mouse.
const preview_id = -100;

pub const Mode = enum {
    tiles,
    buildings,
    guns,
    vehicles,
    robots,
    items,
    zones,
    remove_zones,
    remove_objects,

    fn objectType(m: Mode) ?k.ObjectType {
        return switch (m) {
            .buildings => .building,
            .guns => .cannon,
            .vehicles => .vehicle,
            .robots => .robot,
            .items => .map_item,
            else => null,
        };
    }

    fn objects(m: Mode) u8 {
        return switch (m) {
            .buildings => k.Building.count,
            .guns => k.Cannon.count,
            .vehicles => k.Vehicle.count,
            .robots => k.Robot.count,
            .items => k.Item.count,
            else => 0,
        };
    }
};

pub const NewMap = struct {
    width: u16,
    height: u16,
    planet: k.Planet = .desert,
    name: []const u8,
};

pub const Options = struct {
    /// The map file (loaded unless `new`, saved with S).
    path: []const u8,
    new: ?NewMap = null,
};

/// One reversible change to the map.
const Edit = union(enum) {
    tile: struct { index: u32, from: u16, to: u16 },
    place: Placement,
    remove: Placement,
    add_zone: ZoneRect,
    remove_zone: ZoneRect,

    fn inverse(e: Edit) Edit {
        return switch (e) {
            .tile => |t| .{ .tile = .{ .index = t.index, .from = t.to, .to = t.from } },
            .place => |p| .{ .remove = p },
            .remove => |p| .{ .place = p },
            .add_zone => |z| .{ .remove_zone = z },
            .remove_zone => |z| .{ .add_zone = z },
        };
    }
};

/// Edits made by one mouse stroke are undone together.
const Step = struct { group: u32, edit: Edit };

/// The map being edited: what a .map file holds.
pub const Model = struct {
    gpa: std.mem.Allocator,
    header: mapfmt.Header,
    tiles: []u16,
    placements: std.ArrayList(Placement) = .empty,
    zones: std.ArrayList(ZoneRect) = .empty,

    pub fn fromMap(gpa: std.mem.Allocator, m: *const mapfmt.Map) !Model {
        var model: Model = .{ .gpa = gpa, .header = m.header, .tiles = try gpa.dupe(u16, m.tiles) };
        errdefer model.deinit();
        try model.placements.appendSlice(gpa, m.placements);
        try model.zones.appendSlice(gpa, m.zones);
        return model;
    }

    /// A new map covered with the planet's starter tiles.
    pub fn new(gpa: std.mem.Allocator, info: *const mapfmt.Terrain, n: NewMap, rng: std.Random) !Model {
        var header = std.mem.zeroes(mapfmt.Header);
        header.width = n.width;
        header.height = n.height;
        header.player_count = 2;
        header.terrain = @intFromEnum(n.planet);
        const len = @min(n.name.len, header.name.len - 1);
        @memcpy(header.name[0..len], n.name[0..len]);
        const tiles = try gpa.alloc(u16, @as(usize, n.width) * n.height);
        var starters: std.ArrayList(u16) = .empty;
        defer starters.deinit(gpa);
        for (info.palette(n.planet), 0..) |t, i| if (t.is_starter_tile) try starters.append(gpa, @intCast(i));
        for (tiles) |*t| t.* = if (starters.items.len > 0) starters.items[rng.uintLessThan(usize, starters.items.len)] else 0;
        return .{ .gpa = gpa, .header = header, .tiles = tiles };
    }

    pub fn deinit(m: *Model) void {
        m.gpa.free(m.tiles);
        m.placements.deinit(m.gpa);
        m.zones.deinit(m.gpa);
    }

    /// The map file's bytes.
    pub fn bytes(m: *const Model) ![]u8 {
        const view: mapfmt.Map = .{ .header = m.header, .zones = m.zones.items, .placements = m.placements.items, .tiles = m.tiles };
        var out: std.Io.Writer.Allocating = .init(m.gpa);
        errdefer out.deinit();
        view.write(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    pub fn planet(m: *const Model) k.Planet {
        return @enumFromInt(m.header.terrain);
    }

    fn placementAt(m: *const Model, tx: i32, ty: i32) ?usize {
        for (m.placements.items, 0..) |p, i| if (p.x == tx and p.y == ty) return i;
        return null;
    }

    /// The zone covering tile (tx, ty) (the last one added, if several).
    fn zoneAt(m: *const Model, tx: i32, ty: i32) ?usize {
        var i = m.zones.items.len;
        while (i > 0) {
            i -= 1;
            const z = m.zones.items[i];
            if (tx >= z.x and ty >= z.y and tx < @as(i32, z.x) + z.w and ty < @as(i32, z.y) + z.h) return i;
        }
        return null;
    }

    /// Make a change; false if it doesn't apply (the map is unchanged).
    pub fn apply(m: *Model, e: Edit) !bool {
        switch (e) {
            .tile => |t| {
                if (t.index >= m.tiles.len or m.tiles[t.index] == t.to) return false;
                m.tiles[t.index] = t.to;
            },
            .place => |p| {
                if (m.placementAt(p.x, p.y) != null) return false;
                try m.placements.append(m.gpa, p);
            },
            .remove => |p| {
                for (m.placements.items, 0..) |q, i| if (std.meta.eql(p, q)) {
                    _ = m.placements.orderedRemove(i);
                    return true;
                };
                return false;
            },
            .add_zone => |z| {
                if (z.w == 0 or z.h == 0 or @as(u32, z.x) + z.w > m.header.width or @as(u32, z.y) + z.h > m.header.height) return false;
                for (m.zones.items) |q| if (q.x == z.x and q.y == z.y) return false;
                try m.zones.append(m.gpa, z);
            },
            .remove_zone => |z| {
                for (m.zones.items, 0..) |q, i| if (std.meta.eql(z, q)) {
                    _ = m.zones.orderedRemove(i);
                    return true;
                };
                return false;
            },
        }
        return true;
    }
};

pub const Editor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// All the art.
    assets: *Assets,
    path: []const u8,
    display: Display,
    width: i32 = 800,
    height: i32 = 600,

    terrain_info: *mapfmt.Terrain,
    sheets: terrain_mod.Sheets,
    fonts: *const font.Fonts,
    sprites: *Sprites,
    fx: *Effects,
    objects: Renderer,

    model: Model,
    /// The game on the map as it would start, rebuilt after changes.
    world: World,
    ground: ?terrain_mod.Terrain = null,
    dirty: bool = true,
    minimap: ?Image = null,
    changed: bool = false,
    undo: std.ArrayList(Step) = .empty,
    redo: std.ArrayList(Step) = .empty,
    group: u32 = 0,

    mode: Mode = .tiles,
    team: k.Team = .none,
    object: u8 = 0,
    level: u8 = 0,
    extra_links: u16 = 0,
    health: i32 = 100,
    /// Tiles painted with (one picked at random for each tile).
    brush: std.ArrayList(u16) = .empty,
    /// A zone being dragged out, from this tile.
    zone_start: ?[2]i32 = null,
    ruler: enum { off, edges, grid } = .off,
    status_buf: [160]u8 = undefined,
    status: []const u8 = "",
    status_until: f64 = 0,

    view_x: i32 = 0,
    view_y: i32 = 0,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    left_down: bool = false,
    keys: struct { left: bool = false, right: bool = false, up: bool = false, down: bool = false, ctrl: bool = false, shift: bool = false } = .{},
    prng: std.Random.DefaultPrng,
    clock_origin: std.Io.Timestamp,
    last_frame: f64 = 0,
    quit: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_path: []const u8, options: Options) !*Editor {
        const e = try create(gpa, io, data_path, options);
        errdefer e.deinit();
        try e.rebuild();
        return e;
    }

    fn create(gpa: std.mem.Allocator, io: std.Io, data_path: []const u8, options: Options) !*Editor {
        const dir = try std.fmt.allocPrint(gpa, "{s}/assets", .{data_path});
        defer gpa.free(dir);
        const assets = try Assets.init(gpa, dir);
        errdefer assets.deinit();
        const terrain_info = try gpa.create(mapfmt.Terrain);
        errdefer gpa.destroy(terrain_info);
        {
            var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
            defer d.close(io);
            terrain_info.* = try mapfmt.Terrain.load(io, d);
        }
        const seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)));
        var prng: std.Random.DefaultPrng = .init(seed);

        var model = if (options.new) |n| try Model.new(gpa, terrain_info, n, prng.random()) else blk: {
            var m = try mapfmt.Map.load(io, std.Io.Dir.cwd(), options.path, gpa);
            defer m.deinit(gpa);
            break :blk try Model.fromMap(gpa, &m);
        };
        errdefer model.deinit();

        var display = try Display.open(gpa, "Zod Map Editor", 800, 600, false);
        errdefer display.close();

        const sheets = try terrain_mod.Sheets.load(assets);
        const fonts = try font.Fonts.load(assets);
        const sprites = try Sprites.load(assets);
        const fx = try Effects.create(gpa, sprites, &assets.palettes, seed +% 1);
        errdefer fx.destroy();

        const e = try gpa.create(Editor);
        e.* = .{
            .gpa = gpa,
            .io = io,
            .assets = assets,
            .path = options.path,
            .display = display,
            .terrain_info = terrain_info,
            .sheets = sheets,
            .fonts = fonts,
            .sprites = sprites,
            .fx = fx,
            .objects = blk: {
                var r: Renderer = .init(gpa, sprites, fonts, fx);
                r.animals = false;
                break :blk r;
            },
            .model = model,
            .world = World.init(gpa, terrain_info, seed),
            .prng = prng,
            .clock_origin = std.Io.Clock.awake.now(io),
        };
        return e;
    }

    pub fn deinit(e: *Editor) void {
        const gpa = e.gpa;
        if (e.ground) |*g| g.deinit();
        if (e.minimap) |m| m.deinit(gpa);
        e.objects.deinit();
        e.fx.destroy();
        e.world.deinit();
        e.model.deinit();
        e.undo.deinit(gpa);
        e.redo.deinit(gpa);
        e.brush.deinit(gpa);
        gpa.destroy(e.terrain_info);
        e.assets.deinit();
        e.display.close();
        gpa.destroy(e);
    }

    fn realTime(e: *const Editor) f64 {
        const d = e.clock_origin.durationTo(std.Io.Clock.awake.now(e.io));
        return @as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_s;
    }

    pub fn run(e: *Editor) !void {
        while (!e.quit) {
            const now = e.realTime();
            try e.handleEvents();
            e.scroll(now - e.last_frame);
            e.last_frame = now;
            if (e.dirty) try e.rebuild();
            try e.render(now);
            e.io.sleep(.fromMilliseconds(15), .awake) catch return;
        }
    }

    /// The world and its picture from the model.
    fn rebuild(e: *Editor) !void {
        e.dirty = false;
        const bytes = try e.model.bytes();
        defer e.gpa.free(bytes);
        try e.world.loadMap(bytes);
        const m = &e.world.map.?;
        if (e.ground) |*g| g.deinit();
        e.ground = null;
        e.ground = try terrain_mod.Terrain.init(e.gpa, &e.sheets, e.terrain_info, m, e.prng.random());
        try e.objects.setMap(m, e.terrain_info);
        e.clampView();
        if (e.minimap) |mm| mm.deinit(e.gpa);
        e.minimap = null;
    }

    fn say(e: *Editor, comptime fmt: []const u8, args: anytype) void {
        e.status = fit(&e.status_buf, fmt, args);
        e.status_until = e.realTime() + 4;
    }

    // -----------------------------------------------------------------------
    // Editing
    // -----------------------------------------------------------------------

    fn do(e: *Editor, edit: Edit) !void {
        if (!try e.model.apply(edit)) return;
        try e.undo.append(e.gpa, .{ .group = e.group, .edit = edit });
        if (e.undo.items.len > max_undo) _ = e.undo.orderedRemove(0);
        e.redo.clearRetainingCapacity();
        e.changed = true;
        e.dirty = true;
    }

    /// Undo (or redo) the last stroke.
    fn back(e: *Editor, from: *std.ArrayList(Step), to: *std.ArrayList(Step)) !void {
        const last = from.getLastOrNull() orelse return;
        while (from.getLastOrNull()) |s| {
            if (s.group != last.group) break;
            _ = from.pop();
            const inv = s.edit.inverse();
            if (try e.model.apply(inv)) try to.append(e.gpa, .{ .group = s.group, .edit = inv });
        }
        e.changed = true;
        e.dirty = true;
    }

    fn save(e: *Editor) void {
        const bytes = e.model.bytes() catch return e.say("out of memory", .{});
        defer e.gpa.free(bytes);
        std.Io.Dir.cwd().writeFile(e.io, .{ .sub_path = e.path, .data = bytes }) catch |err| return e.say("could not save {s}: {t}", .{ e.path, err });
        e.changed = false;
        e.say("saved {s}", .{e.path});
    }

    /// The object the current mode would place at tile (tx, ty) (not in
    /// the world), if it fits there.
    fn candidate(e: *Editor, tx: i32, ty: i32) ?Object {
        const ot = e.mode.objectType() orelse return null;
        if (ot == .robot and e.team == .none) return null;
        if (e.model.placementAt(tx, ty) != null) return null;
        var o = Object.init(preview_id, ot, e.object, &e.world.settings, .{
            .planet = e.model.planet(),
            .level = e.level,
            .extra_links = e.extra_links,
        }) orelse return null;
        if (tx * tile + o.width_pix > @as(i32, e.model.header.width) * tile) return null;
        if (ty * tile + o.height_pix > @as(i32, e.model.header.height) * tile) return null;
        o.owner = e.team;
        o.setPosition(tx * tile, ty * tile);
        return o;
    }

    fn placement(e: *const Editor, tx: i32, ty: i32) Placement {
        return .{
            .x = @intCast(tx),
            .y = @intCast(ty),
            .owner = @intCast(@intFromEnum(e.team)),
            .object_type = @intFromEnum(e.mode.objectType().?),
            .object_id = e.object,
            .blevel = @intCast(e.level),
            .extra_links = e.extra_links,
            .health_percent = e.health,
        };
    }

    /// The placement of the object under the mouse.
    fn hoveredPlacement(e: *const Editor) ?usize {
        const p = e.mouseMap() orelse return null;
        for (e.world.objects.items) |o| {
            if (p[0] < o.x or p[1] < o.y or p[0] >= o.x + o.width_pix or p[1] >= o.y + o.height_pix) continue;
            if (e.model.placementAt(@divFloor(o.x, tile), @divFloor(o.y, tile))) |i| return i;
        }
        return null;
    }

    /// Left button at the mouse (`press`: just went down, else dragging).
    fn click(e: *Editor, press: bool) !void {
        const x = e.mouse_x;
        const y = e.mouse_y;
        if (press) e.group +%= 1;
        if (x < panel_w and y < palette_h) {
            if (press) try e.pickTile(@intCast(@divTrunc(y, tile) * mapfmt.palette_width + @divTrunc(x, tile)));
            return;
        }
        if (e.minimapSpot(x, y)) |p| {
            e.view_x = p[0] - (e.viewW() >> 1);
            e.view_y = p[1] - (e.viewH() >> 1);
            e.clampView();
            return;
        }
        const t = e.mouseTile() orelse return;
        switch (e.mode) {
            .tiles => if (e.brush.items.len > 0) {
                const i: u32 = @intCast(t[1] * e.model.header.width + t[0]);
                const to = e.brush.items[e.prng.random().uintLessThan(usize, e.brush.items.len)];
                // Painting over a tile of the brush leaves it be.
                if (std.mem.indexOfScalar(u16, e.brush.items, e.model.tiles[i]) == null or e.brush.items.len == 1)
                    try e.do(.{ .tile = .{ .index = i, .from = e.model.tiles[i], .to = to } });
            },
            .buildings, .guns, .vehicles, .robots, .items => if (e.candidate(t[0], t[1]) != null) {
                try e.do(.{ .place = e.placement(t[0], t[1]) });
            },
            .zones => if (press) {
                e.zone_start = t;
            },
            .remove_zones => if (press) if (e.model.zoneAt(t[0], t[1])) |i| {
                try e.do(.{ .remove_zone = e.model.zones.items[i] });
            },
            .remove_objects => if (e.hoveredPlacement()) |i| {
                try e.do(.{ .remove = e.model.placements.items[i] });
            },
        }
    }

    fn release(e: *Editor) !void {
        const start = e.zone_start orelse return;
        e.zone_start = null;
        const r = e.zoneRect(start) orelse return;
        try e.do(.{ .add_zone = r });
    }

    /// The zone from tile `start` to the one under the mouse.
    fn zoneRect(e: *const Editor, start: [2]i32) ?ZoneRect {
        const t = e.mouseTile() orelse return null;
        const x0 = @min(start[0], t[0]);
        const y0 = @min(start[1], t[1]);
        return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(@max(start[0], t[0]) - x0 + 1), .h = @intCast(@max(start[1], t[1]) - y0 + 1) };
    }

    /// Choose a tile to paint with; with ctrl, add it to the brush (or
    /// take it off).
    fn pickTile(e: *Editor, t: u16) !void {
        if (t >= mapfmt.palette_tiles or !e.terrain_info.palette(e.model.planet())[t].is_usable) return;
        if (e.keys.ctrl) {
            if (std.mem.indexOfScalar(u16, e.brush.items, t)) |i| {
                _ = e.brush.orderedRemove(i);
                return;
            }
        } else e.brush.clearRetainingCapacity();
        try e.brush.append(e.gpa, t);
    }

    fn nextObject(e: *Editor, forward: bool) void {
        const n = e.mode.objects();
        if (n == 0) return;
        e.object = if (forward) (e.object + 1) % n else (e.object + n - 1) % n;
        e.health = 100;
    }

    // -----------------------------------------------------------------------
    // Input
    // -----------------------------------------------------------------------

    fn handleEvents(e: *Editor) !void {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => e.quit = true,
                c.SDL_EVENT_WINDOW_RESIZED => {
                    try e.display.resize(ev.window.data1, ev.window.data2);
                    e.width = e.display.frame.w;
                    e.height = e.display.frame.h;
                    e.clampView();
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    e.mouse_x = @intFromFloat(ev.motion.x);
                    e.mouse_y = @intFromFloat(ev.motion.y);
                    if (e.left_down) try e.click(false);
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT) {
                    e.left_down = true;
                    try e.click(true);
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => if (ev.button.button == c.SDL_BUTTON_LEFT) {
                    e.left_down = false;
                    try e.release();
                },
                c.SDL_EVENT_MOUSE_WHEEL => if (ev.wheel.y != 0) e.nextObject(ev.wheel.y > 0),
                c.SDL_EVENT_KEY_DOWN => try e.keyDown(ev.key.key),
                c.SDL_EVENT_KEY_UP => e.keyUp(ev.key.key),
                else => {},
            }
        }
    }

    fn keyDown(e: *Editor, sym: c.SDL_Keycode) !void {
        switch (sym) {
            c.SDLK_LEFT => e.keys.left = true,
            c.SDLK_RIGHT => e.keys.right = true,
            c.SDLK_UP => e.keys.up = true,
            c.SDLK_DOWN => e.keys.down = true,
            c.SDLK_LCTRL, c.SDLK_RCTRL => e.keys.ctrl = true,
            c.SDLK_LSHIFT, c.SDLK_RSHIFT => e.keys.shift = true,
            c.SDLK_ESCAPE => e.zone_start = null,
            c.SDLK_PRINTSCREEN, c.SDLK_P => e.savePicture(),
            c.SDLK_S => e.save(),
            c.SDLK_R => e.ruler = switch (e.ruler) {
                .off => .edges,
                .edges => .grid,
                .grid => .off,
            },
            c.SDLK_Z => if (e.keys.ctrl) {
                if (e.keys.shift) try e.back(&e.redo, &e.undo) else try e.back(&e.undo, &e.redo);
            },
            c.SDLK_Y => if (e.keys.ctrl) try e.back(&e.redo, &e.undo),
            c.SDLK_M => {
                const n = @typeInfo(Mode).@"enum".fields.len;
                const i = @intFromEnum(e.mode);
                e.mode = @enumFromInt(if (e.keys.shift) (i + n - 1) % n else (i + 1) % n);
                e.object = 0;
                e.health = 100;
                e.extra_links = 0;
                e.zone_start = null;
            },
            c.SDLK_O => e.nextObject(!e.keys.shift),
            c.SDLK_T => e.team = @enumFromInt((@intFromEnum(e.team) + 1) % k.Team.count),
            c.SDLK_L => e.level = (e.level + 1) % k.max_building_levels,
            c.SDLK_COMMA => e.extra_links -|= 1,
            c.SDLK_PERIOD => e.extra_links +|= 1,
            c.SDLK_SEMICOLON => e.health = if (e.health <= 0) 100 else e.health - 1,
            c.SDLK_APOSTROPHE => e.health = if (e.health >= 100) 0 else e.health + 1,
            else => {},
        }
    }

    fn keyUp(e: *Editor, sym: c.SDL_Keycode) void {
        switch (sym) {
            c.SDLK_LEFT => e.keys.left = false,
            c.SDLK_RIGHT => e.keys.right = false,
            c.SDLK_UP => e.keys.up = false,
            c.SDLK_DOWN => e.keys.down = false,
            c.SDLK_LCTRL, c.SDLK_RCTRL => e.keys.ctrl = false,
            c.SDLK_LSHIFT, c.SDLK_RSHIFT => e.keys.shift = false,
            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // View
    // -----------------------------------------------------------------------

    fn viewW(e: *const Editor) i32 {
        return @max(e.width - map_x, 0);
    }

    fn viewH(e: *const Editor) i32 {
        return e.height;
    }

    fn mapW(e: *const Editor) i32 {
        return @as(i32, e.model.header.width) * tile;
    }

    fn mapH(e: *const Editor) i32 {
        return @as(i32, e.model.header.height) * tile;
    }

    fn clampView(e: *Editor) void {
        e.view_x = std.math.clamp(e.view_x, 0, @max(e.mapW() - e.viewW(), 0));
        e.view_y = std.math.clamp(e.view_y, 0, @max(e.mapH() - e.viewH(), 0));
    }

    fn scroll(e: *Editor, dt_in: f64) void {
        const amount: i32 = @intFromFloat(@min(dt_in, 0.1) * scroll_speed);
        const kk = e.keys;
        if (kk.left and !kk.right) e.view_x -= amount;
        if (kk.right and !kk.left) e.view_x += amount;
        if (kk.up and !kk.down) e.view_y -= amount;
        if (kk.down and !kk.up) e.view_y += amount;
        e.clampView();
    }

    fn mouseMap(e: *const Editor) ?[2]i32 {
        if (e.mouse_x < map_x) return null;
        const p = [2]i32{ e.mouse_x - map_x + e.view_x, e.mouse_y + e.view_y };
        if (p[0] >= e.mapW() or p[1] >= e.mapH()) return null;
        return p;
    }

    fn mouseTile(e: *const Editor) ?[2]i32 {
        const p = e.mouseMap() orelse return null;
        return .{ @divFloor(p[0], tile), @divFloor(p[1], tile) };
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    fn render(e: *Editor, now: f64) !void {
        e.display.frame.fill(null, .{ .r = 0, .g = 0, .b = 0 });
        const screen: Canvas = .{ .target = e.display.frame, .clip = .{ .x = 0, .y = 0, .w = e.width, .h = e.height } };
        const view: Rect = .{ .x = e.view_x, .y = e.view_y, .w = e.viewW(), .h = e.viewH() };
        const cv: Canvas = .{ .target = e.display.frame, .clip = .{ .x = map_x, .y = 0, .w = view.w, .h = view.h }, .dx = map_x - e.view_x, .dy = -e.view_y };
        if (e.ground) |*g| {
            e.objects.update(&e.world, g, now);
            try g.draw(cv, view, now, e.world.zones.items, e.prng.random());
            e.objects.drawPre(cv, &e.world, view);
            try e.objects.draw(cv, &e.world, view);
            e.objects.drawAfter(cv, &e.world, view);
            e.drawCursor(cv);
            e.drawZones(cv);
            if (e.ruler != .off) e.drawRuler(screen, view);
        }
        e.drawPalette(screen);
        try e.drawMinimap(screen, view);
        e.drawInfo(screen, now);
        e.display.present();
    }

    /// What the mouse would do on the map.
    fn drawCursor(e: *Editor, cv: Canvas) void {
        const red: gfx.Color = .{ .r = 255, .g = 0, .b = 0 };
        const t = e.mouseTile() orelse return;
        switch (e.mode) {
            .tiles => if (e.brush.items.len > 0) {
                const b = e.brush.items[0];
                cv.drawPart(e.ground.?.sheet, .{ .x = (b % mapfmt.palette_width) * tile, .y = (b / mapfmt.palette_width) * tile, .w = tile, .h = tile }, t[0] * tile, t[1] * tile);
            },
            .buildings, .guns, .vehicles, .robots, .items => if (e.candidate(t[0], t[1])) |o| {
                e.objects.drawPreview(cv, &e.world, &o);
            },
            .remove_objects => if (e.hoveredPlacement()) |i| {
                const p = e.model.placements.items[i];
                for (e.world.objects.items) |o| if (@divFloor(o.x, tile) == p.x and @divFloor(o.y, tile) == p.y) {
                    cv.outline(.{ .x = o.x, .y = o.y, .w = o.width_pix, .h = o.height_pix }, red);
                    break;
                };
            },
            else => {},
        }
    }

    fn drawZones(e: *Editor, cv: Canvas) void {
        const t = e.mouseTile();
        switch (e.mode) {
            .zones => if (e.zone_start) |s| if (e.zoneRect(s)) |z| {
                cv.outline(zonePixels(z), .{ .r = 255, .g = 255, .b = 0 });
            },
            .remove_zones => {
                const hovered = if (t) |tt| e.model.zoneAt(tt[0], tt[1]) else null;
                for (e.model.zones.items, 0..) |z, i| {
                    const col: gfx.Color = if (hovered == i) .{ .r = 255, .g = 0, .b = 0 } else .{ .r = 255, .g = 255, .b = 255 };
                    cv.outline(zonePixels(z), col);
                }
            },
            else => {},
        }
    }

    fn zonePixels(z: ZoneRect) Rect {
        return .{ .x = @as(i32, z.x) * tile, .y = @as(i32, z.y) * tile, .w = @as(i32, z.w) * tile, .h = @as(i32, z.h) * tile };
    }

    /// Tile numbers along the edges (every 5th), or a grid of lines.
    fn drawRuler(e: *Editor, screen: Canvas, view: Rect) void {
        const col: gfx.Color = if (e.model.planet() == .arctic) .{ .r = 255, .g = 0, .b = 0 } else .{ .r = 255, .g = 255, .b = 255 };
        const small = e.fonts.get(.small_white);
        var tx = @divFloor(view.x, tile) + 1;
        while (tx * tile < view.x + view.w) : (tx += 1) {
            const x = map_x + tx * tile - view.x;
            const every5 = @mod(tx, 5) == 0;
            screen.fill(.{ .x = x, .y = 0, .w = 1, .h = if (every5 and e.ruler == .grid) view.h else 4 }, col);
            screen.fill(.{ .x = x, .y = view.h - 4, .w = 1, .h = 4 }, col);
            if (every5) {
                var buf: [8]u8 = undefined;
                small.drawTinted(screen, fit(&buf, "{d}", .{tx}), x + 2, 6, col, 255);
            }
        }
        var ty = @divFloor(view.y, tile) + 1;
        while (ty * tile < view.y + view.h) : (ty += 1) {
            const y = ty * tile - view.y;
            const every5 = @mod(ty, 5) == 0;
            screen.fill(.{ .x = map_x, .y = y, .w = if (every5 and e.ruler == .grid) view.w else 4, .h = 1 }, col);
            screen.fill(.{ .x = map_x + view.w - 4, .y = y, .w = 4, .h = 1 }, col);
            if (every5) {
                var buf: [8]u8 = undefined;
                small.drawTinted(screen, fit(&buf, "{d}", .{ty}), map_x + 6, y, col, 255);
            }
        }
    }

    /// The tile sheet: the tile under the mouse boxed, the brush crossed.
    fn drawPalette(e: *Editor, screen: Canvas) void {
        const sheet = if (e.ground) |g| g.sheet else return;
        screen.draw(sheet, 0, 0);
        if (e.mouse_x < panel_w and e.mouse_y < palette_h) {
            screen.outline(.{ .x = @divTrunc(e.mouse_x, tile) * tile, .y = @divTrunc(e.mouse_y, tile) * tile, .w = tile, .h = tile }, .{ .r = 0, .g = 255, .b = 255 });
        }
        for (e.brush.items) |b| {
            const x: i32 = (b % mapfmt.palette_width) * tile;
            const y: i32 = (b / mapfmt.palette_width) * tile;
            var i: i32 = 0;
            while (i < tile) : (i += 1) {
                screen.fill(.{ .x = x + i, .y = y + i, .w = 1, .h = 1 }, .{ .r = 255, .g = 0, .b = 0 });
                screen.fill(.{ .x = x + tile - 1 - i, .y = y + i, .w = 1, .h = 1 }, .{ .r = 255, .g = 0, .b = 0 });
            }
        }
    }

    fn minimapScale(e: *const Editor) f64 {
        const w: f64 = @floatFromInt(@max(e.mapW(), 1));
        const h: f64 = @floatFromInt(@max(e.mapH(), 1));
        return @min(minimap_size / w, minimap_size / h);
    }

    /// Map point for a click on the minimap.
    fn minimapSpot(e: *const Editor, x: i32, y: i32) ?[2]i32 {
        const s = e.minimapScale();
        const w: i32 = @intFromFloat(@as(f64, @floatFromInt(e.mapW())) * s);
        const h: i32 = @intFromFloat(@as(f64, @floatFromInt(e.mapH())) * s);
        if (x < minimap_x or y < minimap_y or x >= minimap_x + w or y >= minimap_y + h) return null;
        return .{ @intFromFloat(@as(f64, @floatFromInt(x - minimap_x)) / s), @intFromFloat(@as(f64, @floatFromInt(y - minimap_y)) / s) };
    }

    /// The whole map scaled down, with units as dots and the view boxed.
    fn drawMinimap(e: *Editor, screen: Canvas, view: Rect) !void {
        const g = if (e.ground) |*g| g else return;
        const s = e.minimapScale();
        if (e.minimap == null) {
            const w: i32 = @max(@as(i32, @intFromFloat(@as(f64, @floatFromInt(e.mapW())) * s)), 1);
            const h: i32 = @max(@as(i32, @intFromFloat(@as(f64, @floatFromInt(e.mapH())) * s)), 1);
            const img = try Image.create(e.gpa, w, h);
            var j: i32 = 0;
            while (j < h) : (j += 1) {
                const row = img.row(j);
                const sy: i32 = @intFromFloat(@as(f64, @floatFromInt(j)) / s);
                const src = g.ground.row(@min(sy, g.ground.height() - 1));
                for (row, 0..) |*px, i| {
                    const sx: i32 = @intFromFloat(@as(f64, @floatFromInt(i)) / s);
                    px.* = src[@intCast(@min(sx, g.ground.width() - 1))] | 0xFF000000;
                }
            }
            e.minimap = img;
        }
        const img = e.minimap.?;
        screen.draw(img, minimap_x, minimap_y);
        for (e.world.objects.items) |o| {
            if (o.owner == .none or o.kind == .building) continue;
            const x = minimap_x + @as(i32, @intFromFloat(@as(f64, @floatFromInt(o.center_x)) * s));
            const y = minimap_y + @as(i32, @intFromFloat(@as(f64, @floatFromInt(o.center_y)) * s));
            screen.fill(.{ .x = x, .y = y, .w = 2, .h = 2 }, e.assets.palettes.color(o.owner));
        }
        const vx = minimap_x + @as(i32, @intFromFloat(@as(f64, @floatFromInt(view.x)) * s));
        const vy = minimap_y + @as(i32, @intFromFloat(@as(f64, @floatFromInt(view.y)) * s));
        const vw: i32 = @intFromFloat(@as(f64, @floatFromInt(@min(view.w, e.mapW()))) * s);
        const vh: i32 = @intFromFloat(@as(f64, @floatFromInt(@min(view.h, e.mapH()))) * s);
        screen.sub(.{ .x = minimap_x, .y = minimap_y, .w = img.width(), .h = img.height() }).outline(.{ .x = vx, .y = vy, .w = vw, .h = vh }, .{ .r = 255, .g = 255, .b = 255 });
    }

    fn drawInfo(e: *Editor, screen: Canvas, now: f64) void {
        const f = e.fonts.get(.small_white);
        const white: gfx.Color = .{ .r = 255, .g = 255, .b = 255 };
        const x = minimap_x + minimap_size + 8;
        var y: i32 = palette_h + 6;
        const Line = struct {
            fn put(ft: *const font.Font, cv: Canvas, xx: i32, yy: *i32, col: gfx.Color, comptime fmt: []const u8, args: anytype) void {
                var buf: [128]u8 = undefined;
                ft.drawTinted(cv, fit(&buf, fmt, args), xx, yy.*, col, 255);
                yy.* += 11;
            }
        };
        if (e.changed) Line.put(f, screen, x, &y, .{ .r = 255, .g = 64, .b = 64 }, "Changed - S saves", .{});
        Line.put(f, screen, x, &y, white, "Mode: {s} (M)", .{@tagName(e.mode)});
        switch (e.mode) {
            .tiles => Line.put(f, screen, x, &y, white, "Brush: {d} tile(s)", .{e.brush.items.len}),
            .buildings, .guns, .vehicles, .robots, .items => {
                var name_buf: [32]u8 = undefined;
                Line.put(f, screen, x, &y, white, "Object: {s} (O)", .{objectName(e.mode.objectType().?, e.object, &name_buf)});
                Line.put(f, screen, x, &y, white, "Team: {s} (T)", .{e.team.name()});
                Line.put(f, screen, x, &y, white, "Health: {d}% (; ')", .{e.health});
                if (e.mode == .buildings) {
                    Line.put(f, screen, x, &y, white, "Level: {d} (L)", .{e.level + 1});
                    Line.put(f, screen, x, &y, white, "Bridge links: {d} (, .)", .{e.extra_links});
                }
            },
            else => {},
        }
        if (e.mouseTile()) |t| Line.put(f, screen, x, &y, white, "Tile: {d},{d}", .{ t[0], t[1] });
        if (e.hoveredPlacement()) |i| {
            const p = e.model.placements.items[i];
            var name_buf: [32]u8 = undefined;
            const name = objectName(@enumFromInt(p.object_type), p.object_id, &name_buf);
            if (p.object_type == @intFromEnum(k.ObjectType.building))
                Line.put(f, screen, x, &y, white, "Here: {s} L{d} ({s})", .{ name, @as(i32, p.blevel) + 1, p.team().name() })
            else
                Line.put(f, screen, x, &y, white, "Here: {s} ({s})", .{ name, p.team().name() });
        }
        if (now < e.status_until) Line.put(f, screen, x, &y, .{ .r = 255, .g = 255, .b = 0 }, "{s}", .{e.status});
    }

    /// The whole map as a picture, next to the map file (.png).
    fn savePicture(e: *Editor) void {
        const g = if (e.ground) |*g| g else return;
        const img = Image.create(e.gpa, e.mapW(), e.mapH()) catch {
            e.say("Not enough memory for the picture", .{});
            return;
        };
        defer img.deinit(e.gpa);
        // Drawing keeps the target's alpha: start opaque.
        img.fill(null, .{ .r = 0, .g = 0, .b = 0 });
        const whole: Rect = .{ .x = 0, .y = 0, .w = e.mapW(), .h = e.mapH() };
        const cv: Canvas = .{ .target = img, .clip = whole };
        g.draw(cv, whole, e.realTime(), e.world.zones.items, e.prng.random()) catch return e.say("out of memory", .{});
        e.objects.drawPre(cv, &e.world, whole);
        e.objects.draw(cv, &e.world, whole) catch return e.say("out of memory", .{});
        e.objects.drawAfter(cv, &e.world, whole);
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}.png", .{e.path}) catch return e.say("path too long", .{});
        const surface = img.asSurface() orelse return e.say("out of memory", .{});
        defer c.SDL_DestroySurface(surface);
        if (!c.SDL_SavePNG(surface, path.ptr)) return e.say("could not write {s}", .{path});
        e.say("saved {s}", .{path});
    }
};

fn objectName(ot: k.ObjectType, id: u8, buf: []u8) []const u8 {
    return switch (ot) {
        .building => if (id < k.Building.count) @tagName(@as(k.Building, @enumFromInt(id))) else "?",
        .cannon => if (id < k.Cannon.count) @tagName(@as(k.Cannon, @enumFromInt(id))) else "?",
        .vehicle => if (id < k.Vehicle.count) @tagName(@as(k.Vehicle, @enumFromInt(id))) else "?",
        .robot => if (id < k.Robot.count) @tagName(@as(k.Robot, @enumFromInt(id))) else "?",
        .map_item => blk: {
            const item: k.Item = @enumFromInt(id);
            if (item.mapObjectIndex()) |i| break :blk std.fmt.bufPrint(buf, "map object {d}", .{i}) catch "?";
            break :blk switch (item) {
                .flag, .rock, .grenades, .rockets, .hut => @tagName(item),
                else => "?",
            };
        },
        else => "?",
    };
}

test "editing a map: tiles, objects, zones, undo" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var dir = std.Io.Dir.cwd().openDir(io, "bin/assets", .{}) catch return error.SkipZigTest;
    defer dir.close(io);
    const info = try mapfmt.Terrain.load(io, dir);
    var prng: std.Random.DefaultPrng = .init(1);
    var m = try Model.new(gpa, &info, .{ .width = 20, .height = 16, .name = "test" }, prng.random());
    defer m.deinit();
    try testing.expect(info.palette(.desert)[m.tiles[0]].is_starter_tile);

    try testing.expect(try m.apply(.{ .tile = .{ .index = 3, .from = m.tiles[3], .to = 7 } }));
    const fort: Placement = .{ .x = 2, .y = 2, .owner = 1, .object_type = @intFromEnum(k.ObjectType.building), .object_id = 0, .blevel = 0, .extra_links = 0, .health_percent = 100 };
    try testing.expect(try m.apply(.{ .place = fort }));
    // One object per tile.
    try testing.expect(!try m.apply(.{ .place = fort }));
    try testing.expect(try m.apply(.{ .add_zone = .{ .x = 0, .y = 0, .w = 10, .h = 8 } }));
    // Zones must fit on the map.
    try testing.expect(!try m.apply(.{ .add_zone = .{ .x = 15, .y = 0, .w = 10, .h = 8 } }));
    try testing.expectEqual(0, m.zoneAt(9, 7).?);
    try testing.expect(m.zoneAt(10, 7) == null);

    // Saved and loaded again, the map is the same.
    const bytes = try m.bytes();
    defer gpa.free(bytes);
    var again = try mapfmt.Map.parse(gpa, bytes);
    defer again.deinit(gpa);
    try testing.expectEqual(7, again.tiles[3]);
    try testing.expectEqual(1, again.placements.len);
    try testing.expectEqual(1, again.zones.len);
    try testing.expectEqualStrings("test", again.header.nameSlice());

    // Every edit can be undone.
    try testing.expect(try m.apply((Edit{ .place = fort }).inverse()));
    try testing.expectEqual(0, m.placements.items.len);
    try testing.expect(try m.apply((Edit{ .add_zone = .{ .x = 0, .y = 0, .w = 10, .h = 8 } }).inverse()));
    try testing.expectEqual(0, m.zones.items.len);
}
