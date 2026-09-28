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
const Planet = k.Planet;
const teams = Team.count;
const planets = Planet.count;
const dirs = 8;

/// Directions are drawn at these angles (file names use the angle).
fn angle(dir: usize) usize {
    return dir * 45;
}

// ---------------------------------------------------------------------------
// Art given by path patterns
// ---------------------------------------------------------------------------
//
// Most images are given by a path pattern (relative to the assets folder)
// whose placeholders number the file names; a field's array dimensions
// follow its pattern's placeholders, in order:
//
//   {team}    the team's name: the art is drawn for red and recolored for
//             the other teams; neutral gets nothing, or its own file
//             (`.file`), or the red art (`.red`)
//   {planet}  the planet's name
//   {angle}   a direction, as its angle in three digits (000, 045, ...)
//   {frame}   the index in two digits
//   {n}       the index
//
// so `.walk = "units/robots/walk_{team}_r{angle}_n{frame}.png"` fills
// walk: [teams][dirs][4]Image. Patterns and dimensions are checked against
// each other when compiling. Art that doesn't follow one pattern (mirrored
// directions, pictures put together, gaps) is loaded by code below.

const Dim = enum { team, planet, angle, frame, n };
const Vars = [@typeInfo(Dim).@"enum".fields.len]usize;

/// The placeholders of `pattern`, in order.
fn dimsOf(comptime pattern: []const u8) []const Dim {
    comptime {
        var out: []const Dim = &.{};
        var i = 0;
        while (std.mem.indexOfScalarPos(u8, pattern, i, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, pattern, open, '}') orelse @compileError("unclosed { in " ++ pattern);
            const d = std.meta.stringToEnum(Dim, pattern[open + 1 .. close]) orelse
                @compileError("unknown placeholder " ++ pattern[open .. close + 1] ++ " in " ++ pattern);
            out = out ++ .{d};
            i = close + 1;
        }
        return out;
    }
}

/// `pattern` with its placeholders filled in.
fn expand(buf: []u8, comptime pattern: []const u8, vars: Vars) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] != '{') {
            w.writeByte(pattern[i]) catch Assets.tooLong();
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, pattern, i, '}').?;
        const d = std.meta.stringToEnum(Dim, pattern[i + 1 .. close]).?;
        const v = vars[@intFromEnum(d)];
        (switch (d) {
            .team => w.writeAll(@as(Team, @enumFromInt(v)).name()),
            .planet => w.writeAll(@tagName(@as(Planet, @enumFromInt(v)))),
            .angle => w.print("{d:0>3}", .{angle(v)}),
            .frame => w.print("{d:0>2}", .{v}),
            .n => w.print("{d}", .{v}),
        }) catch Assets.tooLong();
        i = close + 1;
    }
    return w.buffered();
}

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

    pub fn tooLong() noreturn {
        // Only an absurdly long assets folder gets here.
        std.debug.panic("asset path too long", .{});
    }

    /// An image (`fmt` relative to the assets folder); the placeholder if
    /// it can't be read.
    pub fn image(a: *Assets, comptime fmt: []const u8, args: anytype) Error!Image {
        var buf: [512]u8 = undefined;
        return a.imageAt(a.path(&buf, fmt, args));
    }

    /// An image that may not exist.
    pub fn find(a: *Assets, comptime fmt: []const u8, args: anytype) Error!?Image {
        var buf: [512]u8 = undefined;
        return a.findAt(a.path(&buf, fmt, args));
    }

    /// `image` for a path made at run time (relative to the assets folder).
    pub fn imageNamed(a: *Assets, name: []const u8) Error!Image {
        var buf: [512]u8 = undefined;
        return a.imageAt(a.path(&buf, "{s}", .{name}));
    }

    /// `find` for a path made at run time (relative to the assets folder).
    pub fn findNamed(a: *Assets, name: []const u8) Error!?Image {
        var buf: [512]u8 = undefined;
        return a.findAt(a.path(&buf, "{s}", .{name}));
    }

    fn imageAt(a: *Assets, full: [:0]const u8) Error!Image {
        return try a.findAt(full) orelse {
            std.log.warn("missing art: {s}", .{full});
            a.missing += 1;
            return a.placeholder;
        };
    }

    fn findAt(a: *Assets, full: [:0]const u8) Error!?Image {
        return Image.load(a.allocator(), full) catch |err| switch (err) {
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

    /// The fields of `dst` named in `paths`: each a pattern, or a pattern
    /// and what neutral gets (see above).
    pub fn fill(a: *Assets, dst: anytype, comptime paths: anytype) Error!void {
        inline for (@typeInfo(@TypeOf(paths)).@"struct".fields) |f| {
            const entry = @field(paths, f.name);
            const pattern, const neutral: Neutral = if (@typeInfo(@TypeOf(entry)) == .pointer) .{ entry, .nothing } else entry;
            @field(dst, f.name) = try a.load(@TypeOf(@field(dst, f.name)), pattern, neutral);
        }
    }

    /// Images for the array type `T` from `pattern`.
    pub fn load(a: *Assets, comptime T: type, comptime pattern: []const u8, comptime neutral: Neutral) Error!T {
        return a.walk(T, pattern, comptime dimsOf(pattern), neutral, @splat(0), false);
    }

    /// `load` with some placeholders given (e.g. `.{ .planet = p }`):
    /// those are not dimensions.
    pub fn loadAt(a: *Assets, comptime T: type, comptime pattern: []const u8, comptime neutral: Neutral, given: anytype) Error!T {
        const fields = @typeInfo(@TypeOf(given)).@"struct".fields;
        const dims = comptime blk: {
            var out: []const Dim = &.{};
            for (dimsOf(pattern)) |d| {
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, @tagName(d))) break;
                } else out = out ++ .{d};
            }
            break :blk out;
        };
        var vars: Vars = @splat(0);
        inline for (fields) |f| {
            const v = @field(given, f.name);
            vars[@intFromEnum(@field(Dim, f.name))] = if (@typeInfo(@TypeOf(v)) == .@"enum") @intFromEnum(v) else v;
        }
        return a.walk(T, pattern, dims, neutral, vars, false);
    }

    fn walk(a: *Assets, comptime T: type, comptime pattern: []const u8, comptime dims: []const Dim, comptime neutral: Neutral, vars: Vars, optional: bool) Error!T {
        if (T == Image) {
            if (dims.len != 0) @compileError("more placeholders than dimensions in " ++ pattern);
            var buf: [256]u8 = undefined;
            const name = expand(&buf, pattern, vars);
            return if (optional) try a.findNamed(name) orelse a.nothing else a.imageNamed(name);
        }
        const info = @typeInfo(T).array;
        if (dims.len == 0) @compileError("fewer placeholders than dimensions in " ++ pattern);
        const d = dims[0];
        // Art for fewer directions (the first ones) is allowed.
        const ok = switch (d) {
            .team => info.len == teams,
            .planet => info.len == planets,
            .angle => info.len <= dirs,
            .frame, .n => true,
        };
        if (!ok) @compileError(std.fmt.comptimePrint("{{{t}}} doesn't number {d} images in {s}", .{ d, info.len, pattern }));
        var out: T = undefined;
        if (d == .team) {
            const red = try a.walk(info.child, pattern, dims[1..], neutral, with(vars, .team, @intFromEnum(Team.red)), optional);
            for (&out, 0..) |*o, t| {
                const team: Team = @enumFromInt(t);
                o.* = switch (team) {
                    .red => red,
                    .none => switch (neutral) {
                        .nothing => splat(info.child, a.nothing),
                        .file => try a.walk(info.child, pattern, dims[1..], neutral, with(vars, .team, t), true),
                        .red => red,
                    },
                    else => try a.recolorAll(info.child, team, red),
                };
            }
        } else {
            for (&out, 0..) |*o, i| o.* = try a.walk(info.child, pattern, dims[1..], neutral, with(vars, d, i), optional);
        }
        return out;
    }

    fn with(vars: Vars, d: Dim, v: usize) Vars {
        var out = vars;
        out[@intFromEnum(d)] = v;
        return out;
    }

    fn splat(comptime T: type, img: Image) T {
        return if (T == Image) img else @splat(splat(@typeInfo(T).array.child, img));
    }

    fn recolorAll(a: *Assets, comptime T: type, team: Team, red: T) Error!T {
        if (T == Image) return a.recolor(team, red);
        var out: T = undefined;
        for (&out, red) |*o, r| o.* = try a.recolorAll(@typeInfo(T).array.child, team, r);
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
    const flags = try a.load([Team.count]Image, "other/flag_{team}_0.png", .file);
    try std.testing.expect(flags[@intFromEnum(Team.blue)].pixels != flags[@intFromEnum(Team.red)].pixels);
    try std.testing.expect(flags[@intFromEnum(Team.none)].pixels != a.nothing.pixels);
}
