//! The in-game menus (QZod_DnGui's gmm_* menus): main menu, options, change
//! teams, manage bots, player list, map selection and the "are you sure"
//! box. Menus float over the game, stack with the last one clicked on top
//! and can be dragged by any empty spot.
//!
//! A menu is laid out from its kind and the game state whenever it is drawn
//! or clicked, so there is no widget tree to keep in sync with the game.

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const font = @import("font.zig");
const Player = @import("session.zig").Player;

const k = game.constants;
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Rect = gfx.Rect;

pub const Kind = enum {
    main,
    change_teams,
    manage_bots,
    player_list,
    select_map,
    options,
    warning,

    fn title(kind: Kind) []const u8 {
        return switch (kind) {
            .main => "Main Menu",
            .change_teams => "Change Teams",
            .manage_bots => "Manage Bots",
            .player_list => "Player List",
            .select_map => "Select Map",
            .options => "Options",
            .warning => "",
        };
    }
};

/// What the "are you sure" box asks about.
pub const Warning = enum {
    quit,
    reset_map,

    fn lines(w: Warning) [2][]const u8 {
        return switch (w) {
            .quit => .{ "Are you sure you want", "to quit the game?" },
            .reset_map => .{ "Are you sure you want", "to reset the map?" },
        };
    }
};

/// What the player asked for.
pub const Command = union(enum) {
    reshuffle_teams,
    join: k.Team,
    start_bot: k.Team,
    stop_bot: k.Team,
    /// Index into the server's map list.
    select_map: i32,
    toggle_pause,
    /// Quarters: 0 (off) to 4 (full).
    volume: u8,
    speed: f32,
    reset_map,
    quit,
};

/// The game state the menus show.
pub const Context = struct {
    team: k.Team = .none,
    players: []const Player = &.{},
    maps: []const []const u8 = &.{},
    volume: u8 = 4,
    speed: f64 = 1,
    paused: bool = false,
};

pub const speeds = [_]f32{ 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 4.0 };
const volume_names = [_][]const u8{ "0%", "25%", "50%", "75%", "100%" };

// Layout (gui_structures.h).
const side = 5;
const title_h = 18;
const bottom = 5;
const button_h = 15;
const label_h = 10;
const entry_h = 13;
const list_rows = 8;
const list_h = 3 + list_rows * entry_h + 2;
const radio_h = 9;
const radio_left = 16;
const radio_center = 13;
const radio_right = 15;
const swatch_w = 19;
const swatch_h = 12;
const arrow_w = 11;
const arrow_h = 8;

// ---------------------------------------------------------------------------
// Art
// ---------------------------------------------------------------------------

/// A box drawn from corners, repeated edges and a repeated middle. Pieces
/// may be missing: the menu frame has no bottom corners (its sides run to
/// the bottom) and lists have no middle.
const Nine = struct {
    pieces: [9]?Image = @splat(null),

    const names = [9][]const u8{ "top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom", "bottom_right" };

    fn load(assets: []const u8, prefix: []const u8, suffix: []const u8) Nine {
        var n: Nine = .{};
        for (names, &n.pieces) |name, *p| {
            var buf: [128]u8 = undefined;
            p.* = loadQuiet(assets, std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ prefix, name, suffix }) catch continue);
        }
        return n;
    }

    fn deinit(n: *Nine) void {
        for (n.pieces) |p| if (p) |img| img.deinit();
    }

    fn draw(n: *const Nine, cv: Canvas, r: Rect) void {
        const p = n.pieces;
        const tl = p[0] orelse return;
        const t = p[1] orelse return;
        const tr = p[2] orelse return;
        const l = p[3] orelse return;
        const rt = p[5] orelse return;
        const b = p[7] orelse return;
        const bl_w = if (p[6]) |i| i.width() else l.width();
        const bl_h = if (p[6]) |i| i.height() else 0;
        const br_w = if (p[8]) |i| i.width() else rt.width();
        const br_h = if (p[8]) |i| i.height() else 0;
        cv.tile(t, .{ .x = r.x + tl.width(), .y = r.y, .w = r.w - tl.width() - tr.width(), .h = t.height() });
        cv.tile(l, .{ .x = r.x, .y = r.y + tl.height(), .w = l.width(), .h = r.h - tl.height() - bl_h });
        cv.tile(rt, .{ .x = r.x + r.w - rt.width(), .y = r.y + tr.height(), .w = rt.width(), .h = r.h - tr.height() - br_h });
        cv.tile(b, .{ .x = r.x + bl_w, .y = r.y + r.h - b.height(), .w = r.w - bl_w - br_w, .h = b.height() });
        if (p[4]) |c| cv.tile(c, .{ .x = r.x + l.width(), .y = r.y + tl.height(), .w = r.w - l.width() - rt.width(), .h = r.h - tl.height() - b.height() });
        cv.draw(tl, r.x, r.y);
        cv.draw(tr, r.x + r.w - tr.width(), r.y);
        if (p[6]) |i| cv.draw(i, r.x, r.y + r.h - i.height());
        if (p[8]) |i| cv.draw(i, r.x + r.w - i.width(), r.y + r.h - i.height());
    }
};

/// One row of a list: ends, repeated top, middle and bottom.
const Entry = struct {
    top: ?Image = null,
    left: ?Image = null,
    center: ?Image = null,
    right: ?Image = null,
    bottom: ?Image = null,

    fn load(assets: []const u8, state: []const u8) Entry {
        var e: Entry = .{};
        inline for (.{ "top", "left", "center", "right", "bottom" }) |name| {
            var buf: [96]u8 = undefined;
            @field(e, name) = loadImage(assets, std.fmt.bufPrint(&buf, "list/list_entry_" ++ name ++ "_{s}", .{state}) catch "");
        }
        return e;
    }

    fn deinit(e: *Entry) void {
        for ([_]?Image{ e.top, e.left, e.center, e.right, e.bottom }) |p| if (p) |img| img.deinit();
    }

    fn draw(e: *const Entry, cv: Canvas, x: i32, y: i32, w: i32) void {
        const l = e.left orelse return;
        const r = e.right orelse return;
        const t = e.top orelse return;
        const c = e.center orelse return;
        const b = e.bottom orelse return;
        const mid = w - l.width() - r.width();
        cv.draw(l, x, y);
        cv.draw(r, x + w - r.width(), y);
        cv.tile(t, .{ .x = x + l.width(), .y = y, .w = mid, .h = t.height() });
        cv.tile(b, .{ .x = x + l.width(), .y = y + entry_h - b.height(), .w = mid, .h = b.height() });
        cv.tile(c, .{ .x = x + l.width(), .y = y + t.height(), .w = mid, .h = c.height() });
    }
};

const ButtonLook = enum { normal, pressed, green };

pub const Art = struct {
    frame: Nine = .{},
    warning: ?Image = null,
    close: [2]?Image = @splat(null),
    buttons: [3]Nine = @splat(.{}),
    list: Nine = .{},
    entries: [2]Entry = @splat(.{}),
    up: [2]?Image = @splat(null),
    down: [2]?Image = @splat(null),
    scroller: ?Image = null,
    radio: [4]?Image = @splat(null),
    swatches: gfx.TeamImages = @splat(null),

    pub fn load(assets: [:0]const u8, palettes: *const gfx.TeamPalettes) Art {
        var a: Art = .{
            .frame = .load(assets, "menu_", ""),
            .warning = loadImage(assets, "menu_warning"),
            .close = .{ loadImage(assets, "close_button_normal"), loadImage(assets, "close_button_pressed") },
            .list = .load(assets, "list/list_", ""),
            .entries = .{ .load(assets, "normal"), .load(assets, "pressed") },
            .up = .{ loadImage(assets, "list/list_button_up_normal"), loadImage(assets, "list/list_button_up_pressed") },
            .down = .{ loadImage(assets, "list/list_button_down_normal"), loadImage(assets, "list/list_button_down_pressed") },
            .scroller = loadImage(assets, "list/list_scroller"),
            .radio = .{ loadImage(assets, "radio/radio_left"), loadImage(assets, "radio/radio_center"), loadImage(assets, "radio/radio_right"), loadImage(assets, "radio/radio_selector") },
            .swatches = gfx.loadTeamImages(palettes, "{s}/other/main_menu_gui/team_color_{s}.png", .{assets}),
        };
        for (&a.buttons, [_][]const u8{ "normal", "pressed", "green" }) |*b, state| {
            var buf: [64]u8 = undefined;
            b.* = .load(assets, std.fmt.bufPrint(&buf, "generic_button_{s}_", .{state}) catch "", "");
        }
        return a;
    }

    pub fn deinit(a: *Art) void {
        a.frame.deinit();
        a.list.deinit();
        for (&a.buttons) |*b| b.deinit();
        for (&a.entries) |*e| e.deinit();
        for ([_]?Image{ a.warning, a.close[0], a.close[1], a.up[0], a.up[1], a.down[0], a.down[1], a.scroller, a.radio[0], a.radio[1], a.radio[2], a.radio[3] }) |p| if (p) |img| img.deinit();
        gfx.freeTeamImages(&a.swatches);
    }

    fn piece(img: ?Image, fallback: i32, comptime dim: enum { w, h }) i32 {
        const i = img orelse return fallback;
        return if (dim == .w) i.width() else i.height();
    }

    /// Where a list's rows are, inside the list.
    fn rows(a: *const Art, list_w: i32) Rect {
        const left = piece(a.list.pieces[3], 3, .w);
        const right = piece(a.list.pieces[5], 14, .w);
        return .{ .x = left, .y = piece(a.list.pieces[1], 3, .h), .w = list_w - left - right, .h = list_rows * entry_h };
    }
};

fn loadImage(assets: []const u8, name: []const u8) ?Image {
    var buf: [512]u8 = undefined;
    return Image.load(std.fmt.bufPrintZ(&buf, "{s}/other/main_menu_gui/{s}.png", .{ assets, name }) catch return null);
}

fn loadQuiet(assets: []const u8, name: []const u8) ?Image {
    var buf: [512]u8 = undefined;
    return Image.loadQuiet(std.fmt.bufPrintZ(&buf, "{s}/other/main_menu_gui/{s}.png", .{ assets, name }) catch return null);
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// What a button does.
const Action = union(enum) {
    command: Command,
    open: Kind,
    warn: Warning,
    confirm,
    cancel,
    /// Change to the map chosen in the list.
    pick_map,
};

const Button = struct { r: Rect, text: []const u8, action: Action, green: bool = false };

const Label = struct {
    x: i32,
    y: i32,
    w: i32,
    text: []const u8,
    justify: enum { left, center, right } = .left,
    font: font.Kind = .yellow_menu,
};

const Radio = struct {
    x: i32,
    y: i32,
    count: u8,
    selected: u8,
    of: enum { volume, speed },

    fn width(r: Radio) i32 {
        return radio_left + (@as(i32, r.count) - 2) * radio_center + radio_right;
    }

    /// The choice at (x, y), if on the radio.
    fn pick(r: Radio, x: i32, y: i32) ?u8 {
        const w = r.width();
        if (x < r.x or x > r.x + w or y < r.y or y > r.y + radio_h) return null;
        const at = x - r.x;
        if (at < radio_left) return 0;
        if (at > w - radio_right) return r.count - 1;
        return @intCast(@min(1 + @divTrunc(at - radio_left, radio_center), r.count - 1));
    }

    fn choice(r: Radio, i: u8) Command {
        return switch (r.of) {
            .volume => .{ .volume = i },
            .speed => .{ .speed = speeds[i] },
        };
    }
};

const Swatch = struct { x: i32, y: i32, team: k.Team };

const Layout = struct {
    w: i32 = 112,
    h: i32 = 0,
    buttons: [16]Button = undefined,
    n_buttons: usize = 0,
    labels: [12]Label = undefined,
    n_labels: usize = 0,
    radios: [2]Radio = undefined,
    n_radios: usize = 0,
    swatches: [k.Team.count]Swatch = undefined,
    n_swatches: usize = 0,
    list: ?Rect = null,
    /// Room for labels made up on the spot (a Layout is never copied).
    text: [2][48]u8 = undefined,

    fn button(l: *Layout, b: Button) void {
        l.buttons[l.n_buttons] = b;
        l.n_buttons += 1;
    }

    fn label(l: *Layout, lb: Label) void {
        l.labels[l.n_labels] = lb;
        l.n_labels += 1;
    }

    fn radio(l: *Layout, r: Radio) void {
        l.radios[l.n_radios] = r;
        l.n_radios += 1;
    }

    fn swatch(l: *Layout, s: Swatch) void {
        l.swatches[l.n_swatches] = s;
        l.n_swatches += 1;
    }

    fn inner(l: *const Layout) i32 {
        return l.w - 2 * side;
    }

    fn close(l: *const Layout) Rect {
        return .{ .x = l.w - 16, .y = 4, .w = 12, .h = 12 };
    }

    fn up(lr: Rect) Rect {
        return .{ .x = lr.x + lr.w - 12, .y = lr.y + 3, .w = arrow_w, .h = arrow_h };
    }

    fn down(lr: Rect) Rect {
        return .{ .x = lr.x + lr.w - 12, .y = lr.y + lr.h - 11, .w = arrow_w, .h = arrow_h };
    }
};

/// Edges included, like the C++ hit tests.
fn within(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and y >= r.y and x <= r.x + r.w and y <= r.y + r.h;
}

/// The n-th human player, by team.
fn nthPlayer(ctx: Context, n: usize) ?*const Player {
    var seen: usize = 0;
    for (0..k.Team.count) |t| for (ctx.players) |*p| {
        if (p.mode != .player or @intFromEnum(p.team) != t) continue;
        if (seen == n) return p;
        seen += 1;
    };
    return null;
}

fn playerCount(ctx: Context) usize {
    var n: usize = 0;
    for (ctx.players) |p| n += @intFromBool(p.mode == .player);
    return n;
}

pub const Menu = struct {
    kind: Kind,
    x: i32 = 0,
    y: i32 = 0,
    warning: Warning = .quit,
    /// Being dragged by this point (relative to the menu).
    grab: ?[2]i32 = null,
    pressed: ?Pressed = null,
    /// First list row shown.
    scroll: usize = 0,
    /// A held list arrow scrolls again at this time.
    next_scroll: f64 = 0,
    /// The map picked in the list.
    chosen: ?usize = null,

    const Pressed = union(enum) { close, button: usize, up, down };

    fn isPressed(m: *const Menu, p: Pressed) bool {
        return if (m.pressed) |q| std.meta.eql(p, q) else false;
    }

    fn layout(m: *const Menu, ctx: Context, l: *Layout) void {
        l.* = .{};
        switch (m.kind) {
            .main => {
                const items = [_]struct { []const u8, Action }{
                    .{ "Change Teams", .{ .open = .change_teams } },
                    .{ "Manage Bots", .{ .open = .manage_bots } },
                    .{ "Player List", .{ .open = .player_list } },
                    .{ "Select Map", .{ .open = .select_map } },
                    .{ "Options", .{ .open = .options } },
                    .{ "Quit Game", .{ .warn = .quit } },
                };
                var y: i32 = title_h;
                for (items) |it| {
                    l.button(.{ .r = .{ .x = side, .y = y, .w = l.inner(), .h = button_h }, .text = it[0], .action = it[1] });
                    y += button_h + 1;
                }
                l.h = y + bottom;
            },
            .options => {
                var y: i32 = title_h;
                const volume = @min(ctx.volume, volume_names.len - 1);
                l.label(.{ .x = side, .y = y, .w = l.inner(), .text = std.fmt.bufPrint(&l.text[0], "Set Volume: {s}", .{volume_names[volume]}) catch "" });
                y += label_h + 1;
                l.radio(.{ .x = side, .y = y, .count = volume_names.len, .selected = volume, .of = .volume });
                y += radio_h + 2;
                l.label(.{ .x = side, .y = y, .w = l.inner(), .text = std.fmt.bufPrint(&l.text[1], "Set Game Speed: {d:.0}%", .{100 * ctx.speed}) catch "" });
                y += label_h + 1;
                var speed: u8 = speeds.len - 1;
                for (speeds, 0..) |s, i| if (ctx.speed <= s + 0.01) {
                    speed = @intCast(i);
                    break;
                };
                l.radio(.{ .x = side, .y = y, .count = speeds.len, .selected = speed, .of = .speed });
                y += radio_h + 7;
                const items = [_]struct { []const u8, Action, bool }{
                    .{ "Pause Game", .{ .command = .toggle_pause }, ctx.paused },
                    .{ "Reshuffle Teams", .{ .command = .reshuffle_teams }, false },
                    .{ "Reset Map", .{ .warn = .reset_map }, false },
                };
                for (items) |it| {
                    l.button(.{ .r = .{ .x = side, .y = y, .w = l.inner(), .h = button_h }, .text = it[0], .action = it[1], .green = it[2] });
                    y += button_h + 1;
                }
                l.h = y + bottom;
            },
            .change_teams => {
                var y: i32 = title_h;
                l.label(.{ .x = side, .y = y, .w = l.inner(), .text = "Change Team To:" });
                y += label_h + 2;
                for (0..k.Team.count) |i| {
                    const team: k.Team = @enumFromInt(i);
                    const bx = l.w - side - 40;
                    const sx = bx - 2 - swatch_w;
                    l.button(.{ .r = .{ .x = bx, .y = y, .w = 40, .h = button_h }, .text = "Join", .action = .{ .command = .{ .join = team } }, .green = team == ctx.team });
                    l.swatch(.{ .x = sx, .y = y + (button_h - swatch_h) / 2, .team = team });
                    l.label(.{ .x = side, .y = y + (button_h - label_h) / 2, .w = sx - 4 - side, .text = team.name(), .justify = .right });
                    y += button_h + 1;
                }
                l.h = y + bottom;
            },
            .manage_bots => {
                const rows = 4;
                const label_w = 40;
                const on_w = 25;
                const gap = 2;
                const col_w = label_w + gap + on_w + gap + on_w;
                var has_bot: [k.Team.count]bool = @splat(false);
                for (ctx.players) |p| if (p.mode == .bot and !p.ignored) {
                    has_bot[@intFromEnum(p.team)] = true;
                };
                for (1..k.Team.count) |i| {
                    const team: k.Team = @enumFromInt(i);
                    const bx: i32 = side + @as(i32, @intCast((i - 1) / rows)) * col_w;
                    const by: i32 = title_h + @as(i32, @intCast((i - 1) % rows)) * (button_h + 1);
                    l.label(.{ .x = bx, .y = by + (button_h - label_h) / 2, .w = label_w, .text = team.name(), .justify = .right });
                    l.button(.{ .r = .{ .x = bx + label_w + gap, .y = by, .w = on_w, .h = button_h }, .text = "On", .action = .{ .command = .{ .start_bot = team } }, .green = has_bot[i] });
                    l.button(.{ .r = .{ .x = bx + label_w + gap + on_w + gap, .y = by, .w = on_w, .h = button_h }, .text = "Off", .action = .{ .command = .{ .stop_bot = team } }, .green = !has_bot[i] });
                }
                const cols = (k.Team.count - 1 + rows - 1) / rows;
                l.w = 2 * side + cols * col_w;
                l.h = title_h + bottom + rows * (button_h + 1);
            },
            .player_list => {
                l.label(.{ .x = side + 4, .y = title_h, .w = l.inner(), .text = "Players Online:" });
                l.label(.{ .x = side, .y = title_h, .w = l.inner(), .text = std.fmt.bufPrint(&l.text[0], "{d}", .{playerCount(ctx)}) catch "", .justify = .right });
                l.list = .{ .x = side, .y = title_h + label_h + 2, .w = l.inner(), .h = list_h };
                l.h = title_h + list_h + bottom + label_h + 2;
            },
            .select_map => {
                l.w = 112 + 56;
                l.list = .{ .x = side, .y = title_h, .w = l.inner(), .h = list_h };
                const y = title_h + list_h + 2;
                l.button(.{ .r = .{ .x = side, .y = y, .w = l.inner(), .h = button_h }, .text = "Select Map", .action = .pick_map });
                l.h = y + button_h + 1 + bottom;
            },
            .warning => {
                l.h = 60;
                l.button(.{ .r = .{ .x = 8, .y = 41, .w = 38, .h = 14 }, .text = "Cancel", .action = .cancel });
                l.button(.{ .r = .{ .x = 66, .y = 41, .w = 38, .h = 14 }, .text = "Ok", .action = .confirm });
                const text = m.warning.lines();
                l.label(.{ .x = 8, .y = 19, .w = l.w - 16, .text = text[0], .justify = .center, .font = .small_white });
                l.label(.{ .x = 8, .y = 19 + label_h + 2, .w = l.w - 16, .text = text[1], .justify = .center, .font = .small_white });
            },
        }
    }

    fn entries(m: *const Menu, ctx: Context) usize {
        return switch (m.kind) {
            .player_list => playerCount(ctx),
            .select_map => ctx.maps.len,
            else => 0,
        };
    }

    fn entryText(m: *const Menu, ctx: Context, i: usize, buf: []u8) []const u8 {
        return switch (m.kind) {
            .player_list => if (nthPlayer(ctx, i)) |p| std.fmt.bufPrint(buf, "{s}: {s}", .{ p.team.name(), p.name.items }) catch p.name.items else "",
            .select_map => if (i < ctx.maps.len) ctx.maps[i] else "",
            else => "",
        };
    }

    fn scrollBy(m: *Menu, ctx: Context, by: i64) void {
        const most: i64 = @max(@as(i64, @intCast(m.entries(ctx))) - list_rows, 0);
        m.scroll = @intCast(std.math.clamp(@as(i64, @intCast(m.scroll)) + by, 0, most));
    }

    fn contains(m: *const Menu, l: *const Layout, x: i32, y: i32) bool {
        return within(.{ .x = m.x, .y = m.y, .w = l.w, .h = l.h }, x, y);
    }

    /// A left click at screen point (x, y); null when it isn't on this
    /// menu.
    fn press(m: *Menu, art: *const Art, ctx: Context, x: i32, y: i32, time: f64) ?Click {
        var l: Layout = undefined;
        m.layout(ctx, &l);
        const tx = x - m.x;
        const ty = y - m.y;
        if (m.kind != .warning and within(l.close(), tx, ty)) {
            m.pressed = .close;
            return .absorbed;
        }
        for (l.buttons[0..l.n_buttons], 0..) |b, i| if (within(b.r, tx, ty)) {
            m.pressed = .{ .button = i };
            return .absorbed;
        };
        for (l.radios[0..l.n_radios]) |r| if (r.pick(tx, ty)) |i| return .{ .command = r.choice(i) };
        if (l.list) |lr| {
            if (within(Layout.up(lr), tx, ty) or within(Layout.down(lr), tx, ty)) {
                m.pressed = if (within(Layout.up(lr), tx, ty)) .up else .down;
                m.next_scroll = time + 0.2;
                return .absorbed;
            }
            const rows = art.rows(lr.w);
            const rx = tx - lr.x;
            const ry = ty - lr.y;
            if (rx >= rows.x and rx <= rows.x + rows.w and ry >= rows.y and ry < rows.y + rows.h) {
                const i = m.scroll + @as(usize, @intCast(@divTrunc(ry - rows.y, entry_h)));
                if (m.kind == .select_map and i < m.entries(ctx)) m.chosen = if (m.chosen == i) null else i;
                return .absorbed;
            }
        }
        if (!m.contains(&l, x, y)) return null;
        m.grab = .{ tx, ty };
        return .absorbed;
    }

    fn draw(m: *const Menu, screen: Canvas, art: *const Art, fonts: *const font.Fonts, ctx: Context) void {
        var l: Layout = undefined;
        m.layout(ctx, &l);
        var cv = screen;
        cv.dx += m.x;
        cv.dy += m.y;
        if (m.kind == .warning) {
            if (art.warning) |img| cv.draw(img, 0, 0);
        } else {
            art.frame.draw(cv, .{ .x = 0, .y = 0, .w = l.w, .h = l.h });
            fonts.get(.yellow_menu).draw(cv, m.kind.title(), 8, 6);
            const c = l.close();
            if (art.close[@intFromBool(m.isPressed(.close))]) |img| cv.draw(img, c.x, c.y);
        }
        const yellow = fonts.get(.yellow_menu);
        for (l.buttons[0..l.n_buttons], 0..) |b, i| {
            const down = m.isPressed(.{ .button = i });
            const look: ButtonLook = if (down) .pressed else if (b.green) .green else .normal;
            art.buttons[@intFromEnum(look)].draw(cv, b.r);
            yellow.draw(cv, b.text, b.r.x + (b.r.w >> 1) - (yellow.width(b.text) >> 1), b.r.y + 3 + @intFromBool(down));
        }
        for (l.labels[0..l.n_labels]) |lb| {
            const f = fonts.get(lb.font);
            const tw = f.width(lb.text);
            const x = switch (lb.justify) {
                .left => lb.x,
                .center => lb.x + (lb.w >> 1) - (tw >> 1),
                .right => lb.x + lb.w - tw,
            };
            f.draw(cv, lb.text, x, lb.y);
        }
        for (l.radios[0..l.n_radios]) |r| drawRadio(cv, art, r);
        for (l.swatches[0..l.n_swatches]) |s| if (art.swatches[@intFromEnum(s.team)]) |img| cv.draw(img, s.x, s.y);
        if (l.list) |lr| m.drawList(cv, art, fonts, ctx, lr);
    }

    fn drawList(m: *const Menu, cv: Canvas, art: *const Art, fonts: *const font.Fonts, ctx: Context, lr: Rect) void {
        art.list.draw(cv, lr);
        const rows = art.rows(lr.w);
        const count = m.entries(ctx);
        const small = fonts.get(.small_white);
        for (0..list_rows) |row| {
            const i = m.scroll + row;
            const x = lr.x + rows.x;
            const y = lr.y + rows.y + @as(i32, @intCast(row)) * entry_h;
            art.entries[@intFromBool(m.chosen == i and m.kind == .select_map)].draw(cv, x, y, rows.w);
            if (i >= count) continue;
            var buf: [96]u8 = undefined;
            small.draw(cv.sub(.{ .x = x + 4, .y = y, .w = rows.w - 8, .h = entry_h }), m.entryText(ctx, i, &buf), x + 4, y + 4);
        }
        const up = Layout.up(lr);
        const down = Layout.down(lr);
        if (art.up[@intFromBool(m.isPressed(.up))]) |img| cv.draw(img, up.x, up.y);
        if (art.down[@intFromBool(m.isPressed(.down))]) |img| cv.draw(img, down.x, down.y);
        // The scroller shows how far down the list is.
        const scroller = art.scroller orelse return;
        const top = Art.piece(art.list.pieces[2], 3, .h);
        const space = lr.h - top - Art.piece(art.list.pieces[8], 3, .h);
        const most = @max(@as(i64, @intCast(count)) - list_rows, 0);
        const f = std.math.clamp(@as(f64, @floatFromInt(m.scroll + 1)) / @as(f64, @floatFromInt(most + 2)), 0, 1);
        cv.draw(scroller, lr.x + lr.w - 9, lr.y + top + @as(i32, @intFromFloat(@as(f64, @floatFromInt(space)) * f)) - 2);
    }
};

fn drawRadio(cv: Canvas, art: *const Art, r: Radio) void {
    const left = art.radio[0] orelse return;
    const center = art.radio[1] orelse return;
    const right = art.radio[2] orelse return;
    const selector = art.radio[3] orelse return;
    const w = r.width();
    cv.draw(left, r.x, r.y);
    cv.draw(right, r.x + w - radio_right, r.y);
    var i: i32 = 0;
    while (i < @as(i32, r.count) - 2) : (i += 1) cv.draw(center, r.x + radio_left + i * radio_center, r.y);
    const s: i32 = r.selected;
    const at = if (s == 0) 7 else if (s == r.count - 1) w - radio_right + 4 else radio_left + (s - 1) * radio_center + 4;
    cv.draw(selector, r.x + at, r.y + 1);
}

// ---------------------------------------------------------------------------
// The stack of open menus
// ---------------------------------------------------------------------------

/// A click's effect.
pub const Click = union(enum) {
    /// Not on a menu: the game may have it.
    missed,
    absorbed,
    command: Command,
};

pub const Menus = struct {
    /// Front (clicked first, drawn last) first; each kind at most once.
    open: [@typeInfo(Kind).@"enum".fields.len]Menu = undefined,
    len: usize = 0,
    /// The window size, for centering new menus.
    screen_w: i32 = 800,
    screen_h: i32 = 600,

    pub fn items(ms: *Menus) []Menu {
        return ms.open[0..ms.len];
    }

    fn find(ms: *const Menus, kind: Kind) ?usize {
        for (ms.open[0..ms.len], 0..) |m, i| if (m.kind == kind) return i;
        return null;
    }

    fn toFront(ms: *Menus, i: usize) void {
        const m = ms.open[i];
        std.mem.copyBackwards(Menu, ms.open[1 .. i + 1], ms.open[0..i]);
        ms.open[0] = m;
    }

    fn remove(ms: *Menus, i: usize) void {
        std.mem.copyForwards(Menu, ms.open[i .. ms.len - 1], ms.open[i + 1 .. ms.len]);
        ms.len -= 1;
    }

    /// Open a menu in the middle of the window, or bring it to the front
    /// (`toggle`: close it) if already open.
    pub fn show(ms: *Menus, kind: Kind, toggle: bool) void {
        if (ms.find(kind)) |i| {
            if (toggle) ms.remove(i) else ms.toFront(i);
            return;
        }
        var m: Menu = .{ .kind = kind };
        var l: Layout = undefined;
        m.layout(.{}, &l);
        m.x = (ms.screen_w >> 1) - (l.w >> 1);
        m.y = (ms.screen_h >> 1) - (l.h >> 1);
        std.mem.copyBackwards(Menu, ms.open[1 .. ms.len + 1], ms.open[0..ms.len]);
        ms.open[0] = m;
        ms.len += 1;
    }

    fn warn(ms: *Menus, w: Warning) void {
        ms.show(.warning, false);
        ms.open[0].warning = w;
    }

    /// Close the front menu (escape); false if none is open.
    pub fn closeTop(ms: *Menus) bool {
        if (ms.len == 0) return false;
        ms.remove(0);
        return true;
    }

    pub fn contains(ms: *const Menus, ctx: Context, x: i32, y: i32) bool {
        for (ms.open[0..ms.len]) |*m| {
            var l: Layout = undefined;
            m.layout(ctx, &l);
            if (m.contains(&l, x, y)) return true;
        }
        return false;
    }

    pub fn press(ms: *Menus, art: *const Art, ctx: Context, x: i32, y: i32, time: f64) Click {
        for (ms.open[0..ms.len], 0..) |*m, i| {
            const click = m.press(art, ctx, x, y, time) orelse continue;
            ms.toFront(i);
            return click;
        }
        return .missed;
    }

    /// The left button went up at (x, y): a button pressed and released on
    /// does its thing.
    pub fn release(ms: *Menus, ctx: Context, x: i32, y: i32) Click {
        var held: ?struct { usize, Menu.Pressed } = null;
        for (ms.open[0..ms.len], 0..) |*m, i| {
            m.grab = null;
            if (m.pressed) |p| if (held == null) {
                held = .{ i, p };
            };
            m.pressed = null;
        }
        if (held) |h| {
            const i = h[0];
            const m = &ms.open[i];
            var l: Layout = undefined;
            m.layout(ctx, &l);
            const tx = x - m.x;
            const ty = y - m.y;
            switch (h[1]) {
                .close => if (within(l.close(), tx, ty)) {
                    ms.remove(i);
                    return .absorbed;
                },
                .button => |b| if (b < l.n_buttons and within(l.buttons[b].r, tx, ty)) return ms.act(i, l.buttons[b].action, ctx),
                .up => if (l.list) |lr| if (within(Layout.up(lr), tx, ty)) m.scrollBy(ctx, -1),
                .down => if (l.list) |lr| if (within(Layout.down(lr), tx, ty)) m.scrollBy(ctx, 1),
            }
        }
        return if (ms.contains(ctx, x, y)) .absorbed else .missed;
    }

    fn act(ms: *Menus, i: usize, action: Action, ctx: Context) Click {
        switch (action) {
            .command => |c| return .{ .command = c },
            .open => |kind| ms.show(kind, false),
            .warn => |w| ms.warn(w),
            .confirm => {
                const w = ms.open[i].warning;
                ms.remove(i);
                return .{ .command = switch (w) {
                    .quit => .quit,
                    .reset_map => .reset_map,
                } };
            },
            .cancel => ms.remove(i),
            .pick_map => if (ms.open[i].chosen) |c| if (c < ctx.maps.len) return .{ .command = .{ .select_map = @intCast(c) } },
        }
        return .absorbed;
    }

    /// The mouse moved: drag a grabbed menu.
    pub fn motion(ms: *Menus, x: i32, y: i32) bool {
        for (ms.open[0..ms.len]) |*m| if (m.grab) |g| {
            m.x = x - g[0];
            m.y = y - g[1];
            return true;
        };
        return false;
    }

    /// The wheel scrolls the list under the mouse.
    pub fn wheel(ms: *Menus, ctx: Context, up: bool, x: i32, y: i32) bool {
        for (ms.open[0..ms.len]) |*m| {
            var l: Layout = undefined;
            m.layout(ctx, &l);
            if (!m.contains(&l, x, y)) continue;
            if (l.list != null) m.scrollBy(ctx, if (up) -1 else 1);
            return true;
        }
        return false;
    }

    /// Held list arrows keep scrolling (30 rows a second).
    pub fn update(ms: *Menus, ctx: Context, time: f64) void {
        for (ms.open[0..ms.len]) |*m| {
            const dir: i64 = if (m.isPressed(.up)) -1 else if (m.isPressed(.down)) 1 else continue;
            const n: i64 = @intFromFloat(@max(time - m.next_scroll, 0) * 30);
            if (n == 0) continue;
            m.scrollBy(ctx, dir * n);
            m.next_scroll = time;
        }
    }

    /// Back to front, kept inside the window.
    pub fn draw(ms: *Menus, cv: Canvas, art: *const Art, fonts: *const font.Fonts, ctx: Context, screen_w: i32, screen_h: i32) void {
        ms.screen_w = screen_w;
        ms.screen_h = screen_h;
        var i = ms.len;
        while (i > 0) {
            i -= 1;
            const m = &ms.open[i];
            var l: Layout = undefined;
            m.layout(ctx, &l);
            m.x = std.math.clamp(m.x, 0, @max(screen_w - l.w, 0));
            m.y = std.math.clamp(m.y, 0, @max(screen_h - l.h, 0));
            m.draw(cv, art, fonts, ctx);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn clickAt(ms: *Menus, art: *const Art, ctx: Context, kind: Kind, x: i32, y: i32) Click {
    const m = &ms.open[ms.find(kind).?];
    const sx = m.x + x;
    const sy = m.y + y;
    const pressed = ms.press(art, ctx, sx, sy, 0);
    if (pressed != .absorbed) return pressed;
    return ms.release(ctx, sx, sy);
}

test "menus open each other and give commands" {
    const art: Art = .{};
    var ms: Menus = .{};
    const ctx: Context = .{ .team = .red };
    ms.show(.main, false);
    try testing.expectEqual(1, ms.len);
    // The main menu is centered.
    try testing.expectEqual(400 - 56, ms.open[0].x);

    // "Options" is the fifth button.
    _ = clickAt(&ms, &art, ctx, .main, 20, title_h + 4 * (button_h + 1) + 5);
    try testing.expectEqual(Kind.options, ms.open[0].kind);
    try testing.expectEqual(2, ms.len);

    // The volume radio: its left end is off, its right end full.
    const vol_y = title_h + label_h + 1 + 2;
    try testing.expectEqual(Command{ .volume = 0 }, ms.press(&art, ctx, ms.open[0].x + side + 2, ms.open[0].y + vol_y, 0).command);
    try testing.expectEqual(Command{ .volume = 4 }, ms.press(&art, ctx, ms.open[0].x + side + 69, ms.open[0].y + vol_y, 0).command);
    _ = ms.release(ctx, 0, 0);

    // Quitting asks first; cancel keeps playing, ok quits.
    ms.show(.main, false);
    const quit_y = title_h + 5 * (button_h + 1) + 5;
    try testing.expectEqual(Click.absorbed, clickAt(&ms, &art, ctx, .main, 20, quit_y));
    try testing.expectEqual(Kind.warning, ms.open[0].kind);
    _ = clickAt(&ms, &art, ctx, .warning, 10, 45);
    try testing.expect(ms.find(.warning) == null);
    _ = clickAt(&ms, &art, ctx, .main, 20, quit_y);
    try testing.expectEqual(Command.quit, clickAt(&ms, &art, ctx, .warning, 70, 45).command);

    // Releasing off the button does nothing; the close box closes.
    _ = ms.press(&art, ctx, ms.open[0].x + 20, ms.open[0].y + title_h + 5, 0);
    try testing.expectEqual(Click.missed, ms.release(ctx, 0, 0));
    const len = ms.len;
    _ = clickAt(&ms, &art, ctx, ms.open[0].kind, 112 - 12, 8);
    try testing.expectEqual(len - 1, ms.len);
}

test "teams, bots, maps" {
    const art: Art = .{};
    var ms: Menus = .{};
    const players = [_]Player{.{ .id = 2, .team = .blue, .mode = .bot }};
    const maps = [_][]const u8{ "a.map", "b.map" };
    const ctx: Context = .{ .team = .red, .players = &players, .maps = &maps };

    ms.show(.change_teams, false);
    var l: Layout = undefined;
    ms.open[0].layout(ctx, &l);
    try testing.expect(l.buttons[1].green); // red is ours
    const blue = l.buttons[2].r;
    try testing.expectEqual(Command{ .join = .blue }, clickAt(&ms, &art, ctx, .change_teams, blue.x + 2, blue.y + 2).command);

    ms.show(.manage_bots, false);
    ms.open[0].layout(ctx, &l);
    try testing.expectEqual(198, l.w);
    // Blue (the second team) has a bot: "On" is lit.
    try testing.expect(l.buttons[2].green and !l.buttons[3].green);
    const off = l.buttons[3].r;
    try testing.expectEqual(Command{ .stop_bot = .blue }, clickAt(&ms, &art, ctx, .manage_bots, off.x + 2, off.y + 2).command);

    ms.show(.select_map, false);
    ms.open[0].layout(ctx, &l);
    const pick = l.buttons[0].r;
    // Nothing chosen yet.
    try testing.expectEqual(Click.absorbed, clickAt(&ms, &art, ctx, .select_map, pick.x + 2, pick.y + 2));
    const rows = art.rows(l.list.?.w);
    _ = clickAt(&ms, &art, ctx, .select_map, l.list.?.x + rows.x + 5, l.list.?.y + rows.y + entry_h + 2);
    try testing.expectEqual(Command{ .select_map = 1 }, clickAt(&ms, &art, ctx, .select_map, pick.x + 2, pick.y + 2).command);

    // Dragging moves the menu.
    const x0 = ms.open[0].x;
    _ = ms.press(&art, ctx, x0 + 50, ms.open[0].y + 2, 0);
    try testing.expect(ms.motion(x0 + 60, ms.open[0].y + 2));
    _ = ms.release(ctx, x0 + 60, 0);
    try testing.expectEqual(x0 + 10, ms.open[0].x);
    try testing.expect(!ms.motion(0, 0));
}
