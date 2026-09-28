//! Mouse cursors (ZCursor): one per kind of order, animated over four
//! frames, in the team's color. The past tense kinds ("placed",
//! "attacked", ...) mark where an order was given.

const std = @import("std");
const k = @import("../game/constants.zig");
const gfx = @import("gfx.zig");
const Assets = @import("assets.zig").Assets;

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
    images: [Kind.count][k.Team.count][frames]Image,

    pub fn load(a: *Assets) Assets.Error!Cursors {
        var c: Cursors = undefined;
        for (0..Kind.count) |ki| {
            const kind: Kind = @enumFromInt(ki);
            for (0..frames) |f| {
                if (kind.neutral()) {
                    const img = try a.image("cursors/{s}_n{d:0>2}.png", .{ @tagName(kind), f });
                    for (&c.images[ki]) |*team| team[f] = img;
                    continue;
                }
                // Drawn for red, recolored for the others.
                const v = try a.teams("cursors/{[1]s}_{[0]s}_n{[2]d:0>2}.png", .{ @tagName(kind), f }, .file);
                for (0..k.Team.count) |t| c.images[ki][t][f] = v[t];
            }
        }
        // Without a team the order cursors show their markers (only the
        // plain cursor has art for no team).
        const none = @intFromEnum(k.Team.none);
        for (0..Kind.count) |ki| {
            const kind: Kind = @enumFromInt(ki);
            if (kind.neutral() or kind == .cursor) continue;
            c.images[ki][none] = if (kind == .nono) @splat(a.nothing) else c.images[@intFromEnum(kind.marker())][none];
        }
        return c;
    }

    /// Draw at (x, y); order cursors are centered on the point.
    pub fn draw(c: *const Cursors, cv: gfx.Canvas, kind: Kind, team: k.Team, time: f64, x: i32, y: i32) void {
        const f: usize = @intFromFloat(@mod(@floor(time / 0.2), frames));
        const shift: i32 = if (kind == .cursor) 0 else -8;
        cv.draw(c.images[@intFromEnum(kind)][@intFromEnum(team)][f], x + shift, y + shift);
    }
};

test "cursors" {
    const a = try Assets.init(std.testing.allocator, "bin/assets");
    defer a.deinit();
    const c = try Cursors.load(a);
    try std.testing.expectEqual(0, a.missing);
    const blue = c.images[@intFromEnum(Kind.attack)][@intFromEnum(k.Team.blue)][3];
    const red = c.images[@intFromEnum(Kind.attack)][@intFromEnum(k.Team.red)][3];
    try std.testing.expect(blue.pixels != red.pixels);
    try std.testing.expect(c.images[@intFromEnum(Kind.cursor)][@intFromEnum(k.Team.none)][0].pixels != a.nothing.pixels);
}
