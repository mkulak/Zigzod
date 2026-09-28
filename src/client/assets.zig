//! The game's art, loaded once: sprites, HUD, windows, menus, fonts, ...
//!
//! Everything loaded here lives in one arena and is freed together by
//! `deinit`, so nothing loaded needs freeing on its own. Art that fails to
//! load is replaced by a placeholder (a magenta square, reported in the
//! log), so the rest of the client never deals with missing images. Art
//! that may legitimately not exist is asked for with `find`, and `nothing`
//! (a transparent pixel) fills places that have no picture.

const std = @import("std");
const k = @import("../game/constants.zig");
const gfx = @import("gfx.zig");

const Image = gfx.Image;
const Team = k.Team;

pub const Assets = struct {
    pub const Error = std.mem.Allocator.Error;
    arena: std.heap.ArenaAllocator,
    /// The assets folder.
    dir: []const u8,
    palettes: gfx.TeamPalettes,
    /// Stands in for art that failed to load.
    placeholder: Image,
    /// Stands for "no picture here".
    nothing: Image,
    /// How many files failed to load.
    missing: usize = 0,

    pub fn init(gpa: std.mem.Allocator, dir: []const u8) Error!*Assets {
        const a = try gpa.create(Assets);
        errdefer gpa.destroy(a);
        a.* = .{
            .arena = .init(gpa),
            .dir = undefined,
            .palettes = .load(gpa, dir),
            .placeholder = undefined,
            .nothing = undefined,
        };
        errdefer a.arena.deinit();
        const arena = a.arena.allocator();
        a.dir = try arena.dupe(u8, dir);
        a.nothing = try Image.create(arena, 1, 1);
        a.placeholder = try Image.create(arena, 16, 16);
        for (0..16) |y| for (a.placeholder.row(@intCast(y)), 0..) |*p, x| {
            p.* = if ((x / 4 + y / 4) % 2 == 0) 0xFFFF00FF else 0xFF000000;
        };
        return a;
    }

    pub fn deinit(a: *Assets) void {
        const gpa = a.arena.child_allocator;
        a.arena.deinit();
        gpa.destroy(a);
    }

    /// Allocations that live as long as the assets.
    pub fn allocator(a: *Assets) std.mem.Allocator {
        return a.arena.allocator();
    }

    /// A path in the assets folder.
    pub fn path(a: *const Assets, buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
        // Formatted in two steps so that `fmt` can use positional arguments.
        const head = std.fmt.bufPrint(buf, "{s}/", .{a.dir}) catch tooLong();
        const tail = std.fmt.bufPrintZ(buf[head.len..], fmt, args) catch tooLong();
        return buf[0 .. head.len + tail.len :0];
    }

    fn tooLong() noreturn {
        // Only an absurdly long assets folder gets here.
        std.debug.panic("asset path too long", .{});
    }

    /// An image (`fmt` relative to the assets folder); the placeholder if
    /// it can't be read.
    pub fn image(a: *Assets, comptime fmt: []const u8, args: anytype) Error!Image {
        return try a.find(fmt, args) orelse {
            var buf: [512]u8 = undefined;
            std.log.warn("missing art: {s}", .{a.path(&buf, fmt, args)});
            a.missing += 1;
            return a.placeholder;
        };
    }

    /// An image that may not exist.
    pub fn find(a: *Assets, comptime fmt: []const u8, args: anytype) Error!?Image {
        var buf: [512]u8 = undefined;
        return Image.load(a.allocator(), a.path(&buf, fmt, args)) catch |err| switch (err) {
            error.ImageUnreadable => null,
            error.OutOfMemory => |e| e,
        };
    }

    /// `red` recolored for `team`.
    pub fn recolor(a: *Assets, team: Team, red: Image) Error!Image {
        if (red.pixels == a.placeholder.pixels or red.pixels == a.nothing.pixels) return red;
        return a.palettes.make(a.allocator(), team, red);
    }

    /// `base` with `overlay` drawn on it at (x, y).
    pub fn composite(a: *Assets, base: Image, overlay: Image, x: i32, y: i32) Error!Image {
        const img = try base.clone(a.allocator());
        img.draw(overlay, null, x, y);
        return img;
    }

    /// What teams without art of their own get.
    pub const Neutral = enum {
        /// Nothing is drawn.
        nothing,
        /// The neutral file (the team name "null"), or nothing if there
        /// is none.
        file,
        /// The red art.
        red,
    };

    /// One image per team from art drawn for red: `fmt` takes the team
    /// name first, the other teams are recolored from red.
    pub fn teams(a: *Assets, comptime fmt: []const u8, args: anytype, neutral: Neutral) Error![Team.count]Image {
        var out: [Team.count]Image = undefined;
        const red = try a.image(fmt, .{Team.red.name()} ++ args);
        for (&out, 0..) |*img, t| {
            const team: Team = @enumFromInt(t);
            img.* = switch (team) {
                .red => red,
                .none => switch (neutral) {
                    .nothing => a.nothing,
                    .file => try a.find(fmt, .{team.name()} ++ args) orelse a.nothing,
                    .red => red,
                },
                else => try a.recolor(team, red),
            };
        }
        return out;
    }
};

test "missing art becomes the placeholder" {
    const a = try Assets.init(std.testing.allocator, "bin/assets");
    defer a.deinit();
    const img = try a.image("no/such/file_{d}.png", .{7});
    try std.testing.expectEqual(a.placeholder.pixels, img.pixels);
    try std.testing.expectEqual(1, a.missing);
    try std.testing.expect(try a.find("no/such/file.png", .{}) == null);
    const flags = try a.teams("other/flag_{s}_{d}.png", .{0}, .file);
    try std.testing.expect(flags[@intFromEnum(Team.blue)].pixels != flags[@intFromEnum(Team.red)].pixels);
    try std.testing.expect(flags[@intFromEnum(Team.none)].pixels != a.nothing.pixels);
}
