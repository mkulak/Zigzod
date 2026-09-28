//! The production window of forts and factories (GWProduction): choose what
//! to build, start and stop production, queue more units, place finished
//! guns. It floats over the map next to its building.

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const font = @import("font.zig");
const sprites_mod = @import("sprites.zig");
const units = @import("units.zig");
const Effects = @import("effects.zig").Effects;

const k = game.constants;
const buildlist = game.buildlist;
const Object = game.object.Object;
const World = game.world.World;
const Unit = buildlist.Unit;
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Rect = gfx.Rect;

const folder = "other/production_gui/";

pub const ButtonKind = enum {
    place,
    ok,
    cancel,
    up,
    down,
    plus_small,
    minus_small,
    queue,
    object,
    object_name,
};

const State = enum { place, select, building, paused };

pub const Images = struct {
    buttons: [@typeInfo(ButtonKind).@"enum".fields.len][2]?Image = @splat(@splat(null)),
    base: ?Image = null,
    base_expanded: ?Image = null,
    fort_label: ?Image = null,
    robot_label: ?Image = null,
    vehicle_label: ?Image = null,
    /// [state][blink]
    state_label: [4][2]?Image = @splat(@splat(null)),
    p_bar: ?Image = null,
    p_bar_yellow: ?Image = null,
    fus_top_left: ?Image = null,
    fus_top_right: ?Image = null,
    fus_bottom_left: ?Image = null,
    fus_bottom_right: ?Image = null,
    fus_top: ?Image = null,
    fus_bottom: ?Image = null,
    fus_left: ?Image = null,
    fus_right: ?Image = null,

    pub fn load(assets: []const u8) Images {
        var m: Images = .{};
        for (&m.buttons, 0..) |*b, i| {
            const name = @tagName(@as(ButtonKind, @enumFromInt(i)));
            b[0] = one(assets, "{s}_button.png", .{name});
            b[1] = one(assets, "{s}_button_pressed.png", .{name});
        }
        m.base = one(assets, "base_image.png", .{});
        m.base_expanded = one(assets, "base_image_expanded.png", .{});
        m.fort_label = one(assets, "fort_factory_label.png", .{});
        m.robot_label = one(assets, "robot_factory_label.png", .{});
        m.vehicle_label = one(assets, "vehicle_factory_label.png", .{});
        for (&m.state_label, [_][]const u8{ "place", "select", "building", "paused" }) |*l, name| {
            l[0] = one(assets, "{s}_label.png", .{name});
            l[1] = one(assets, "{s}less_label.png", .{name});
        }
        m.p_bar = one(assets, "percentage_bar.png", .{});
        m.p_bar_yellow = one(assets, "percentage_bar_yellow.png", .{});
        inline for (.{ "top_left", "top_right", "bottom_left", "bottom_right", "top", "bottom", "left", "right" }) |part| {
            @field(m, "fus_" ++ part) = one(assets, "fus_" ++ part ++ ".png", .{});
        }
        return m;
    }

    fn one(assets: []const u8, comptime fmt: []const u8, args: anytype) ?Image {
        var buf: [512]u8 = undefined;
        return Image.load(std.fmt.bufPrintZ(&buf, "{s}/" ++ folder ++ fmt, .{assets} ++ args) catch return null);
    }

    pub fn deinit(m: *Images) void {
        inline for (@typeInfo(Images).@"struct".fields) |f| free(&@field(m, f.name));
    }

    fn free(x: anytype) void {
        switch (@typeInfo(@TypeOf(x.*))) {
            .array => for (x) |*e| free(e),
            .optional => if (x.*) |img| img.deinit(),
            else => comptime unreachable,
        }
    }

    fn button(m: *const Images, kind: ButtonKind, pressed: bool) ?Image {
        return m.buttons[@intFromEnum(kind)][@intFromBool(pressed)];
    }
};

/// The name shown under a unit (ZObject::GetHoverName).
pub fn unitName(u: Unit) []const u8 {
    return switch (u.kind) {
        .cannon => switch (@as(k.Cannon, @enumFromInt(u.id))) {
            .gatling => "Gatling",
            .gun => "Gun",
            .howitzer => "Howitzer",
            .missile_cannon => "Missile",
        },
        .vehicle => switch (@as(k.Vehicle, @enumFromInt(u.id))) {
            .jeep => "Jeep",
            .light => "Light",
            .medium => "Medium",
            .heavy => "Heavy",
            .apc => "APC",
            .missile_launcher => "M Missile",
            .crane => "Crane",
        },
        .robot => switch (@as(k.Robot, @enumFromInt(u.id))) {
            .grunt => "Grunt",
            .psycho => "Psychos",
            .sniper => "Sniper",
            .tough => "Tough",
            .pyro => "Pyros",
            .laser => "Laser",
        },
        else => "",
    };
}

/// Animated units shown in the window.
const Preview = struct {
    unit: Unit,
    obj: Object,
    look: units.UnitVisual = .{},
};

/// What the window asks the game to do.
pub const Action = union(enum) {
    none,
    close,
    start: Unit,
    stop,
    enqueue: Unit,
    /// Cancel queue item `index` (which is `unit`).
    dequeue: struct { index: usize, unit: Unit },
    /// Start placing the first finished gun.
    place: k.Cannon,
};

/// One of the two unit choosers: what to build now, what to queue.
const Selector = struct {
    x: i32,
    y: i32,
    index: usize = 0,
    /// Only chooses (the queue one); the other shows what is being built.
    only_selector: bool,

    const up: [2]i32 = .{ 47, 2 };
    const down: [2]i32 = .{ 47, 45 };

    fn choosing(s: Selector, state: State) bool {
        return s.only_selector or state == .select;
    }

    fn inPortrait(s: Selector, x: i32, y: i32) bool {
        return x >= s.x + 2 and y >= s.y + 2 and x <= s.x + 46 and y <= s.y + 52;
    }
};

const Pressed = union(enum) {
    button: ButtonKind,
    selector_up: u1,
    selector_down: u1,
    queue_item: usize,
    pick: usize,
};

/// The full list of what can be built, opened by clicking a selector's
/// portrait: robots, vehicles and guns, a row each.
const Picker = struct {
    /// Which selector it fills (0 build, 1 queue).
    for_selector: u1,
    rect: Rect,
    cells: [max_cells]Cell = undefined,
    n: usize = 0,

    const max_cells = 32;
    const margin = 2;
    const top = 20;
    const side = 4;
    const cell_w = 45;
    const cell_h = 51;

    const Cell = struct { unit: Unit, x: i32, y: i32 };

    /// Centered on (cx, cy), kept on the map.
    fn init(for_selector: u1, list: []const Unit, cx: i32, cy: i32, map_w: i32, map_h: i32) Picker {
        var pk: Picker = .{ .for_selector = for_selector, .rect = undefined };
        var rows: i32 = 0;
        var cols: i32 = 2;
        for ([_]k.ObjectType{ .robot, .vehicle, .cannon }) |kind| {
            var col: i32 = 0;
            for (list) |u| {
                if (u.kind != kind or pk.n == max_cells) continue;
                pk.cells[pk.n] = .{ .unit = u, .x = side + margin + col * (cell_w + margin), .y = top + margin + rows * (cell_h + margin) };
                pk.n += 1;
                col += 1;
            }
            if (col > 0) rows += 1;
            cols = @max(cols, col);
        }
        const w = side + (margin + cell_w) * cols + margin + side;
        const h = top + (margin + cell_h) * rows + margin + side;
        var x = cx - (w >> 1);
        var y = cy - (h >> 1);
        x = @max(@min(x, map_w - (w + 16)), 16);
        y = @max(@min(y, map_h - (h + 16)), 16);
        pk.rect = .{ .x = x, .y = y, .w = w, .h = h };
        return pk;
    }

    fn cellsSlice(pk: *const Picker) []const Cell {
        return pk.cells[0..pk.n];
    }
};

pub const Production = struct {
    gpa: std.mem.Allocator,
    building: i32,
    kind: k.Building,
    x: i32,
    y: i32,
    expanded: bool = false,
    selectors: [2]Selector = .{ .{ .x = 3, .y = 19, .only_selector = false }, .{ .x = 111, .y = 19, .only_selector = true } },
    pressed: ?Pressed = null,
    picker: ?Picker = null,
    previews: std.ArrayList(Preview) = .empty,

    /// A window for our production building `o`, or null if it has none.
    pub fn open(gpa: std.mem.Allocator, o: *const Object, map: *const game.map.Map) ?Production {
        const b = switch (o.kind) {
            .building => |b| b,
            else => return null,
        };
        if (!b.producesUnits() or o.isDestroyed()) return null;
        var p: Production = .{ .gpa = gpa, .building = o.ref_id, .kind = b.type, .x = o.x - 56, .y = o.y - 40 };
        p.x = @min(p.x, map.widthPixels() - (228 + 16));
        p.y = @min(p.y, map.heightPixels() - (96 + 16));
        p.x = @max(p.x, 16);
        p.y = @max(p.y, 16);
        return p;
    }

    pub fn deinit(p: *Production) void {
        for (p.previews.items) |*pv| pv.obj.deinit(p.gpa);
        p.previews.deinit(p.gpa);
    }

    fn width(p: *const Production) i32 {
        return if (p.expanded) 228 else 112;
    }

    fn height(p: *const Production) i32 {
        return if (p.expanded) 96 else 80;
    }

    pub fn contains(p: *const Production, x: i32, y: i32) bool {
        if (p.picker) |*pk| if (pk.rect.contains(x, y)) return true;
        return x >= p.x and y >= p.y and x < p.x + p.width() and y < p.y + p.height();
    }

    fn options(b: *const game.object.Building) []const Unit {
        return buildlist.forBuilding(b.type, b.level);
    }

    /// The window's view of the building's state.
    fn state(world: *const World, o: *const Object, b: *const game.object.Building) State {
        if (o.isDestroyed()) return .paused;
        if (b.cannons.items.len > 0) return .place;
        if (world.unit_limit_reached[@intFromEnum(o.owner)]) return .paused;
        return switch (b.state) {
            .place => .place,
            .select => .select,
            .building => .building,
            .paused => .paused,
        };
    }

    fn buttonPos(p: *const Production, kind: ButtonKind) ?[2]i32 {
        return switch (kind) {
            .place, .ok => .{ 67, 60 },
            .cancel => .{ 67, 47 },
            .plus_small, .minus_small => .{ 96, 4 },
            .queue => if (p.expanded) .{ 111, 78 } else null,
            else => null,
        };
    }

    fn buttonActive(p: *const Production, kind: ButtonKind, st: State) bool {
        return switch (kind) {
            .ok => st != .place,
            .cancel => true,
            .place => st == .place,
            .plus_small => !p.expanded,
            .minus_small => p.expanded,
            .queue => p.expanded,
            else => false,
        };
    }

    /// The unit a selector shows.
    fn selected(p: *const Production, which: u1, st: State, b: *const game.object.Building) ?Unit {
        const s = p.selectors[which];
        if (s.choosing(st)) {
            const list = options(b);
            if (list.len == 0) return null;
            return list[s.index % list.len];
        }
        if (b.cannons.items.len > 0) return .{ .kind = .cannon, .id = @intFromEnum(b.cannons.items[0]) };
        return b.unit;
    }

    // -----------------------------------------------------------------------
    // Mouse
    // -----------------------------------------------------------------------

    fn hit(img: ?Image, x0: i32, y0: i32, x: i32, y: i32) bool {
        const i = img orelse return false;
        return x >= x0 and y >= y0 and x <= x0 + i.width() and y <= y0 + i.height();
    }

    /// Left button down at map point (x, y) (inside the window).
    pub fn press(p: *Production, world: *const World, images: *const Images, x: i32, y: i32) void {
        p.pressed = null;
        const o = world.find(p.building) orelse return;
        const b = o.building() orelse return;
        const st = state(world, o, b);
        if (p.picker) |*pk| {
            const r = pk.rect;
            if (r.contains(x, y)) {
                for (pk.cellsSlice(), 0..) |cell, i| {
                    if (hit(images.button(.object, false), r.x + cell.x, r.y + cell.y, x, y)) p.pressed = .{ .pick = i };
                }
                return;
            }
        }
        const lx = x - p.x;
        const ly = y - p.y;
        for (0..@typeInfo(ButtonKind).@"enum".fields.len) |i| {
            const kind: ButtonKind = @enumFromInt(i);
            const pos = p.buttonPos(kind) orelse continue;
            if (!p.buttonActive(kind, st)) continue;
            if (hit(images.button(kind, false), pos[0], pos[1], lx, ly)) p.pressed = .{ .button = kind };
        }
        for (p.selectors, 0..) |s, i| {
            if (i == 1 and !p.expanded) continue;
            if (!s.choosing(st)) continue;
            if (hit(images.button(.up, false), s.x + Selector.up[0], s.y + Selector.up[1], lx, ly)) p.pressed = .{ .selector_up = @intCast(i) };
            if (hit(images.button(.down, false), s.x + Selector.down[0], s.y + Selector.down[1], lx, ly)) p.pressed = .{ .selector_down = @intCast(i) };
        }
        if (p.expanded) for (0..b.queue.items.len) |i| {
            if (hit(images.button(.object_name, false), 177, 22 + @as(i32, @intCast(i)) * 14, lx, ly)) p.pressed = .{ .queue_item = i };
        };
    }

    /// Left button up at map point (x, y): what to do.
    pub fn release(p: *Production, world: *const World, images: *const Images, x: i32, y: i32) Action {
        const map = world.map orelse return .close;
        const pressed = p.pressed;
        p.pressed = null;
        const o = world.find(p.building) orelse return .close;
        const b = o.building() orelse return .close;
        const st = state(world, o, b);
        if (p.picker) |pk| {
            p.picker = null;
            const r = pk.rect;
            if (!r.contains(x, y)) return .none;
            const pick = switch (pressed orelse return .none) {
                .pick => |i| i,
                else => return .none,
            };
            const cells = pk.cellsSlice();
            if (pick >= cells.len or !hit(images.button(.object, false), r.x + cells[pick].x, r.y + cells[pick].y, x, y)) return .none;
            const u = cells[pick].unit;
            const list = options(b);
            for (list, 0..) |lu, i| if (std.meta.eql(lu, u)) {
                p.selectors[pk.for_selector].index = i;
            };
            return if (pk.for_selector == 0) p.ok(st, b) else .{ .enqueue = u };
        }
        const lx = x - p.x;
        const ly = y - p.y;
        if (pressed) |pr| switch (pr) {
            .button => |kind| if (hit(images.button(kind, true), p.buttonPos(kind).?[0], p.buttonPos(kind).?[1], lx, ly)) {
                switch (kind) {
                    .ok => return p.ok(st, b),
                    .cancel => return if (st == .building) .stop else .close,
                    .place => return if (b.cannons.items.len > 0 and o.zone != null) .{ .place = b.cannons.items[0] } else .none,
                    .plus_small => p.expanded = true,
                    .minus_small => {
                        p.expanded = false;
                        p.picker = null;
                    },
                    .queue => if (p.selected(1, st, b)) |u| return .{ .enqueue = u },
                    else => {},
                }
            },
            .selector_up => |i| p.turn(i, b, 1),
            .selector_down => |i| p.turn(i, b, -1),
            .queue_item => |i| if (i < b.queue.items.len and hit(images.button(.object_name, true), 177, 22 + @as(i32, @intCast(i)) * 14, lx, ly)) {
                return .{ .dequeue = .{ .index = i, .unit = b.queue.items[i] } };
            },
            .pick => {},
        };
        // Clicking a portrait opens the full list.
        for (p.selectors, 0..) |s, i| {
            if (i == 1 and !p.expanded) continue;
            if (s.choosing(st) and s.inPortrait(lx, ly) and pressed == null) {
                p.picker = .init(@intCast(i), options(b), p.x + s.x + 24, p.y + s.y + 21, map.widthPixels(), map.heightPixels());
            }
        }
        return .none;
    }

    fn ok(p: *Production, st: State, b: *const game.object.Building) Action {
        return switch (st) {
            .select => if (p.selected(0, st, b)) |u| .{ .start = u } else .none,
            .building, .paused => .close,
            .place => .none,
        };
    }

    fn turn(p: *Production, which: u1, b: *const game.object.Building, dir: i2) void {
        const n = options(b).len;
        if (n == 0) return;
        const s = &p.selectors[which];
        s.index = if (dir > 0) (s.index + 1) % n else (s.index + n - 1) % n;
    }

    /// The mouse wheel turns the selectors.
    pub fn wheel(p: *Production, world: *const World, up: bool) void {
        const o = world.find(p.building) orelse return;
        const b = o.building() orelse return;
        const st = state(world, o, b);
        const which: u1 = if (p.selectors[0].choosing(st)) 0 else if (p.expanded) 1 else return;
        p.turn(which, b, if (up) 1 else -1);
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    /// Seconds shown: the build time of the chosen unit, or what is left.
    fn timeShown(world: *const World, o: *const Object, b: *const game.object.Building, st: State, choice: ?Unit) ?i64 {
        if (st == .select) {
            const u = choice orelse return null;
            const s = world.settings.unit(u.kind, u.id) orelse return null;
            var t: f64 = @floatFromInt(s.build_time);
            t -= t * 0.5 * b.zone_ownage;
            t += t * (1.25 * (1.0 - o.healthRatio()));
            return @intFromFloat(t);
        }
        return @intFromFloat(@max(b.final_time - world.now(), 0));
    }

    pub fn draw(p: *Production, cv: Canvas, world: *const World, images: *const Images, all: *const sprites_mod.Sprites, fonts: *const font.Fonts, fx: *Effects, rng: std.Random) void {
        const o = world.find(p.building) orelse return;
        const b = o.building() orelse return;
        const st = state(world, o, b);
        const time = world.now();
        const small = fonts.get(.small_white);
        const x = p.x;
        const y = p.y;

        if (if (p.expanded) images.base_expanded else images.base) |img| cv.draw(img, x, y);
        const label = switch (b.type) {
            .robot_factory => images.robot_label,
            .vehicle_factory => images.vehicle_label,
            else => images.fort_label,
        };
        if (label) |img| cv.draw(img, x + 9, y + 6);
        const blink: usize = @intFromFloat(@mod(@floor(time / 0.3), 2));
        if (images.state_label[@intFromEnum(st)][blink]) |img| cv.draw(img, x + 64, y + 19);

        for (0..@typeInfo(ButtonKind).@"enum".fields.len) |i| {
            const kind: ButtonKind = @enumFromInt(i);
            const pos = p.buttonPos(kind) orelse continue;
            if (!p.buttonActive(kind, st)) continue;
            const down = if (p.pressed) |pr| std.meta.eql(pr, Pressed{ .button = kind }) else false;
            if (images.button(kind, down)) |img| cv.draw(img, x + pos[0], y + pos[1]);
        }

        // The queue.
        if (p.expanded) for (b.queue.items, 0..) |u, i| {
            const qy = y + 22 + @as(i32, @intCast(i)) * 14;
            const down = if (p.pressed) |pr| std.meta.eql(pr, Pressed{ .queue_item = i }) else false;
            if (images.button(.object_name, down)) |img| cv.draw(img, x + 177, qy);
            const name = unitName(u);
            small.draw(cv, name, x + 177 + 23 - (small.width(name) >> 1), qy + 2);
        };

        var buf: [16]u8 = undefined;
        if (timeShown(world, o, b, st, p.selected(0, st, b))) |secs| {
            small.draw(cv, std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ @divTrunc(secs, 60), @mod(secs, 60) }) catch "", x + 90, y + 35);
        }
        const health: i64 = if (o.max_health > 0) std.math.clamp(@divTrunc(100 * @as(i64, o.health), o.max_health), 0, 100) else 0;
        const health_text = std.fmt.bufPrint(&buf, "{d}%", .{health}) catch "";
        small.draw(cv, health_text, x + 86 - (small.width(health_text) >> 1), y + 6);

        for (p.selectors, 0..) |s, i| {
            if (i == 1 and !p.expanded) continue;
            const sx = x + s.x;
            const sy = y + s.y;
            if (s.choosing(st)) {
                for ([_]struct { ButtonKind, [2]i32, Pressed }{
                    .{ .up, Selector.up, .{ .selector_up = @intCast(i) } },
                    .{ .down, Selector.down, .{ .selector_down = @intCast(i) } },
                }) |bt| {
                    const down = if (p.pressed) |pr| std.meta.eql(pr, bt[2]) else false;
                    if (images.button(bt[0], down)) |img| cv.draw(img, sx + bt[1][0], sy + bt[1][1]);
                }
            } else if (!s.only_selector) {
                // Progress: the yellow part shrinks as the unit gets done.
                if (images.p_bar) |bar| cv.draw(bar, sx + 50, sy + 2);
                if (images.p_bar_yellow) |bar| {
                    const done = std.math.clamp((time - b.init_time) / @max(b.final_time - b.init_time, 0.001), 0, 1);
                    const h: i32 = @intFromFloat((1 - done) * @as(f64, @floatFromInt(bar.height())));
                    if (h > 0) cv.drawPart(bar, .{ .x = 0, .y = 0, .w = bar.width(), .h = h }, sx + 50, sy + 2);
                }
            }
            if (p.selected(@intCast(i), st, b)) |u| {
                p.drawUnit(cv, world, all, fx, rng, u, o.owner, sx + 24, sy + 21, i == 0);
                const name = unitName(u);
                small.draw(cv, name, sx + 25 - (small.width(name) >> 1), sy + 42);
            }
        }

        if (p.picker) |*pk| p.drawPicker(cv, world, images, all, fonts, fx, rng, pk, o.owner);
    }

    /// A live unit, centered on (cx, cy).
    fn drawUnit(p: *Production, cv: Canvas, world: *const World, all: *const sprites_mod.Sprites, fx: *Effects, rng: std.Random, u: Unit, team: k.Team, cx: i32, cy: i32, random_turn: bool) void {
        const pv = p.preview(world, u, team, rng, random_turn) orelse return;
        pv.obj.setPosition(cx - (pv.obj.width_pix >> 1), cy - (pv.obj.height_pix >> 1));
        units.update(&pv.obj, &pv.look, .{ .world = world, .time = world.now(), .rng = rng, .fx = fx });
        units.draw(cv, all, &pv.obj, &pv.look, world, 0);
    }

    fn preview(p: *Production, world: *const World, u: Unit, team: k.Team, rng: std.Random, random_turn: bool) ?*Preview {
        for (p.previews.items) |*pv| if (std.meta.eql(pv.unit, u) and pv.obj.owner == team) return pv;
        var obj = Object.init(-1, u.kind, u.id, &world.settings, .{}) orelse return null;
        obj.owner = team;
        var look: units.UnitVisual = .{};
        units.init(&obj, &look, rng, team, world.now());
        // Guns show ready; in the full list vehicles face down.
        look.just_placed = false;
        if (!random_turn and u.kind == .vehicle) {
            look.direction = 6;
            look.turret = 6;
        }
        p.previews.append(p.gpa, .{ .unit = u, .obj = obj, .look = look }) catch {
            obj.deinit(p.gpa);
            return null;
        };
        return &p.previews.items[p.previews.items.len - 1];
    }

    fn drawPicker(p: *Production, cv: Canvas, world: *const World, images: *const Images, all: *const sprites_mod.Sprites, fonts: *const font.Fonts, fx: *Effects, rng: std.Random, pk: *const Picker, team: k.Team) void {
        const r = pk.rect;
        const side = Picker.side;
        // Frame: corners, stretched edges, gray inside.
        cv.fill(.{ .x = r.x + side, .y = r.y + Picker.top, .w = r.w - 2 * side, .h = r.h - Picker.top - side }, .{ .r = 57, .g = 57, .b = 57 });
        if (images.fus_top_left) |tl| {
            if (images.fus_top) |t| tile(cv, t, r.x + tl.width(), r.y, r.w - tl.width() - side, true);
            cv.draw(tl, r.x, r.y);
        }
        if (images.fus_bottom) |t| tile(cv, t, r.x + side, r.y + r.h - side, r.w - 2 * side, true);
        if (images.fus_left) |t| tile(cv, t, r.x, r.y + Picker.top, r.h - Picker.top - side, false);
        if (images.fus_right) |t| tile(cv, t, r.x + r.w - side, r.y + Picker.top, r.h - Picker.top - side, false);
        if (images.fus_top_right) |img| cv.draw(img, r.x + r.w - side, r.y);
        if (images.fus_bottom_left) |img| cv.draw(img, r.x, r.y + r.h - side);
        if (images.fus_bottom_right) |img| cv.draw(img, r.x + r.w - side, r.y + r.h - side);

        const small = fonts.get(.small_white);
        for (pk.cellsSlice(), 0..) |cell, i| {
            const down = if (p.pressed) |pr| std.meta.eql(pr, Pressed{ .pick = i }) else false;
            const cx = r.x + cell.x;
            const cy = r.y + cell.y;
            if (images.button(.object, down)) |img| cv.draw(img, cx, cy);
            p.drawUnit(cv, world, all, fx, rng, cell.unit, team, cx + 22, cy + 19, false);
            const name = unitName(cell.unit);
            small.draw(cv, name, cx + 23 - (small.width(name) >> 1), cy + 40);
        }
    }

    /// Repeat `img` along a length (cut at the end).
    fn tile(cv: Canvas, img: Image, x: i32, y: i32, len: i32, horizontal: bool) void {
        var at: i32 = 0;
        const step = if (horizontal) img.width() else img.height();
        while (at < len) : (at += step) {
            const part = @min(step, len - at);
            if (horizontal) {
                cv.drawPart(img, .{ .x = 0, .y = 0, .w = part, .h = img.height() }, x + at, y);
            } else {
                cv.drawPart(img, .{ .x = 0, .y = 0, .w = img.width(), .h = part }, x, y + at);
            }
        }
    }
};

test "production window" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    const terrain = try gpa.create(game.map.Terrain);
    defer gpa.destroy(terrain);
    terrain.* = try game.map.Terrain.load(io, assets);
    var world = World.init(gpa, terrain, 1);
    defer world.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "Data/Campaing/Z_original/p02_bb_orig01.map", gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try world.loadMap(bytes);
    var fort: ?*Object = null;
    for (world.objects.items) |o| if (o.kind == .building and o.kind.building.type == .fort_front) {
        fort = o;
    };
    const f = fort.?;
    f.owner = .red;
    const b = f.building().?;
    b.state = .select;
    b.cannons.clearRetainingCapacity();

    var images = Images.load("bin/assets");
    defer images.deinit();
    var p = Production.open(gpa, f, &world.map.?).?;
    defer p.deinit();

    // OK starts building what the selector shows.
    const ok_img = images.button(.ok, false).?;
    p.press(&world, &images, p.x + 67 + 2, p.y + 60 + 2);
    const act = p.release(&world, &images, p.x + 67 + 2, p.y + 60 + 2);
    try std.testing.expectEqual(buildlist.forBuilding(b.type, b.level)[0], act.start);
    _ = ok_img;

    // The portrait opens the full list; picking the second unit starts it.
    p.press(&world, &images, p.x + 3 + 10, p.y + 19 + 10);
    try std.testing.expectEqual(Action.none, p.release(&world, &images, p.x + 3 + 10, p.y + 19 + 10));
    const pk = p.picker.?;
    const cell = pk.cellsSlice()[1];
    p.press(&world, &images, pk.rect.x + cell.x + 5, pk.rect.y + cell.y + 5);
    const pick = p.release(&world, &images, pk.rect.x + cell.x + 5, pk.rect.y + cell.y + 5);
    try std.testing.expectEqual(cell.unit, pick.start);
    try std.testing.expect(p.picker == null);

    // While building, cancel stops.
    b.state = .building;
    p.press(&world, &images, p.x + 67 + 2, p.y + 47 + 2);
    try std.testing.expectEqual(Action.stop, p.release(&world, &images, p.x + 67 + 2, p.y + 47 + 2));
}

// ---------------------------------------------------------------------------
// Factory list
// ---------------------------------------------------------------------------

/// Art of the factory list (from assets/other/factory_gui).
pub const ListImages = struct {
    top: ?Image = null,
    right: ?Image = null,
    entry: ?Image = null,
    bar_green: ?Image = null,
    bar_grey: ?Image = null,
    bar_white_i: ?Image = null,
    up: [2]?Image = @splat(null),
    down: [2]?Image = @splat(null),
    scroll_top: ?Image = null,
    scroll_center: ?Image = null,
    scroll_bottom: ?Image = null,
    inner_top: ?Image = null,
    inner_center: ?Image = null,
    inner_bottom: ?Image = null,

    pub fn load(assets: []const u8) ListImages {
        const one = struct {
            fn f(a: []const u8, name: []const u8) ?Image {
                var buf: [512]u8 = undefined;
                return Image.load(std.fmt.bufPrintZ(&buf, "{s}/other/factory_gui/{s}.png", .{ a, name }) catch return null);
            }
        }.f;
        return .{
            .top = one(assets, "main_top"),
            .right = one(assets, "main_right"),
            .entry = one(assets, "main_entry"),
            .bar_green = one(assets, "entry_bar_green"),
            .bar_grey = one(assets, "entry_bar_grey"),
            .bar_white_i = one(assets, "entry_bar_white_i"),
            .up = .{ one(assets, "fup_button"), one(assets, "fup_button_pressed") },
            .down = .{ one(assets, "fdown_button"), one(assets, "fdown_button_pressed") },
            .scroll_top = one(assets, "scrollbar_top"),
            .scroll_center = one(assets, "scrollbar_center"),
            .scroll_bottom = one(assets, "scrollbar_bottom"),
            .inner_top = one(assets, "scrollbar_inner_top"),
            .inner_center = one(assets, "scrollbar_inner_center"),
            .inner_bottom = one(assets, "scrollbar_inner_bottom"),
        };
    }

    pub fn deinit(m: *ListImages) void {
        inline for (@typeInfo(ListImages).@"struct".fields) |f| Images.free(&@field(m, f.name));
    }
};

/// All our forts and factories at the bottom left of the map (the B
/// button): health, production and tech level; click one to go there
/// (GWFactoryList).
pub const FactoryList = struct {
    shown: bool = false,
    /// First entry shown (the list scrolls).
    first: usize = 0,
    pressed: ?enum { up, down } = null,

    const max_entries = 64;
    const width = 142;

    fn entries(world: *const World, team: k.Team, out: *[max_entries]*Object) []*Object {
        var n: usize = 0;
        for ([_][]const k.Building{ &.{ .fort_front, .fort_back }, &.{.robot_factory}, &.{.vehicle_factory} }) |types| {
            for (world.objects.items) |o| {
                if (o.owner != team or team == .none or n == max_entries) continue;
                const b = o.building() orelse continue;
                if (std.mem.indexOfScalar(k.Building, types, b.type) == null) continue;
                out[n] = o;
                n += 1;
            }
        }
        return out[0..n];
    }

    const Layout = struct { x: i32, y: i32, h: i32, visible: usize };

    /// Bottom left of the map area, as tall as its entries (or the area).
    fn layout(l: *FactoryList, images: *const ListImages, area: Rect, count: usize) ?Layout {
        const top = images.top orelse return null;
        const entry = images.entry orelse return null;
        var visible: usize = 0;
        if (count > 0) {
            const room = area.h - top.height() - entry.height();
            visible = 1 + @as(usize, @intCast(@max(@divTrunc(room, entry.height()), 0)));
            visible = @min(visible, count);
        }
        l.first = @min(l.first, count - visible);
        const h = top.height() + @as(i32, @intCast(visible)) * entry.height();
        return .{ .x = area.x, .y = area.y + area.h - h, .h = h, .visible = visible };
    }

    /// Screen point (x, y) pressed: true if the list took it; `jump` is set
    /// to a building clicked.
    pub fn press(l: *FactoryList, world: *const World, team: k.Team, images: *const ListImages, area: Rect, x: i32, y: i32, jump: *?i32) bool {
        if (!l.shown) return false;
        var buf: [max_entries]*Object = undefined;
        const list = entries(world, team, &buf);
        const lay = l.layout(images, area, list.len) orelse return false;
        if (x < lay.x or y < lay.y or x >= lay.x + width or y >= lay.y + lay.h) return false;
        const lx = x - lay.x;
        const ly = y - lay.y;
        if (list.len > 0) {
            if (inside(images.up[0], 123, images.top.?.height() + 2, lx, ly)) l.pressed = .up;
            if (inside(images.down[0], 123, lay.h - 11, lx, ly)) l.pressed = .down;
        }
        const entry_h = images.entry.?.height();
        const top_h = images.top.?.height();
        if (lx <= 120 and ly >= top_h) {
            const i = l.first + @as(usize, @intCast(@divTrunc(ly - top_h, entry_h)));
            if (i < list.len and i < l.first + lay.visible) jump.* = list[i].ref_id;
        }
        return true;
    }

    pub fn release(l: *FactoryList) void {
        const pressed = l.pressed orelse return;
        l.pressed = null;
        l.scroll(pressed == .down);
    }

    pub fn scroll(l: *FactoryList, down: bool) void {
        if (down) l.first += 1 else l.first -|= 1;
    }

    fn inside(img: ?Image, x0: i32, y0: i32, x: i32, y: i32) bool {
        const i = img orelse return false;
        return x >= x0 and y >= y0 and x <= x0 + i.width() and y <= y0 + i.height();
    }

    pub fn draw(l: *FactoryList, cv: Canvas, world: *const World, team: k.Team, images: *const ListImages, fonts: *const font.Fonts, area: Rect) void {
        if (!l.shown) return;
        var buf: [max_entries]*Object = undefined;
        const list = entries(world, team, &buf);
        const lay = l.layout(images, area, list.len) orelse return;
        const top = images.top.?;
        const entry = images.entry.?;
        cv.draw(top, lay.x, lay.y);
        var ty = lay.y + top.height();
        for (list[l.first..][0..lay.visible]) |o| {
            cv.draw(entry, lay.x, ty);
            drawEntry(cv, world, o, images, fonts, lay.x + 12, ty + 7);
            ty += entry.height();
        }
        if (images.right) |right| {
            var ry = lay.y + top.height();
            while (ry < area.y + area.h) : (ry += right.height()) cv.draw(right, lay.x + top.width() - right.width(), ry);
        }
        if (list.len == 0) return;
        if (images.up[@intFromBool(l.pressed == .up)]) |img| cv.draw(img, lay.x + 123, lay.y + top.height() + 2);
        if (images.down[@intFromBool(l.pressed == .down)]) |img| cv.draw(img, lay.x + 123, lay.y + lay.h - 11);
        // The scroll bar: its thumb shows the visible part.
        const bar_top = top.height() + 14;
        const bar_h = lay.h - 14 - bar_top;
        strip(cv, images.scroll_top, images.scroll_center, images.scroll_bottom, lay.x + 123, lay.y + bar_top, bar_h);
        const max_h = bar_h - 16;
        const shown = @as(f64, @floatFromInt(lay.visible)) / @as(f64, @floatFromInt(list.len));
        const h: i32 = @max(@as(i32, @intFromFloat(@as(f64, @floatFromInt(max_h)) * shown)), 6);
        const hidden = list.len - lay.visible;
        const down: f64 = if (hidden > 0) @as(f64, @floatFromInt(l.first)) / @as(f64, @floatFromInt(hidden)) else 0;
        const y = lay.y + bar_top + ((bar_h - h - (max_h - h)) >> 1) + @as(i32, @intFromFloat(@as(f64, @floatFromInt(max_h - h)) * down));
        strip(cv, images.inner_top, images.inner_center, images.inner_bottom, lay.x + 122, y, h);
    }

    /// Top, repeated middle and bottom pieces over a height.
    fn strip(cv: Canvas, top: ?Image, center: ?Image, bottom: ?Image, x: i32, y: i32, h: i32) void {
        const t = top orelse return;
        const c_ = center orelse return;
        const b = bottom orelse return;
        cv.draw(t, x, y);
        var cy = y + t.height();
        const end = y + h - b.height();
        while (cy < end) : (cy += c_.height()) {
            cv.drawPart(c_, .{ .x = 0, .y = 0, .w = c_.width(), .h = @min(c_.height(), end - cy) }, x, cy);
        }
        cv.draw(b, x, end);
    }

    /// Three bars: health, production, tech level.
    fn drawEntry(cv: Canvas, world: *const World, o: *Object, images: *const ListImages, fonts: *const font.Fonts, x: i32, y0: i32) void {
        const b = o.building().?;
        const small = fonts.get(.small_white);
        var texts: [3][2][]const u8 = @splat(.{ "", "" });
        var fill: [3]?f64 = @splat(null);
        var bufs: [3][24]u8 = undefined;

        const health = std.math.clamp(o.healthRatio(), 0, 1);
        fill[0] = health;
        texts[0] = .{
            switch (b.type) {
                .robot_factory => "Robot Factory",
                .vehicle_factory => "Vehicle Factory",
                else => "Fort Factory",
            },
            std.fmt.bufPrint(&bufs[0], "{d}%", .{@as(i32, @intFromFloat(health * 100))}) catch "",
        };
        texts[2][0] = std.fmt.bufPrint(&bufs[2], "Tech Level {d}", .{b.level + 1}) catch "";
        if (o.isDestroyed()) {
            fill[1] = 0;
            fill[2] = 0;
            texts[1][0] = "Destroyed";
        } else {
            const time = world.now();
            const state: BuildState = if (world.unit_limit_reached[@intFromEnum(o.owner)]) .paused else b.state;
            switch (state) {
                .place => texts[1][0] = "Placing Cannon",
                .select => texts[1][0] = "No Production",
                .paused => texts[1][0] = "Paused",
                .building => {
                    fill[1] = std.math.clamp((time - b.init_time) / @max(b.final_time - b.init_time, 0.001), 0, 1);
                    if (b.unit) |u| texts[1][0] = productionName(u);
                    const left: i64 = @intFromFloat(@max(b.final_time - time, 0));
                    texts[1][1] = std.fmt.bufPrint(&bufs[1], "{d}:{d:0>2}", .{ @mod(@divTrunc(left, 60), 60), @mod(left, 60) }) catch "";
                },
            }
        }
        var y = y0;
        for (0..3) |i| {
            if (fill[i]) |f| {
                const green = images.bar_green orelse return;
                if (f > 0.99) {
                    cv.draw(green, x, y);
                } else {
                    const gw: i32 = @intFromFloat(@as(f64, @floatFromInt(green.width())) * f);
                    if (gw > 0) cv.drawPart(green, .{ .x = 0, .y = 0, .w = gw, .h = green.height() }, x, y);
                    if (images.bar_white_i) |w| cv.draw(w, @max(x + gw - 1, x), y);
                }
            } else if (images.bar_grey) |grey| cv.draw(grey, x, y);
            small.draw(cv, texts[i][0], x + 2, y + 3);
            small.draw(cv, texts[i][1], x + 101 - small.width(texts[i][1]), y + 3);
            y += 17;
        }
    }

    const BuildState = game.object.BuildState;
};

/// The name used in the factory list.
fn productionName(u: Unit) []const u8 {
    return switch (u.kind) {
        .robot => ([_][]const u8{ "Grunt", "Psycho", "Sniper", "Tough", "Pyro", "Laser" })[@min(u.id, 5)],
        .vehicle => ([_][]const u8{ "Jeep", "Light", "Medium", "Heavy", "APC", "M Missile", "Crane" })[@min(u.id, 6)],
        .cannon => ([_][]const u8{ "Gatling", "Gun", "Howitzer", "Missile" })[@min(u.id, 3)],
        else => "???",
    };
}
