//! The server's computer players: Zig bots (see bot.zig) running in the
//! server's own loop. They connect over the loopback like any player, so
//! the server treats them no differently.

const std = @import("std");
const k = @import("../game/constants.zig");
const Terrain = @import("../game/map.zig").Terrain;
const Bot = @import("../bot.zig").Bot;

pub const Bots = struct {
    gpa: std.mem.Allocator,
    port: u16,
    terrain: *const Terrain,
    bots: [k.Team.count]?*Bot = @splat(null),
    seed: u64,

    pub fn start(b: *Bots, team: k.Team) void {
        const slot = &b.bots[@intFromEnum(team)];
        if (slot.* != null) return;
        b.seed +%= 0x9E3779B97F4A7C15;
        slot.* = Bot.connect(b.gpa, "127.0.0.1", b.port, b.terrain, team, b.seed) catch |err| {
            std.log.warn("could not start a bot for the {s} team: {t}", .{ team.name(), err });
            return;
        };
        std.log.info("started a bot for the {s} team", .{team.name()});
    }

    /// Let the bots read the game and think.
    pub fn update(b: *Bots, real_time: f64) void {
        for (&b.bots, 0..) |*slot, i| if (slot.*) |bot| {
            bot.update(real_time) catch |err| std.log.warn("bot for the {s} team: {t}", .{ @as(k.Team, @enumFromInt(i)).name(), err });
            if (!bot.connected()) {
                bot.deinit();
                slot.* = null;
            }
        };
    }

    pub fn deinit(b: *Bots) void {
        for (&b.bots) |*slot| if (slot.*) |bot| {
            bot.deinit();
            slot.* = null;
        };
    }
};
