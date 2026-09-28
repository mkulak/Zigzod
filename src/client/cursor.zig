//! Mouse cursors (ZCursor): one per kind of order, animated over four
//! frames, in the team's color. The past tense kinds ("placed",
//! "attacked", ...) mark where an order was given.

const std = @import("std");
const k = @import("../game/constants.zig");
const gfx = @import("gfx.zig");

const Image = gfx.Image;
const frames = 4;

pub const Kind = enum {
    cursor,
    place,
    placed,
    attack,
    attacked,
    grab,
    grabbed,
    grenade,
    grenaded,
    repair,
    repaired,
    nono,
    cannon,
    cannoned,
    enter,
    entered,
    exit,
    exited,

    const count = @typeInfo(Kind).@"enum".fields.len;

    /// The marker left where this kind of order was given.
    pub fn marker(kind: Kind) Kind {
        return switch (kind) {
            .attack => .attacked,
            .grab => .grabbed,
            .grenade => .grenaded,
            .repair => .repaired,
            .enter => .entered,
            .exit => .exited,
            .cannon => .cannoned,
            else => .placed,
        };
    }

    /// Markers look the same for every team.
    fn neutral(kind: Kind) bool {
        return switch (kind) {
            .placed, .attacked, .grabbed, .grenaded, .repaired, .cannoned, .entered, .exited => true,
            else => false,
        };
    }
};

pub const Cursors = struct {
    images: [Kind.count][k.Team.count][frames]?Image = @splat(@splat(@splat(null))),
    /// Neutral images, owned here (the team tables share them).
    owned: [Kind.count][frames]?Image = @splat(@splat(null)),

    pub fn load(assets: []const u8, palettes: *const gfx.TeamPalettes) Cursors {
        var c: Cursors = .{};
        for (0..Kind.count) |ki| {
            const kind: Kind = @enumFromInt(ki);
            for (0..frames) |f| {
                var buf: [256]u8 = undefined;
                if (kind.neutral()) {
                    const path = std.fmt.bufPrintZ(&buf, "{s}/cursors/{s}_n{d:0>2}.png", .{ assets, @tagName(kind), f }) catch continue;
                    c.owned[ki][f] = Image.load(path);
                    for (&c.images[ki]) |*team| team[f] = c.owned[ki][f];
                    continue;
                }
                // Drawn for red, recolored for the others.
                for (0..k.Team.count) |t| {
                    const team: k.Team = @enumFromInt(t);
                    if (team != .none and team != .red) continue;
                    const path = std.fmt.bufPrintZ(&buf, "{s}/cursors/{s}_{s}_n{d:0>2}.png", .{ assets, @tagName(kind), team.name(), f }) catch continue;
                    c.images[ki][t][f] = if (team == .none) Image.loadQuiet(path) else Image.load(path);
                }
                const red = c.images[ki][@intFromEnum(k.Team.red)][f] orelse continue;
                for (0..k.Team.count) |t| {
                    if (t == @intFromEnum(k.Team.none) or t == @intFromEnum(k.Team.red)) continue;
                    c.images[ki][t][f] = palettes.make(@enumFromInt(t), red);
                }
            }
        }
        // Without a team the order cursors show their markers.
        for (0..Kind.count) |ki| {
            const kind: Kind = @enumFromInt(ki);
            if (kind.neutral() or kind == .cursor) continue;
            // (Only the plain cursor has art for no team.)
            const none = @intFromEnum(k.Team.none);
            for (&c.images[ki][none]) |*img| if (img.*) |i| {
                i.deinit();
                img.* = null;
            };
            if (kind != .nono) c.images[ki][none] = c.images[@intFromEnum(kind.marker())][none];
        }
        return c;
    }

    pub fn deinit(c: *Cursors) void {
        for (0..Kind.count) |ki| {
            const kind: Kind = @enumFromInt(ki);
            if (kind.neutral()) {
                for (c.owned[ki]) |img| if (img) |i| i.deinit();
                continue;
            }
            for (c.images[ki], 0..) |team, t| {
                // The neutral team borrows the markers.
                if (t == @intFromEnum(k.Team.none) and kind != .cursor) continue;
                for (team) |img| if (img) |i| i.deinit();
            }
        }
    }

    /// Draw at (x, y); order cursors are centered on the point.
    pub fn draw(c: *const Cursors, cv: gfx.Canvas, kind: Kind, team: k.Team, time: f64, x: i32, y: i32) void {
        const f: usize = @intFromFloat(@mod(@floor(time / 0.2), frames));
        const img = c.images[@intFromEnum(kind)][@intFromEnum(team)][f] orelse return;
        const shift: i32 = if (kind == .cursor) 0 else -8;
        cv.draw(img, x + shift, y + shift);
    }
};

test "cursors" {
    const palettes = gfx.TeamPalettes.load("bin/assets");
    var c = Cursors.load("bin/assets", &palettes);
    defer c.deinit();
    try std.testing.expect(c.images[@intFromEnum(Kind.attack)][@intFromEnum(k.Team.blue)][3] != null);
    try std.testing.expect(c.images[@intFromEnum(Kind.placed)][@intFromEnum(k.Team.green)][0] != null);
    try std.testing.expect(c.images[@intFromEnum(Kind.cursor)][@intFromEnum(k.Team.none)][0] != null);
}
