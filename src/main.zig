//! `zod`: the Zig Zod engine: `zod server` runs the game server, `zod
//! client` (work in progress) the game client. The playable client, the
//! bot and the map editor are still the C++ programs.

const std = @import("std");
const build_options = @import("build_options");
const game = @import("game.zig");
const Server = @import("server/server.zig").Server;
const Options = @import("server/server.zig").Options;
const App = @import("client/app.zig").App;

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\usage: zod server [options]
    \\       zod client [-c host] [-n name] [-t team] [-r WxH] [-f]
    \\
    \\Runs a dedicated game server that the Zod client (zod_engine -c host)
    \\and bots connect to.
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
    \\  --bot program  program started for bots (default: zod_engine next to zod)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "client")) return runClient(init, args[2..]);
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
        } else if (std.mem.eql(u8, arg, "--bot")) {
            options.bot_program = value;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }
    if (options.map != null and options.map_list != null) fail("use either -m or -l", .{});
    if (options.map == null and options.map_list == null) options.map_list = "map_list.txt";
    if (options.bot_program == null) {
        const dir = try std.process.executableDirPathAlloc(io, arena);
        options.bot_program = try std.fs.path.join(arena, &.{ dir, "zod_engine" });
    }

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

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zod: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}
