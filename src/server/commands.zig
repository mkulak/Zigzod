//! Chat commands (`/help`, `/changemap 3`, ...), from zserver_commands.cpp.

const std = @import("std");
const k = @import("../game/constants.zig");
const protocol = @import("../net/protocol.zig");
const srv = @import("server.zig");

const Server = srv.Server;
const Player = srv.Player;
const Error = srv.Error;

const Command = struct {
    name: []const u8,
    usage: []const u8,
    purpose: []const u8,
    run: *const fn (s: *Server, p: *Player, args: []const u8) Error!void,
};

const list = [_]Command{
    .{ .name = "help", .usage = "/help command", .purpose = "explain how to use a command and what it is used for", .run = help },
    .{ .name = "listcommands", .usage = "/listcommands", .purpose = "list all of the available commands", .run = listCommands },
    .{ .name = "login", .usage = "/login username, password", .purpose = "log into your username", .run = noAccounts },
    .{ .name = "logout", .usage = "/logout", .purpose = "log out of your username", .run = noAccounts },
    .{ .name = "createuser", .usage = "/createuser username, loginname, password, email", .purpose = "create a new user", .run = noAccounts },
    .{ .name = "pause", .usage = "/pause", .purpose = "pauses the game", .run = pause },
    .{ .name = "resume", .usage = "/resume", .purpose = "resumes the game", .run = unpause },
    .{ .name = "listmaps", .usage = "/listmaps", .purpose = "lists available maps to be used with /changemap", .run = listMaps },
    .{ .name = "changemap", .usage = "/changemap map_number", .purpose = "reset game to desired map, use /listmaps to get the map_number", .run = changeMap },
    .{ .name = "startbot", .usage = "/startbot team_color", .purpose = "start a bot", .run = startBot },
    .{ .name = "stopbot", .usage = "/stopbot team_color", .purpose = "stop a bot", .run = stopBot },
    .{ .name = "playerinfo", .usage = "/playerinfo", .purpose = "gives details on your logged in user", .run = playerInfo },
    .{ .name = "currentmap", .usage = "/currentmap", .purpose = "gives the name of the current map", .run = currentMap },
    .{ .name = "resetgame", .usage = "/resetgame", .purpose = "resets the current game", .run = resetGame },
    .{ .name = "changeteam", .usage = "/changeteam team_color", .purpose = "change your team", .run = changeTeam },
    .{ .name = "reshuffleteams", .usage = "/reshuffleteams", .purpose = "randomly places players on new teams and preserves balance", .run = reshuffleTeams },
    .{ .name = "buyregistration", .usage = "/buyregistration", .purpose = "downloads an offline registration key from the server for a cost in voting power", .run = buyRegistration },
    .{ .name = "changespeed", .usage = "/changespeed multiplier_number", .purpose = "changes the game speed. half speed is 50, double speed is 200", .run = changeSpeed },
    .{ .name = "version", .usage = "/version", .purpose = "returns the version of the server", .run = version },
};

/// Run `line` (the chat text after the '/').
pub fn run(s: *Server, p: *Player, line: []const u8) Error!void {
    const space = std.mem.indexOfScalar(u8, line, ' ');
    const name = line[0 .. space orelse line.len];
    const args = if (space) |i| line[i + 1 ..] else "";
    for (list) |c| if (std.mem.eql(u8, c.name, name)) return c.run(s, p, args);
    try tell(s, p, "command not found, please type /help or /listcommands");
}

fn tell(s: *Server, p: *const Player, text: []const u8) Error!void {
    try s.news(.{ .player = @intCast(p.id) }, text);
}

fn tellFmt(s: *Server, p: *const Player, comptime fmt: []const u8, args: anytype) Error!void {
    try s.newsFmt(.{ .player = @intCast(p.id) }, fmt, args);
}

/// The first comma-separated argument, without leading spaces.
fn firstArg(args: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, args, ',') orelse args.len;
    return std.mem.trimStart(u8, args[0..end], " ");
}

fn help(s: *Server, p: *Player, args: []const u8) Error!void {
    const topic = if (args.len == 0) "help" else args;
    for (list) |c| if (std.mem.eql(u8, c.name, topic)) {
        try tellFmt(s, p, "{s} usage: {s}", .{ c.name, c.usage });
        try tellFmt(s, p, "{s} purpose: {s}", .{ c.name, c.purpose });
        if (std.mem.eql(u8, topic, "help")) try listCommands(s, p, "");
        return;
    };
}

fn listCommands(s: *Server, p: *Player, _: []const u8) Error!void {
    try tell(s, p, "command list: help, listcommands, login, logout, createuser, pause, resume, listmaps, changemap, startbot, stopbot");
    try tell(s, p, "command list: playerinfo, currentmap, resetgame, changeteam, reshuffleteams, buyregistration, changespeed, version");
}

fn noAccounts(s: *Server, p: *Player, _: []const u8) Error!void {
    try tell(s, p, "login error: no database used");
}

fn pause(s: *Server, p: *Player, _: []const u8) Error!void {
    if (!s.world.clock.paused) _ = try s.startVote(.pause, -1, p);
}

fn unpause(s: *Server, p: *Player, _: []const u8) Error!void {
    if (s.world.clock.paused) _ = try s.startVote(.@"resume", -1, p);
}

fn listMaps(s: *Server, p: *Player, _: []const u8) Error!void {
    var i: usize = 0;
    const maps = s.selectable_maps.items;
    while (i < maps.len) {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll("map list: ") catch {};
        const end = @min(i + 4, maps.len);
        while (i < end) : (i += 1) {
            if (i % 4 != 0) w.writeAll(", ") catch {};
            w.print("{d}. {s}", .{ i, maps[i] }) catch {};
        }
        try tell(s, p, w.buffered());
    }
}

fn changeMap(s: *Server, p: *Player, args: []const u8) Error!void {
    const arg = firstArg(args);
    if (arg.len == 0) return tell(s, p, "command error: invalid input(s)");
    _ = try s.startVote(.change_map, std.fmt.parseInt(i32, arg, 10) catch 0, p);
}

fn teamArg(args: []const u8) ?k.Team {
    return k.Team.fromName(firstArg(args));
}

fn startBot(s: *Server, p: *Player, args: []const u8) Error!void {
    if (firstArg(args).len == 0) return tell(s, p, "command error: invalid input(s)");
    const team = teamArg(args) orelse .none;
    if (team == .none) return tell(s, p, "start bot error: invalid team, available teams: red, blue, green, yellow, purple, teal, white, black");
    _ = try s.startVote(.start_bot, @intFromEnum(team), p);
}

fn stopBot(s: *Server, p: *Player, args: []const u8) Error!void {
    if (firstArg(args).len == 0) return tell(s, p, "command error: invalid input(s)");
    if (teamArg(args)) |team| if (s.teamHasBot(team, false)) {
        _ = try s.startVote(.stop_bot, @intFromEnum(team), p);
        return;
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("stop bot error: invalid team, available teams: ") catch {};
    var first = true;
    for (0..k.Team.count) |i| {
        const team: k.Team = @enumFromInt(i);
        if (!s.teamHasBot(team, false)) continue;
        if (!first) w.writeAll(", ") catch {};
        w.writeAll(team.name()) catch {};
        first = false;
    }
    try tell(s, p, w.buffered());
}

fn playerInfo(s: *Server, p: *Player, _: []const u8) Error!void {
    try tellFmt(s, p, "player info: name: '{s}'", .{p.name.items});
    try tellFmt(s, p, "player info: team: {s}", .{p.team.name()});
    try tell(s, p, "player info: logged in: no");
}

fn currentMap(s: *Server, p: *Player, _: []const u8) Error!void {
    try tellFmt(s, p, "current map: {s}", .{s.map_name.items});
}

fn resetGame(s: *Server, p: *Player, _: []const u8) Error!void {
    _ = try s.startVote(.reset_game, -1, p);
}

fn changeTeam(s: *Server, p: *Player, args: []const u8) Error!void {
    if (firstArg(args).len == 0) return tell(s, p, "command error: invalid input(s)");
    const team = teamArg(args) orelse
        return tell(s, p, "change team error: invalid team, example command usage: /changeteam red ... or /changeteam blue");
    if (team == p.team) return tell(s, p, "change team error: you are already on that team");
    const previous = p.team;
    try s.changePlayerTeam(p, team);
    try s.newsFmt(.all, "{s} has changed from the {s} team to the {s} team", .{ p.name.items, previous.name(), team.name() });
}

fn reshuffleTeams(s: *Server, p: *Player, _: []const u8) Error!void {
    _ = try s.startVote(.reshuffle_teams, -1, p);
}

fn buyRegistration(s: *Server, p: *Player, _: []const u8) Error!void {
    try s.send(.{ .player = @intCast(p.id) }, .poll_buy_regkey, &.{});
}

fn changeSpeed(s: *Server, p: *Player, args: []const u8) Error!void {
    const arg = firstArg(args);
    if (arg.len == 0) return tell(s, p, "command error: invalid input(s)");
    _ = try s.startVote(.change_game_speed, std.fmt.parseInt(i32, arg, 10) catch 0, p);
}

fn version(s: *Server, p: *Player, _: []const u8) Error!void {
    try s.relayVersion(.{ .player = @intCast(p.id) });
}

test "argument parsing" {
    try std.testing.expectEqualStrings("red", firstArg("  red, blue"));
    try std.testing.expectEqual(k.Team.blue, teamArg("blue").?);
    try std.testing.expect(teamArg("mauve") == null);
    _ = protocol;
}
