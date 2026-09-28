//! `zod`: the Zig Zod engine: `zod server` runs the game server, `zod
//! client` the game client, `zod bot` a computer player and `zod edit` the
//! map editor.

const std = @import("std");
const build_options = @import("build_options");
const game = @import("game.zig");
const Server = @import("server/server.zig").Server;
const Options = @import("server/server.zig").Options;
const App = @import("client/app.zig").App;
const Bot = @import("bot.zig").Bot;
const editor = @import("editor.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\usage: zod server [options]
    \\       zod client [-c host] [-p port] [-n name] [-t team] [-r WxH] [-f]
    \\       zod bot [-c host] [-p port] -t team
    \\       zod edit file.map [-n WxH] [-P planet] [-N name]
    \\
    \\`zod edit` edits a map; -n creates a new one of that many tiles.
    \\Keys: M mode, O / wheel object, T team, L level, , . bridge length,
    \\; ' health, S save, Ctrl+Z undo, Ctrl+Shift+Z redo, R ruler,
    \\P save a picture, arrows scroll. Ctrl+click picks several tiles.
    \\
    \\`zod server` runs a game server that clients and bots connect to.
    \\
    \\  -m file        map to play
    \\  -l file        map list to play (first line: 1 for random order)
    \\                 (default: map_list.txt)
    \\  -z file        unit settings (default: default_settings.txt)
    \\  -e file        server settings
    \\  -b team        start a bot for a team (may be repeated)
    \\  -p port        port to listen on (default: 8000)
    \\  -D dir         game data folder that file names are relative to
    \\                 (default: the repository's bin/)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "client")) return runClient(init, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "bot")) return runBot(init, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "edit")) return runEditor(init, args[2..]);
    if (args.len < 2 or !std.mem.eql(u8, args[1], "server")) {
        std.debug.print("{s}", .{usage});
        std.process.exit(if (args.len >= 2 and std.mem.eql(u8, args[1], "--help")) 0 else 2);
    }

    var options: Options = .{};
    var data_path: []const u8 = build_options.data_dir;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (i + 1 >= args.len) fail("missing value for {s}", .{arg});
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "-m")) {
            options.map = value;
        } else if (std.mem.eql(u8, arg, "-l")) {
            options.map_list = value;
        } else if (std.mem.eql(u8, arg, "-z")) {
            options.settings = value;
        } else if (std.mem.eql(u8, arg, "-e")) {
            options.server_settings = value;
        } else if (std.mem.eql(u8, arg, "-b")) {
            const team = game.constants.Team.fromName(value) orelse fail("unknown team '{s}'", .{value});
            if (team == .none) fail("bots need a team", .{});
            options.bots.insert(team);
        } else if (std.mem.eql(u8, arg, "-p")) {
            options.port = std.fmt.parseInt(u16, value, 10) catch fail("bad port '{s}'", .{value});
        } else if (std.mem.eql(u8, arg, "-D")) {
            data_path = value;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }
    if (options.map != null and options.map_list != null) fail("use either -m or -l", .{});
    if (options.map == null and options.map_list == null) options.map_list = "map_list.txt";

    var data = std.Io.Dir.cwd().openDir(io, data_path, .{}) catch |err| fail("can't open data folder '{s}': {t}", .{ data_path, err });
    defer data.close(io);

    const server = try Server.init(gpa, io, data, options);
    defer server.deinit();
    try server.run();
}

fn runClient(init: std.process.Init, args: []const [:0]const u8) !void {
    var options: @import("client/app.zig").Options = .{};
    var data_path: []const u8 = build_options.data_dir;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f")) {
            options.fullscreen = true;
            continue;
        }
        if (i + 1 >= args.len) fail("missing value for {s}", .{arg});
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "-c")) {
            options.host = value;
        } else if (std.mem.eql(u8, arg, "-n")) {
            options.name = value;
        } else if (std.mem.eql(u8, arg, "-t")) {
            options.team = game.constants.Team.fromName(value) orelse fail("unknown team '{s}'", .{value});
        } else if (std.mem.eql(u8, arg, "-p")) {
            options.port = std.fmt.parseInt(u16, value, 10) catch fail("bad port '{s}'", .{value});
        } else if (std.mem.eql(u8, arg, "-r")) {
            const x = std.mem.indexOfScalar(u8, value, 'x') orelse fail("bad resolution '{s}'", .{value});
            options.width = std.fmt.parseInt(i32, value[0..x], 10) catch fail("bad resolution '{s}'", .{value});
            options.height = std.fmt.parseInt(i32, value[x + 1 ..], 10) catch fail("bad resolution '{s}'", .{value});
        } else if (std.mem.eql(u8, arg, "-D")) {
            data_path = value;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }
    const app = try App.init(init.gpa, init.io, data_path, options);
    defer app.deinit();
    try app.run();
}

fn runEditor(init: std.process.Init, args: []const [:0]const u8) !void {
    var options: editor.Options = .{ .path = "" };
    var data_path: []const u8 = build_options.data_dir;
    var size: ?[2]u16 = null;
    var planet: game.constants.Planet = .desert;
    var name: []const u8 = "new map";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-') {
            options.path = arg;
            continue;
        }
        if (i + 1 >= args.len) fail("missing value for {s}", .{arg});
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "-n")) {
            const x = std.mem.indexOfScalar(u8, value, 'x') orelse fail("bad size '{s}'", .{value});
            size = .{
                std.fmt.parseInt(u16, value[0..x], 10) catch fail("bad size '{s}'", .{value}),
                std.fmt.parseInt(u16, value[x + 1 ..], 10) catch fail("bad size '{s}'", .{value}),
            };
        } else if (std.mem.eql(u8, arg, "-P")) {
            planet = std.meta.stringToEnum(game.constants.Planet, value) orelse fail("unknown planet '{s}'", .{value});
        } else if (std.mem.eql(u8, arg, "-N")) {
            name = value;
        } else if (std.mem.eql(u8, arg, "-D")) {
            data_path = value;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }
    if (options.path.len == 0) fail("which map? (zod edit file.map)", .{});
    if (size) |s| {
        if (s[0] == 0 or s[1] == 0) fail("a map needs at least one tile", .{});
        options.new = .{ .width = s[0], .height = s[1], .planet = planet, .name = name };
    }
    const e = try editor.Editor.init(init.gpa, init.io, data_path, options);
    defer e.deinit();
    try e.run();
}

fn runBot(init: std.process.Init, args: []const [:0]const u8) !void {
    const io = init.io;
    var host: [:0]const u8 = "localhost";
    var port: u16 = @import("net.zig").conn.default_port;
    var team: ?game.constants.Team = null;
    var data_path: []const u8 = build_options.data_dir;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) fail("missing value for {s}", .{args[i]});
        const arg = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "-c")) {
            host = value;
        } else if (std.mem.eql(u8, arg, "-p")) {
            port = std.fmt.parseInt(u16, value, 10) catch fail("bad port '{s}'", .{value});
        } else if (std.mem.eql(u8, arg, "-t")) {
            team = game.constants.Team.fromName(value) orelse fail("unknown team '{s}'", .{value});
        } else if (std.mem.eql(u8, arg, "-D")) {
            data_path = value;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }
    const t = team orelse fail("a bot needs a team (-t)", .{});
    if (t == .none) fail("a bot needs a team (-t)", .{});

    var assets = std.Io.Dir.cwd().openDir(io, data_path, .{}) catch |err| fail("can't open data folder '{s}': {t}", .{ data_path, err });
    defer assets.close(io);
    var dir = try assets.openDir(io, "assets", .{});
    defer dir.close(io);
    const terrain = try game.map.Terrain.load(io, dir);

    const origin = std.Io.Clock.awake.now(io);
    const bot = Bot.connect(init.gpa, host, port, &terrain, t, @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)))) catch |err| fail("could not connect to {s}:{d}: {t}", .{ host, port, err });
    defer bot.deinit();
    while (bot.connected()) {
        const d = origin.durationTo(std.Io.Clock.awake.now(io));
        try bot.update(@as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_s);
        io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
    std.log.info("disconnected from the server", .{});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zod: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}
