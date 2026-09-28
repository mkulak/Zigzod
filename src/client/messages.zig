//! Text and notices over the map: news and chat lines at the bottom left,
//! the flashing computer messages at the top ("Robot manufactured"), the
//! column of finished guns waiting to be placed, the pause notice and the
//! vote box (RenderNews, ZCompMessageEngine, ZVote).

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const font = @import("font.zig");

const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const Image = gfx.Image;
const Assets = @import("assets.zig").Assets;
const Canvas = gfx.Canvas;
const Rect = gfx.Rect;

// ---------------------------------------------------------------------------
// News
// ---------------------------------------------------------------------------

pub const News = struct {
    gpa: std.mem.Allocator,
    /// Newest first.
    lines: std.ArrayList(Line) = .empty,
    /// Show old lines too ('h').
    history: bool = false,

    const Line = struct { text: []u8, color: gfx.Color, until: f64 };
    const lasting = 17.0;
    const fade = 5.0;
    const max_lines = 50;
    const line_h = 15;

    pub fn deinit(n: *News) void {
        for (n.lines.items) |l| n.gpa.free(l.text);
        n.lines.deinit(n.gpa);
    }

    /// A line in the given color (black means plain white), shown for a
    /// while (`time` is real time).
    pub fn add(n: *News, text: []const u8, color_in: gfx.Color, time: f64) void {
        if (text.len == 0) return;
        const color: gfx.Color = if (color_in.r == 0 and color_in.g == 0 and color_in.b == 0) .{ .r = 255, .g = 255, .b = 255 } else color_in;
        const copy = n.gpa.dupe(u8, text) catch return;
        n.lines.insert(n.gpa, 0, .{ .text = copy, .color = color, .until = time + lasting }) catch {
            n.gpa.free(copy);
            return;
        };
        while (n.lines.items.len > max_lines) n.gpa.free(n.lines.pop().?.text);
    }

    /// Upwards from `bottom`, fading out before they go.
    pub fn draw(n: *const News, cv: Canvas, fonts: *const font.Fonts, x: i32, bottom: i32, time: f64) void {
        const f = fonts.get(.small_white);
        var y = bottom - line_h;
        for (n.lines.items) |l| {
            const left = l.until - time;
            if (!n.history and left <= 0) continue;
            const alpha: u8 = if (n.history or left >= fade) 255 else @intFromFloat(255 * left / fade);
            f.drawTinted(cv, l.text, x, y, l.color, alpha);
            y -= line_h;
            if (y < 0) break;
        }
    }
};

// ---------------------------------------------------------------------------
// Computer messages, guns to place, pause, vote
// ---------------------------------------------------------------------------

pub const Message = enum { robot_manufactured, vehicle_manufactured, gun_manufactured, fort_under_attack };

pub const Images = struct {
    messages: [4]Image,
    gun: Image,
    click_to_resume: Image,
    vote: Image,

    pub fn load(a: *Assets) Assets.Error!Images {
        return .{
            .messages = .{
                try a.image("other/comp_messages/robot_manufactured.png", .{}),
                try a.image("other/comp_messages/vehicle_manufactured.png", .{}),
                try a.image("other/comp_messages/gun_manufactured.png", .{}),
                try a.image("other/comp_messages/fort_under_attack.png", .{}),
            },
            .gun = try a.image("other/comp_messages/gun.png", .{}),
            .click_to_resume = try a.image("other/comp_messages/click_to_resume.png", .{}),
            .vote = try a.image("other/menus/vote_in_progress.png", .{}),
        };
    }
};

/// What clicking a notice asks for.
pub const Click = union(enum) {
    /// Look at and select this unit.
    select: i32,
    /// Look at this building and open its window.
    open: i32,
    /// Look at this.
    look: i32,
    resume_game,
};

pub const Notices = struct {
    /// The message flashing at the top, about `ref_id`.
    shown: ?struct { msg: Message, ref_id: i32, start: f64 } = null,

    const max_guns = 8;
    const flashes = 10;
    const flash_time = 0.3;
    const linger = 5.0;

    /// Flash a message (`time` is real time, like everything here).
    pub fn show(n: *Notices, msg: Message, ref_id: i32, time: f64) void {
        n.shown = .{ .msg = msg, .ref_id = ref_id, .start = time };
    }

    /// Visible now? It blinks ten times, then stays for five seconds.
    fn visible(n: *Notices, time: f64) ?Message {
        const s = n.shown orelse return null;
        const t = time - s.start;
        if (t >= flashes * flash_time + linger) {
            n.shown = null;
            return null;
        }
        if (t >= flashes * flash_time) return s.msg;
        const flip: u32 = @intFromFloat(t / flash_time);
        return if (flip % 2 == 0) s.msg else null;
    }

    /// Our forts and factories with finished guns (one row each).
    fn gunBuildings(world: *const World, team: k.Team, out: *[max_guns]*Object) []*Object {
        var n: usize = 0;
        for (world.objects.items) |o| {
            if (o.owner != team or team == .none or o.isDestroyed() or n == max_guns) continue;
            const b = o.building() orelse continue;
            if (!b.producesUnits() or b.cannons.items.len == 0) continue;
            out[n] = o;
            n += 1;
        }
        return out[0..n];
    }

    fn messageRect(images: *const Images, msg: Message, area: Rect) Rect {
        const img = images.messages[@intFromEnum(msg)];
        return .{ .x = area.x + ((area.w - img.width()) >> 1), .y = area.y + 20, .w = img.width(), .h = img.height() };
    }

    fn resumeRect(images: *const Images, area: Rect) Rect {
        const img = images.click_to_resume;
        return .{ .x = area.x + ((area.w - img.width()) >> 1), .y = area.y + ((area.h - img.height()) >> 1), .w = img.width(), .h = img.height() };
    }

    /// A click at screen point (x, y) on one of the notices.
    pub fn click(n: *Notices, world: *const World, team: k.Team, paused: bool, images: *const Images, area: Rect, x: i32, y: i32, time: f64) ?Click {
        if (n.shown) |s| if (n.visible(time) != null or time - s.start < flashes * flash_time) {
            if (within(messageRect(images, s.msg, area), x, y)) {
                return switch (s.msg) {
                    .robot_manufactured, .vehicle_manufactured => .{ .select = s.ref_id },
                    .gun_manufactured => .{ .open = s.ref_id },
                    .fort_under_attack => .{ .look = s.ref_id },
                };
            }
        };
        {
            const gun = images.gun;
            var buf: [max_guns]*Object = undefined;
            var gy = area.y + 8;
            for (gunBuildings(world, team, &buf)) |o| {
                if (within(.{ .x = area.x + 8, .y = gy, .w = gun.width(), .h = gun.height() }, x, y)) return .{ .open = o.ref_id };
                gy += 2 + gun.height();
            }
        }
        if (paused and within(resumeRect(images, area), x, y)) return .resume_game;
        return null;
    }

    fn within(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x <= r.x + r.w and y <= r.y + r.h;
    }

    pub const Vote = struct {
        description: []const u8,
        needed: usize,
        yes: usize,
        no: usize,
        have: usize = 1,
    };

    pub fn draw(n: *Notices, cv: Canvas, world: *const World, team: k.Team, paused: bool, vote: ?Vote, images: *const Images, fonts: *const font.Fonts, area: Rect, time: f64) void {
        if (n.visible(time)) |msg| {
            const r = messageRect(images, msg, area);
            cv.draw(images.messages[@intFromEnum(msg)], r.x, r.y);
        }
        {
            const gun = images.gun;
            var buf: [max_guns]*Object = undefined;
            var gy = area.y + 8;
            const small = fonts.get(.small_white);
            for (gunBuildings(world, team, &buf)) |o| {
                cv.draw(gun, area.x + 8, gy);
                const count = o.building().?.cannons.items.len;
                if (count > 1) {
                    var tb: [8]u8 = undefined;
                    small.draw(cv, std.fmt.bufPrint(&tb, "X{d}", .{count}) catch "", area.x + 8 + gun.width() + 4, gy + 3);
                }
                gy += 2 + gun.height();
            }
        }
        if (paused) {
            const r = resumeRect(images, area);
            cv.draw(images.click_to_resume, r.x, r.y);
        }
        if (vote) |v| {
            const box = images.vote;
            const x = area.x + area.w - box.width() - 4;
            const y = area.y + 4;
            cv.drawAlpha(box, x, y, 200);
            const f = fonts.get(.yellow_menu);
            const centered = struct {
                fn put(ft: *const font.Font, c: Canvas, text: []const u8, cx: i32, cy: i32) void {
                    ft.drawTinted(c, text, cx - (ft.width(text) >> 1), cy - (ft.height(text) >> 1), .{ .r = 255, .g = 255, .b = 255 }, 200);
                }
            }.put;
            // Shorten the description to fit.
            var desc_buf: [128]u8 = undefined;
            var desc = v.description[0..@min(v.description.len, desc_buf.len - 2)];
            while (desc.len >= 3 and f.width(desc) > 112 - 8) {
                @memcpy(desc_buf[0 .. desc.len - 3], desc[0 .. desc.len - 3]);
                desc_buf[desc.len - 3] = '.';
                desc_buf[desc.len - 2] = '.';
                desc = desc_buf[0 .. desc.len - 1];
            }
            var nb: [4][12]u8 = undefined;
            centered(f, cv, desc, x + 57, y + 41);
            centered(f, cv, std.fmt.bufPrint(&nb[0], "{d}", .{v.have}) catch "", x + 57, y + 53);
            centered(f, cv, std.fmt.bufPrint(&nb[1], "{d}", .{v.needed}) catch "", x + 57, y + 64);
            centered(f, cv, std.fmt.bufPrint(&nb[2], "{d}", .{v.yes}) catch "", x + 22, y + 64);
            centered(f, cv, std.fmt.bufPrint(&nb[3], "{d}", .{v.no}) catch "", x + 91, y + 64);
        }
    }
};

test "messages blink, then stay, then go" {
    var n: Notices = .{};
    n.show(.robot_manufactured, 5, 100);
    try std.testing.expect(n.visible(100.1) != null);
    try std.testing.expect(n.visible(100.4) == null);
    try std.testing.expect(n.visible(104) != null);
    try std.testing.expect(n.visible(109) == null);
    try std.testing.expect(n.shown == null);

    var news: News = .{ .gpa = std.testing.allocator };
    defer news.deinit();
    for (0..60) |i| news.add(if (i % 2 == 0) "hello" else "world", .{ .r = 255, .g = 0, .b = 0 }, 0);
    try std.testing.expectEqual(50, news.lines.items.len);
}
