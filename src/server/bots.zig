//! Computer players. Until the bot is ported to Zig, each bot is a separate
//! process of the C++ engine (`zod_engine -c localhost -b <team>`) that
//! connects like any other player.

const std = @import("std");
const k = @import("../game/constants.zig");

pub const Bots = struct {
    /// Program to start for a bot; no bots without one.
    program: ?[]const u8,
    children: [k.Team.count]?std.process.Child = @splat(null),

    pub fn start(b: *Bots, gpa: std.mem.Allocator, io: std.Io, team: k.Team) void {
        _ = gpa;
        const program = b.program orelse {
            std.log.warn("no bot program set, can't start a bot for the {s} team", .{team.name()});
            return;
        };
        const slot = &b.children[@intFromEnum(team)];
        if (slot.* != null) return;
        slot.* = std.process.spawn(io, .{
            .argv = &.{ program, "-c", "localhost", "-b", team.name() },
            .stdin = .ignore,
        }) catch |err| {
            std.log.warn("could not start bot '{s}': {t}", .{ program, err });
            return;
        };
        std.log.info("started a bot for the {s} team", .{team.name()});
    }

    pub fn deinit(b: *Bots, io: std.Io) void {
        for (&b.children) |*slot| if (slot.*) |*child| {
            child.kill(io);
            slot.* = null;
        };
    }
};
