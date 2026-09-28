//! The heads-up display: the panel on the right (clock, portrait, selected
//! unit, health, minimap, buttons) and the bar at the bottom (unit count,
//! chat line, unit buttons) (ZHud and ZMiniMap).
//!
//! The art is laid out for a 648x484 screen; the panel stays in the bottom
//! right corner and the bar stretches along the bottom. It is drawn
//! completely every frame.

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const font = @import("font.zig");

const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const Image = gfx.Image;
const Rect = gfx.Rect;

pub const width = 100;
pub const height = 36;

/// Size of the layout the art was made for.
const base_w = 648;
const base_h = 484;
/// Where the side panel starts in that layout.
const side_x = 548;
/// Where the bottom bar starts.
const bottom_y = 448;

pub const Button = enum {
    /// Jump to a unit that is under attack.
    a,
    /// Show the factory production list.
    b,
    d,
    /// Select the next gun (cannon).
    g,
    menu,
    /// Select the next robot.
    r,
    t,
    /// Select the next vehicle.
    v,
    z,

    const count = @typeInfo(Button).@"enum".fields.len;

    /// Position in the base layout; the unit buttons sit at the left end
    /// of the bottom bar whatever the screen size.
    fn pos(b: Button) struct { x: i32, y: i32, left: bool = false } {
        return switch (b) {
            .a => .{ .x = 556, .y = 8 },
            .b => .{ .x = 68, .y = 458, .left = true },
            .d => .{ .x = 586, .y = 264 },
            .g => .{ .x = 98, .y = 458, .left = true },
            .menu => .{ .x = 482, .y = 458 },
            .r => .{ .x = 8, .y = 458, .left = true },
            .t => .{ .x = 556, .y = 264 },
            .v => .{ .x = 38, .y = 458, .left = true },
            .z => .{ .x = 616, .y = 264 },
        };
    }
};

pub const ButtonState = enum { active, inactive, pressed };

/// What a click on the HUD did.
pub const Click = union(enum) {
    /// Over the HUD, nothing in particular.
    none,
    button: Button,
    /// A spot on the map (from the minimap).
    map: [2]i32,
    /// Look at (and select) this object.
    jump: i32,
};

const Images = struct {
    buttons: [Button.count][3]?Image = @splat(@splat(null)),
    side: gfx.TeamImages = @splat(null),
    bottom_left: ?Image = null,
    bottom_center: ?Image = null,
    bottom_right: ?Image = null,
    side_filler: ?Image = null,
    health_full: ?Image = null,
    health_lost: ?Image = null,
    health_empty: ?Image = null,
    unit_amount_bar: gfx.TeamImages = @splat(null),
    grenade: gfx.TeamImages = @splat(null),
    robot_icon: [k.Robot.count]gfx.TeamImages = @splat(@splat(null)),
    cannon_icon: [k.Cannon.count]gfx.TeamImages = @splat(@splat(null)),
    vehicle_icon: [k.Vehicle.count]gfx.TeamImages = @splat(@splat(null)),
    robot_label: [k.Robot.count]?Image = @splat(null),
    cannon_label: [k.Cannon.count]?Image = @splat(null),
    vehicle_label: [k.Vehicle.count]?Image = @splat(null),
    /// The driver's name plate, in the team's color.
    unit_label: [k.Robot.count]gfx.TeamImages = @splat(@splat(null)),

    fn load(assets: []const u8, palettes: *const gfx.TeamPalettes) Images {
        var m: Images = .{};
        const dir = "{s}/other/hud/";
        for (&m.buttons, 0..) |*imgs, b| {
            for (imgs, [_][]const u8{ "active", "inactive", "pressed" }) |*img, state| {
                img.* = one(assets, dir ++ "{s}_button_{s}.bmp", .{ @tagName(@as(Button, @enumFromInt(b))), state });
            }
        }
        m.side = gfx.loadTeamImages(palettes, dir ++ "main_hud_side_{s}.png", .{assets});
        m.bottom_left = one(assets, dir ++ "main_hud_bottom_left.bmp", .{});
        m.bottom_center = one(assets, dir ++ "main_hud_bottom_center.bmp", .{});
        m.bottom_right = one(assets, dir ++ "main_hud_bottom_right.bmp", .{});
        m.side_filler = one(assets, dir ++ "side_filler.bmp", .{});
        m.health_full = one(assets, dir ++ "health_full.png", .{});
        m.health_lost = one(assets, dir ++ "health_lost.png", .{});
        m.health_empty = one(assets, dir ++ "health_empty.png", .{});
        m.unit_amount_bar = gfx.loadTeamImages(palettes, dir ++ "unit_amount_bar_{s}.bmp", .{assets});
        m.grenade = gfx.loadTeamImages(palettes, dir ++ "icon_grenade_{s}.png", .{assets});
        inline for (.{ .{ k.Robot, "robot" }, .{ k.Cannon, "cannon" }, .{ k.Vehicle, "vehicle" } }) |kind| {
            for (0..kind[0].count) |i| {
                const name = @tagName(@as(kind[0], @enumFromInt(i)));
                @field(m, kind[1] ++ "_icon")[i] = gfx.loadTeamImages(palettes, dir ++ "icon_{s}_{s}.png", .{ assets, name });
                @field(m, kind[1] ++ "_label")[i] = one(assets, dir ++ "label_{s}.png", .{name});
            }
        }
        for (&m.unit_label, 0..) |*l, i| l.* = gfx.loadTeamImages(palettes, dir ++ "unit_label_{s}_{s}.png", .{ assets, @tagName(@as(k.Robot, @enumFromInt(i))) });
        return m;
    }

    fn one(assets: []const u8, comptime fmt: []const u8, args: anytype) ?Image {
        var buf: [512]u8 = undefined;
        return Image.load(std.fmt.bufPrintZ(&buf, fmt, .{assets} ++ args) catch return null);
    }

    fn deinit(m: *Images) void {
        inline for (@typeInfo(Images).@"struct".fields) |f| free(&@field(m, f.name));
    }

    fn free(x: anytype) void {
        switch (@typeInfo(@TypeOf(x.*))) {
            .array => for (x) |*e| free(e),
            .optional => if (x.*) |img| img.deinit(),
            else => comptime unreachable,
        }
    }
};

/// The minimap's corner in the base layout, and its largest size.
const minimap_x = 555;
const minimap_y = 299;
const minimap_w = 647 - 555;
const minimap_h = 388 - 299;

pub const Hud = struct {
    images: Images,
    fonts: *const font.Fonts,
    palettes: *const gfx.TeamPalettes,
    buttons: [Button.count]ButtonState = initialButtons(),
    /// Minimap area within its box (depends on the map's shape).
    minimap: Rect = .{ .x = 0, .y = 0, .w = minimap_w, .h = minimap_h },
    map_w: i32 = 0,
    map_h: i32 = 0,

    /// A unit of ours under attack: the A button flashes.
    alert: ?i32 = null,
    alert_misses: u8 = 0,
    next_alert_check: f64 = 0,
    next_alert_flash: f64 = 0,

    pub fn init(assets: []const u8, palettes: *const gfx.TeamPalettes, fonts: *const font.Fonts) Hud {
        return .{ .images = .load(assets, palettes), .fonts = fonts, .palettes = palettes };
    }

    pub fn deinit(h: *Hud) void {
        h.images.deinit();
    }

    fn initialButtons() [Button.count]ButtonState {
        var b: [Button.count]ButtonState = @splat(.active);
        for ([_]Button{ .a, .b, .g, .r, .v }) |x| b[@intFromEnum(x)] = .inactive;
        return b;
    }

    pub fn reset(h: *Hud) void {
        h.buttons = initialButtons();
        h.alert = null;
    }

    /// Fit the minimap to a new map's shape (ZMiniMap::Setup_Boundaries).
    pub fn setMap(h: *Hud, m: *const game.map.Map) void {
        const tiles_w: f64 = @floatFromInt(m.header.width);
        const tiles_h: f64 = @floatFromInt(m.header.height);
        const ratio = tiles_w / tiles_h;
        var r: Rect = .{ .x = 0, .y = 0, .w = minimap_w, .h = minimap_h };
        if (ratio < @as(f64, minimap_w) / minimap_h) {
            r.w = @intFromFloat(ratio * minimap_h);
        } else {
            r.h = @intFromFloat(minimap_w / ratio);
        }
        r.x = ((minimap_w - r.w) >> 1) + 2;
        r.y = ((minimap_h - r.h) >> 1) + 2;
        r.w -= 4;
        r.h -= 4;
        h.minimap = r;
        h.map_w = m.widthPixels();
        h.map_h = m.heightPixels();
    }

    pub fn state(h: *const Hud, b: Button) ButtonState {
        return h.buttons[@intFromEnum(b)];
    }

    /// Unit buttons are active while we have such units, the production
    /// list button while we have buildings (ZPlayer::ReSetupButtons).
    pub fn updateButtons(h: *Hud, world: *const World, team: k.Team) void {
        var have: struct { building: bool = false, cannon: bool = false, vehicle: bool = false, robot: bool = false } = .{};
        if (team != .none) for (world.objects.items) |o| {
            if (o.owner != team) continue;
            switch (o.kind) {
                .building => have.building = true,
                .cannon => have.cannon = true,
                .vehicle => have.vehicle = true,
                .robot => have.robot = true,
                else => {},
            }
        };
        for ([_]struct { Button, bool }{ .{ .b, have.building }, .{ .g, have.cannon }, .{ .v, have.vehicle }, .{ .r, have.robot } }) |bh| {
            const s = &h.buttons[@intFromEnum(bh[0])];
            if (!bh[1]) s.* = .inactive else if (s.* == .inactive) s.* = .active;
        }
    }

    /// One of our units was attacked; flash the A button (sometimes).
    pub fn attacked(h: *Hud, target: i32, time: f64, rng: std.Random) void {
        if (h.alert != null or rng.uintLessThan(u32, 5) != 0) return;
        h.alert = target;
        h.alert_misses = 0;
        h.next_alert_check = time + 0.25;
        h.next_alert_flash = time + 0.15;
    }

    /// The alert goes away when the unit is gone or has not been under
    /// attack for a few seconds (ZHud::ProcessA).
    pub fn update(h: *Hud, world: *const World, time: f64) void {
        const id = h.alert orelse return;
        const a = &h.buttons[@intFromEnum(Button.a)];
        if (world.find(id) == null) return h.endAlert();
        if (time >= h.next_alert_check) {
            h.next_alert_check = time + 0.25;
            const attacked_now = for (world.objects.items) |o| {
                if (o.attack_target == id) break true;
            } else false;
            if (attacked_now) {
                h.alert_misses = 0;
            } else if (h.alert_misses < 10) {
                h.alert_misses += 1;
            } else return h.endAlert();
        }
        if (time >= h.next_alert_flash) {
            h.next_alert_flash = time + 0.15;
            a.* = if (a.* == .inactive) .active else .inactive;
        }
    }

    fn endAlert(h: *Hud) void {
        h.alert = null;
        h.buttons[@intFromEnum(Button.a)] = .inactive;
    }

    // -----------------------------------------------------------------------
    // Layout
    // -----------------------------------------------------------------------

    /// Offset of the base layout on a screen of this size.
    fn offset(screen_w: i32, screen_h: i32) [2]i32 {
        return .{ screen_w - base_w, screen_h - base_h };
    }

    fn buttonRect(h: *const Hud, b: Button, off: [2]i32) ?Rect {
        const img = h.images.buttons[@intFromEnum(b)][@intFromEnum(h.state(b))] orelse return null;
        const p = b.pos();
        return .{ .x = p.x + if (p.left) 0 else off[0], .y = p.y + off[1], .w = img.width(), .h = img.height() };
    }

    pub fn contains(screen_w: i32, screen_h: i32, x: i32, y: i32) bool {
        return x >= screen_w - width or y >= screen_h - height;
    }

    /// The map spot under a point of the minimap, if it is over it.
    pub fn minimapSpot(h: *const Hud, screen_w: i32, screen_h: i32, x: i32, y: i32) ?[2]i32 {
        if (h.map_w == 0) return null;
        const off = offset(screen_w, screen_h);
        const rx = x - off[0] - minimap_x - h.minimap.x;
        const ry = y - off[1] - minimap_y - h.minimap.y;
        if (rx < 0 or ry < 0 or rx > h.minimap.w or ry > h.minimap.h) return null;
        const fx = @as(f64, @floatFromInt(rx)) / @as(f64, @floatFromInt(@max(h.minimap.w, 1)));
        const fy = @as(f64, @floatFromInt(ry)) / @as(f64, @floatFromInt(@max(h.minimap.h, 1)));
        return .{ @intFromFloat(fx * @as(f64, @floatFromInt(h.map_w))), @intFromFloat(fy * @as(f64, @floatFromInt(h.map_h))) };
    }

    // -----------------------------------------------------------------------
    // Mouse
    // -----------------------------------------------------------------------

    /// Left button pressed at (x, y); null when not over the HUD.
    pub fn press(h: *Hud, screen_w: i32, screen_h: i32, x: i32, y: i32) ?Click {
        if (!contains(screen_w, screen_h, x, y)) return null;
        const off = offset(screen_w, screen_h);
        for (0..Button.count) |i| {
            const b: Button = @enumFromInt(i);
            const r = h.buttonRect(b, off) orelse continue;
            if (!r.contains(x, y)) continue;
            if (b == .a) return if (h.alert) |id| .{ .jump = id } else .none;
            if (h.buttons[i] == .active) h.buttons[i] = .pressed;
            return .none;
        }
        if (h.minimapSpot(screen_w, screen_h, x, y)) |spot| return .{ .map = spot };
        return .none;
    }

    /// Left button released: a pressed button under the mouse is clicked.
    pub fn release(h: *Hud, screen_w: i32, screen_h: i32, x: i32, y: i32) Click {
        const off = offset(screen_w, screen_h);
        var clicked: Click = .none;
        for (&h.buttons, 0..) |*s, i| {
            if (s.* != .pressed) continue;
            const b: Button = @enumFromInt(i);
            if (h.buttonRect(b, off)) |r| if (r.contains(x, y)) {
                clicked = .{ .button = b };
            };
            s.* = .active;
        }
        return clicked;
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    pub const View = struct {
        world: *const World,
        team: k.Team,
        /// The unit shown in the panel.
        selected: ?*const Object,
        time: f64,
        /// The map area on screen, in map coordinates.
        view: Rect,
        /// Text being typed into the chat line.
        chat: ?[]const u8 = null,
    };

    pub fn draw(h: *const Hud, screen: Image, v: View) void {
        const sw = screen.width();
        const sh = screen.height();
        const off = offset(sw, sh);
        const cv: gfx.Canvas = .{ .target = screen, .clip = .{ .x = 0, .y = 0, .w = sw, .h = sh } };
        const m = &h.images;
        const team = @intFromEnum(v.team);

        // Bottom bar: left end, stretched middle, right end.
        const bar_y = off[1] + bottom_y;
        const right_end = side_x + off[0];
        var chat_area: Rect = .{ .x = 0, .y = off[1] + 460, .w = 0, .h = 18 };
        if (m.bottom_left) |left| {
            cv.draw(left, 0, bar_y);
            h.drawUnitAmount(cv, v, off);
            if (m.bottom_center) |center| if (m.bottom_right) |right| {
                var x = left.width();
                const end = right_end - right.width();
                chat_area.x = x;
                chat_area.w = end - x;
                while (x < end) : (x += center.width()) {
                    cv.drawPart(center, .{ .x = 0, .y = 0, .w = @min(center.width(), end - x), .h = center.height() }, x, bar_y);
                }
                cv.draw(right, end, bar_y);
            };
        }

        // Side panel, with filler above it on tall screens.
        if (m.side_filler) |filler| {
            var y: i32 = 0;
            while (y < off[1]) : (y += filler.height()) cv.draw(filler, right_end, y);
        }
        if (m.side[team]) |side| cv.draw(side, right_end, off[1]);

        for (0..Button.count) |i| {
            const b: Button = @enumFromInt(i);
            const r = h.buttonRect(b, off) orelse continue;
            if (m.buttons[i][@intFromEnum(h.buttons[i])]) |img| cv.draw(img, r.x, r.y);
        }

        h.drawClock(cv, v.time, off);
        h.drawSelected(cv, v, off);
        h.drawMinimap(cv, v, off);
        h.drawChat(cv, chat_area, v.chat);
    }

    fn drawUnitAmount(h: *const Hud, cv: gfx.Canvas, v: View, off: [2]i32) void {
        const bar = h.images.unit_amount_bar[@intFromEnum(v.team)] orelse return;
        const y = off[1] + 460;
        cv.fill(.{ .x = 132, .y = y, .w = 62, .h = 16 }, .{ .r = 0, .g = 0, .b = 0 });
        var units: i32 = 0;
        for (v.world.objects.items) |o| {
            if (o.isUnit() and o.owner == v.team) units += 1;
        }
        const max = @max(v.world.max_units_per_team, 1);
        const fraction = std.math.clamp(@as(f64, @floatFromInt(units)) / @as(f64, @floatFromInt(max)), 0, 1);
        const w: i32 = @intFromFloat(@as(f64, @floatFromInt(bar.width())) * fraction);
        if (w > 0) cv.drawPart(bar, .{ .x = 0, .y = 0, .w = w, .h = bar.height() }, 132, y);
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{units}) catch return;
        h.fonts.get(.small_white).draw(cv, text, 132 + 3, y + 5);
    }

    /// Game time as h:mm:ss in the three boxes at the top of the panel.
    fn drawClock(h: *const Hud, cv: gfx.Canvas, time: f64, off: [2]i32) void {
        const total: u64 = @intFromFloat(@max(time, 0));
        const hours = total / 3600;
        const f = h.fonts.get(.big_white);
        var buf: [8]u8 = undefined;
        const x = off[0] + side_x;
        const y = off[1] + 9;
        f.draw(cv, if (hours <= 9) std.fmt.bufPrint(&buf, "{d}", .{hours}) catch "" else "!", x + 38, y);
        f.draw(cv, std.fmt.bufPrint(&buf, "{d:0>2}", .{(total / 60) % 60}) catch "", x + 52, y);
        f.draw(cv, std.fmt.bufPrint(&buf, "{d:0>2}", .{total % 60}) catch "", x + 75, y);
    }

    fn drawSelected(h: *const Hud, cv: gfx.Canvas, v: View, off: [2]i32) void {
        const m = &h.images;
        const team = @intFromEnum(v.team);
        const x = off[0] + 550;
        const health_x = off[0] + side_x + 14;
        const health_y = off[1] + 213;
        const o = v.selected orelse {
            if (m.health_empty) |img| cv.draw(img, health_x, health_y);
            return;
        };
        const icon: ?Image, const label: ?Image, const driver: ?k.Robot = switch (o.kind) {
            .robot => |r| .{ m.robot_icon[@intFromEnum(r)][team], m.robot_label[@intFromEnum(r)], r },
            .vehicle => |veh| .{ m.vehicle_icon[@intFromEnum(veh.type)][team], m.vehicle_label[@intFromEnum(veh.type)], o.driver_type },
            .cannon => |cn| .{ m.cannon_icon[@intFromEnum(cn.type)][team], m.cannon_label[@intFromEnum(cn.type)], o.driver_type },
            else => .{ null, null, null },
        };
        if (icon) |img| {
            const shift: i32 = if (o.kind == .robot) 3 else 30 - (img.height() >> 1);
            cv.draw(img, x, off[1] + 148 + shift);
        }
        if (driver) |d| if (m.unit_label[@intFromEnum(d)][team]) |img| cv.draw(img, x, off[1] + 124);
        if (label) |img| cv.draw(img, x, off[1] + 230);

        if (o.canHaveGrenades()) {
            if (m.grenade[@intFromEnum(o.owner)]) |img| cv.draw(img, off[0] + 575, off[1] + 185);
            var buf: [8]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d:0>2}", .{@as(u32, @intCast(@max(o.grenades, 0)))}) catch "";
            h.fonts.get(.big_white).draw(cv, text, off[0] + 600, off[1] + 187);
        }

        // Health: green what is left, yellow what was lost and can be
        // repaired, empty beyond the unit's maximum.
        const full = m.health_full orelse return;
        const lost = m.health_lost orelse return;
        const empty = m.health_empty orelse return;
        if (o.isDestroyed()) return cv.draw(empty, health_x, health_y);
        const max_dist = 74;
        const green: i32 = @max(@divTrunc(max_dist * o.health, k.max_unit_health), 1);
        const yellow: i32 = @max(@divTrunc(max_dist * o.max_health, k.max_unit_health), 1);
        cv.drawPart(full, .{ .x = 0, .y = 0, .w = green, .h = 8 }, health_x, health_y);
        if (yellow > green) cv.drawPart(lost, .{ .x = green, .y = 0, .w = yellow - green, .h = 8 }, health_x + green, health_y);
        if (max_dist > yellow) cv.drawPart(empty, .{ .x = yellow, .y = 0, .w = max_dist - yellow, .h = 8 }, health_x + yellow, health_y);
    }

    /// Zones in their owner's color, objects as dots, the view as a box.
    fn drawMinimap(h: *const Hud, cv: gfx.Canvas, v: View, off: [2]i32) void {
        if (h.map_w == 0) return;
        const area: Rect = .{ .x = off[0] + minimap_x + h.minimap.x, .y = off[1] + minimap_y + h.minimap.y, .w = h.minimap.w, .h = h.minimap.h };
        const mini: gfx.Canvas = .{ .target = cv.target, .clip = area.intersect(cv.clip) orelse return };
        mini.fill(area, .{ .r = 10, .g = 10, .b = 10 });
        const ratio = @as(f64, @floatFromInt(area.h)) / @as(f64, @floatFromInt(h.map_h));
        const scale = struct {
            fn f(val: i32, r: f64) i32 {
                return @intFromFloat(@as(f64, @floatFromInt(val)) * r);
            }
        }.f;
        for (v.world.zones.items) |z| {
            const r: Rect = .{ .x = area.x + scale(z.x, ratio) + 1, .y = area.y + scale(z.y, ratio) + 1, .w = scale(z.w, ratio) - 2, .h = scale(z.h, ratio) - 2 };
            if (r.w <= 0 or r.h <= 0) continue;
            const c = h.palettes.color(z.owner);
            mini.fill(r, .{ .r = @intFromFloat(@as(f64, @floatFromInt(c.r)) * 0.4), .g = @intFromFloat(@as(f64, @floatFromInt(c.g)) * 0.4), .b = @intFromFloat(@as(f64, @floatFromInt(c.b)) * 0.4) });
        }
        for (v.world.objects.items) |o| {
            const r: Rect = .{
                .x = area.x + scale(o.x, ratio),
                .y = area.y + scale(o.y, ratio),
                .w = @max(scale(@divTrunc(o.width_pix * 4, 5), ratio), 1),
                .h = @max(scale(@divTrunc(o.height_pix * 4, 5), ratio), 1),
            };
            mini.fill(r, h.palettes.color(o.owner));
        }
        mini.outline(.{
            .x = area.x + scale(v.view.x, ratio),
            .y = area.y + scale(v.view.y, ratio),
            .w = scale(v.view.w, ratio),
            .h = scale(v.view.h, ratio),
        }, .{ .r = 200, .g = 200, .b = 0 });
    }

    /// "Say:: ..." while typing; long text shows its end.
    fn drawChat(h: *const Hud, cv: gfx.Canvas, area: Rect, typing: ?[]const u8) void {
        if (area.w <= 0) return;
        cv.fill(area, .{ .r = 115, .g = 115, .b = 115 });
        const text = typing orelse return;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Say:: {s}", .{text}) catch return;
        const f = h.fonts.get(.small_white);
        const inner = area.w - 6;
        if (inner <= 0) return;
        const clip: gfx.Canvas = .{ .target = cv.target, .clip = .{ .x = area.x + 3, .y = area.y, .w = inner, .h = area.h } };
        // Right aligned once it no longer fits.
        const w = f.width(line);
        f.draw(clip, line, area.x + 3 - @max(w - inner, 0), area.y + 5);
    }
};

test "minimap maps points to the map" {
    var h: Hud = undefined;
    h.minimap = .{ .x = 0, .y = 0, .w = minimap_w, .h = minimap_h };
    h.map_w = 0;
    try std.testing.expect(h.minimapSpot(800, 600, 700, 500) == null);
    var header = std.mem.zeroes(game.map.Header);
    header.width = 64;
    header.height = 32;
    const m: game.map.Map = .{ .header = header, .tiles = &.{}, .placements = &.{}, .zones = &.{} };
    h.setMap(&m);
    // A wide map: full width, centered vertically.
    try std.testing.expectEqual(minimap_w - 4, h.minimap.w);
    try std.testing.expect(h.minimap.y > 2);
    const off = Hud.offset(800, 600);
    const corner = h.minimapSpot(800, 600, off[0] + minimap_x + h.minimap.x, off[1] + minimap_y + h.minimap.y).?;
    try std.testing.expectEqual([2]i32{ 0, 0 }, corner);
    const end = h.minimapSpot(800, 600, off[0] + minimap_x + h.minimap.x + h.minimap.w, off[1] + minimap_y + h.minimap.y + h.minimap.h).?;
    try std.testing.expectEqual([2]i32{ 64 * 16, 32 * 16 }, end);
    try std.testing.expect(Hud.contains(800, 600, 750, 10));
    try std.testing.expect(!Hud.contains(800, 600, 100, 100));
}
