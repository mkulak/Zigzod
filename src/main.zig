//! `zod`, the Zod engine: `zod play` plays a game on this computer, `zod
//! server` runs a game server, `zod client` joins one, `zod bot` adds a
//! computer player to one and `zod edit` is the map editor.

const std = @import("std");
const build_options = @import("build_options");
const game = @import("game.zig");
const net = @import("net.zig");
const server_mod = @import("server/server.zig");
const app_mod = @import("client/app.zig");
const Bot = @import("bot.zig").Bot;
const editor = @import("editor.zig");

const Team = game.constants.Team;

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\usage: zod play [server options] [client options]
    \\       zod server [server options]
    \\       zod client [-c host] [client options]
    \\       zod bot [-c host] [-p port] -t team
    \\       zod edit file.map [-n WxH] [-P planet] [-N name]
    \\
    \\`zod play` runs a server here and joins it (by default the campaign
    \\maps as red against a blue bot: -l map_list.txt -b blue -t red).
    \\
    \\Server options:
    \\  -m file        map to play
    \\  -l file        map list to play (first line: 1 for random order)
    \\                 (default: map_list.txt)
    \\  -z file        unit settings (default: default_settings.txt)
    \\  -e file        server settings
    \\  -b team        a computer player for a team (may be repeated)
    \\  -p port        port (default: 8000)
    \\
    \\Client options:
    \\  -t team        team to play (default: red)
    \\  -n name        player name
    \\  -r WxH         window size (default: 800x600)
    \\  -f             full screen
    \\
    \\Map editor: -n WxH makes a new map of that many tiles, on planet -P
    \\(desert, volcanic, arctic, jungle, city), named -N. Keys: M mode,
    \\O / wheel object, T team, L level, , . bridge length, ; ' health,
    \\S save, Ctrl+Z undo, Ctrl+Shift+Z redo, R ruler, P save a picture,
    \\arrows scroll; Ctrl+click picks several tiles to paint with.
    \\
    \\All: -D dir is the game data folder that file names are relative to
    \\(default: the repository's bin/).
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = if (args.len >= 2) args[1] else "";
    const rest: []const [:0]const u8 = if (args.len >= 2) args[2..] else &.{};
    if (std.mem.eql(u8, command, "play")) return play(init, rest);
    if (std.mem.eql(u8, command, "server")) return runServer(init, rest);
    if (std.mem.eql(u8, command, "client")) return runClient(init, rest);
    if (std.mem.eql(u8, command, "bot")) return runBot(init, rest);
    if (std.mem.eql(u8, command, "edit")) return runEditor(init, rest);
    std.debug.print("{s}", .{usage});
    const help = std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help");
    std.process.exit(if (help) 0 else 2);
}

/// Command line options, each with a value except flags.
const Args = struct {
    list: []const [:0]const u8,
    i: usize = 0,

    fn next(a: *Args) ?[:0]const u8 {
        if (a.i >= a.list.len) return null;
        defer a.i += 1;
        const arg = a.list[a.i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        }
        return arg;
    }

    fn value(a: *Args, arg: []const u8) [:0]const u8 {
        if (a.i >= a.list.len) fail("missing value for {s}", .{arg});
        defer a.i += 1;
        return a.list[a.i];
    }
};

const Common = struct {
    data_path: []const u8 = build_options.data_dir,
};

fn parseTeam(s: []const u8) Team {
    return Team.fromName(s) orelse fail("unknown team '{s}'", .{s});
}

fn parsePort(s: []const u8) u16 {
    return std.fmt.parseInt(u16, s, 10) catch fail("bad port '{s}'", .{s});
}

fn parseSize(comptime T: type, s: []const u8) [2]T {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse fail("bad size '{s}'", .{s});
    return .{
        std.fmt.parseInt(T, s[0..x], 10) catch fail("bad size '{s}'", .{s}),
        std.fmt.parseInt(T, s[x + 1 ..], 10) catch fail("bad size '{s}'", .{s}),
    };
}

/// A server option; false if `arg` isn't one.
fn serverOption(o: *server_mod.Options, c: *Common, arg: []const u8, a: *Args) bool {
    if (std.mem.eql(u8, arg, "-m")) {
        o.map = a.value(arg);
    } else if (std.mem.eql(u8, arg, "-l")) {
        o.map_list = a.value(arg);
    } else if (std.mem.eql(u8, arg, "-z")) {
        o.settings = a.value(arg);
    } else if (std.mem.eql(u8, arg, "-e")) {
        o.server_settings = a.value(arg);
    } else if (std.mem.eql(u8, arg, "-b")) {
        const team = parseTeam(a.value(arg));
        if (team == .none) fail("bots need a team", .{});
        o.bots.insert(team);
    } else if (std.mem.eql(u8, arg, "-p")) {
        o.port = parsePort(a.value(arg));
    } else if (std.mem.eql(u8, arg, "-D")) {
        c.data_path = a.value(arg);
    } else return false;
    return true;
}

/// A client option; false if `arg` isn't one.
fn clientOption(o: *app_mod.Options, c: *Common, arg: []const u8, a: *Args) bool {
    if (std.mem.eql(u8, arg, "-f")) {
        o.fullscreen = true;
    } else if (std.mem.eql(u8, arg, "-c")) {
        o.host = a.value(arg);
    } else if (std.mem.eql(u8, arg, "-n")) {
        o.name = a.value(arg);
    } else if (std.mem.eql(u8, arg, "-t")) {
        o.team = parseTeam(a.value(arg));
    } else if (std.mem.eql(u8, arg, "-p")) {
        o.port = parsePort(a.value(arg));
    } else if (std.mem.eql(u8, arg, "-r")) {
        const s = parseSize(i32, a.value(arg));
        o.width = s[0];
        o.height = s[1];
    } else if (std.mem.eql(u8, arg, "-D")) {
        c.data_path = a.value(arg);
    } else return false;
    return true;
}

fn checkMaps(o: *server_mod.Options) void {
    if (o.map != null and o.map_list != null) fail("use either -m or -l", .{});
    if (o.map == null and o.map_list == null) o.map_list = "map_list.txt";
}

fn openData(io: std.Io, path: []const u8) std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| fail("can't open data folder '{s}': {t}", .{ path, err });
}

fn runServer(init: std.process.Init, args: []const [:0]const u8) !void {
    var o: server_mod.Options = .{};
    var c: Common = .{};
    var a: Args = .{ .list = args };
    while (a.next()) |arg| if (!serverOption(&o, &c, arg, &a)) fail("unknown option '{s}'", .{arg});
    checkMaps(&o);
    var data = openData(init.io, c.data_path);
    defer data.close(init.io);
    const server = try server_mod.Server.init(init.gpa, init.io, data, o);
    defer server.deinit();
    try server.run();
}

fn runClient(init: std.process.Init, args: []const [:0]const u8) !void {
    var o: app_mod.Options = .{};
    var c: Common = .{};
    var a: Args = .{ .list = args };
    while (a.next()) |arg| if (!clientOption(&o, &c, arg, &a)) fail("unknown option '{s}'", .{arg});
    const app = try app_mod.App.init(init.gpa, init.io, c.data_path, o);
    defer app.deinit();
    try app.run();
}

/// A server with its bots and a client in one loop.
fn play(init: std.process.Init, args: []const [:0]const u8) !void {
    var so: server_mod.Options = .{};
    var co: app_mod.Options = .{};
    var c: Common = .{};
    var a: Args = .{ .list = args };
    var bots_given = false;
    while (a.next()) |arg| {
        if (std.mem.eql(u8, arg, "-b")) bots_given = true;
        // -p and -D matter to both.
        if (std.mem.eql(u8, arg, "-p")) {
            so.port = parsePort(a.value(arg));
            co.port = so.port;
        } else if (!serverOption(&so, &c, arg, &a) and !clientOption(&co, &c, arg, &a)) fail("unknown option '{s}'", .{arg});
    }
    checkMaps(&so);
    if (!bots_given) so.bots.insert(if (co.team == .blue) .red else .blue);

    var data = openData(init.io, c.data_path);
    defer data.close(init.io);
    const server = try server_mod.Server.init(init.gpa, init.io, data, so);
    defer server.deinit();
    co.host = "127.0.0.1";
    const app = try app_mod.App.init(init.gpa, init.io, c.data_path, co);
    defer app.deinit();
    while (true) {
        try server.tick();
        server.bots.update(server.realTime());
        if (!try app.frame()) break;
        init.io.sleep(.fromMilliseconds(10), .awake) catch break;
    }
}

fn runBot(init: std.process.Init, args: []const [:0]const u8) !void {
    const io = init.io;
    var host: [:0]const u8 = "localhost";
    var port: u16 = net.conn.default_port;
    var team: Team = .none;
    var c: Common = .{};
    var a: Args = .{ .list = args };
    while (a.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c")) {
            host = a.value(arg);
        } else if (std.mem.eql(u8, arg, "-p")) {
            port = parsePort(a.value(arg));
        } else if (std.mem.eql(u8, arg, "-t")) {
            team = parseTeam(a.value(arg));
        } else if (std.mem.eql(u8, arg, "-D")) {
            c.data_path = a.value(arg);
        } else fail("unknown option '{s}'", .{arg});
    }
    if (team == .none) fail("a bot needs a team (-t)", .{});

    var data = openData(io, c.data_path);
    defer data.close(io);
    var assets = try data.openDir(io, "assets", .{});
    defer assets.close(io);
    const terrain = try game.map.Terrain.load(io, assets);

    const origin = std.Io.Clock.awake.now(io);
    const seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)));
    const bot = Bot.connect(init.gpa, host, port, &terrain, team, seed) catch |err| fail("could not connect to {s}:{d}: {t}", .{ host, port, err });
    defer bot.deinit();
    while (bot.connected()) {
        const d = origin.durationTo(std.Io.Clock.awake.now(io));
        try bot.update(@as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_s);
        io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
    std.log.info("disconnected from the server", .{});
}

fn runEditor(init: std.process.Init, args: []const [:0]const u8) !void {
    var o: editor.Options = .{ .path = "" };
    var c: Common = .{};
    var size: ?[2]u16 = null;
    var planet: game.constants.Planet = .desert;
    var name: []const u8 = "new map";
    var a: Args = .{ .list = args };
    while (a.next()) |arg| {
        if (arg.len == 0 or arg[0] != '-') {
            o.path = arg;
        } else if (std.mem.eql(u8, arg, "-n")) {
            size = parseSize(u16, a.value(arg));
        } else if (std.mem.eql(u8, arg, "-P")) {
            const v = a.value(arg);
            planet = std.meta.stringToEnum(game.constants.Planet, v) orelse fail("unknown planet '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "-N")) {
            name = a.value(arg);
        } else if (std.mem.eql(u8, arg, "-D")) {
            c.data_path = a.value(arg);
        } else fail("unknown option '{s}'", .{arg});
    }
    if (o.path.len == 0) fail("which map? (zod edit file.map)", .{});
    if (size) |s| {
        if (s[0] == 0 or s[1] == 0) fail("a map needs at least one tile", .{});
        o.new = .{ .width = s[0], .height = s[1], .planet = planet, .name = name };
    }
    const e = try editor.Editor.init(init.gpa, init.io, c.data_path, o);
    defer e.deinit();
    try e.run();
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zod: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

test {
    _ = @import("game.zig");
    _ = @import("net.zig");
    _ = @import("server.zig");
    _ = @import("client.zig");
    _ = @import("bot.zig");
    _ = @import("editor.zig");
}
