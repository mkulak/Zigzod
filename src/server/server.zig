//! The game server: accepts players, answers their requests, runs the
//! simulation and sends every change to the clients (from ZServer in
//! QZod_DnClientServer). Speaks the original protocol, so C++ clients and
//! bots can play on it.
//!
//! Differences from the original:
//! * players have stable ids; the original addressed them by their index
//!   in a list that shifted when someone disconnected;
//! * there are no user accounts or database, so every player has one vote
//!   (without a database the original let anyone decide every vote alone);
//! * bots are Zig bots run by the server itself (see `bots.zig`).

const std = @import("std");
const fit = @import("../text.zig").fit;
const game = @import("../game.zig");
const net = @import("../net.zig");
const commands = @import("commands.zig");
const Bots = @import("bots.zig").Bots;

const k = game.constants;
const protocol = net.protocol;
const World = game.world.World;
const Object = game.object.Object;
const Waypoint = game.object.Waypoint;
const Audience = game.world.Audience;
const Settings = game.settings.Settings;
const Conn = net.conn.Conn;

pub const Error = std.mem.Allocator.Error;

pub const max_player_name = 30;
/// Seconds a vote stays open.
pub const vote_time = 30;
/// Real seconds between the end of a game and the next map.
const reset_delay = 10;

pub const VoteType = enum(i32) {
    pause,
    @"resume",
    change_map,
    start_bot,
    stop_bot,
    reset_game,
    reshuffle_teams,
    change_game_speed,
    _,

    pub fn description(v: VoteType) []const u8 {
        return switch (v) {
            .pause => "Pause Game",
            .@"resume" => "Resume Game",
            .change_map => "Change Map",
            .start_bot => "Start Bot",
            .stop_bot => "Stop Bot",
            .reset_game => "Reset Game",
            .reshuffle_teams => "Reshuffle Teams",
            .change_game_speed => "Set Game Speed",
            _ => "?",
        };
    }
};

pub const Vote = struct {
    kind: VoteType,
    value: i32,
    /// Real time when it expires.
    end_time: f64,
};

/// Server options (the `-e` file, ZPSettings).
pub const ServerSettings = struct {
    start_map_paused: bool = true,
    bots_start_ignored: bool = false,
    allow_game_speed_change: bool = true,
    /// File listing the maps players may vote for (one per line).
    selectable_map_list: []const u8 = "",

    /// Parse `name=value` lines; unknown names (like the old database
    /// options) are ignored. Strings point into `text`.
    pub fn parse(s: *ServerSettings, text: []const u8) void {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = line[0..eq];
            const value = line[eq + 1 ..];
            const flag = (std.fmt.parseInt(i32, std.mem.trim(u8, value, " "), 10) catch 0) != 0;
            if (std.mem.eql(u8, name, "start_map_paused")) s.start_map_paused = flag;
            if (std.mem.eql(u8, name, "bots_start_ignored")) s.bots_start_ignored = flag;
            if (std.mem.eql(u8, name, "allow_game_speed_change")) s.allow_game_speed_change = flag;
            if (std.mem.eql(u8, name, "selectable_map_list")) s.selectable_map_list = value;
        }
    }

    pub fn write(s: ServerSettings, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("start_map_paused={d}\n", .{@intFromBool(s.start_map_paused)});
        try w.print("bots_start_ignored={d}\n", .{@intFromBool(s.bots_start_ignored)});
        try w.print("allow_game_speed_change={d}\n", .{@intFromBool(s.allow_game_speed_change)});
        try w.print("selectable_map_list={s}\n", .{s.selectable_map_list});
    }
};

pub const Player = struct {
    id: i32,
    conn: Conn,
    name: std.ArrayList(u8) = .empty,
    team: k.Team = .none,
    mode: k.PlayerMode = .nobody,
    vote: k.VoteChoice = .none,
    ignored: bool = false,
    /// Identified as a bot (SEND_BOT_BYPASS_DATA).
    bot: bool = false,

    fn deinit(p: *Player, gpa: std.mem.Allocator) void {
        p.name.deinit(gpa);
        p.conn.deinit(gpa);
    }

    fn setName(p: *Player, gpa: std.mem.Allocator, name: []const u8) Error!void {
        p.name.clearRetainingCapacity();
        try p.name.appendSlice(gpa, name[0..@min(name.len, max_player_name)]);
    }
};

pub const Options = struct {
    port: u16 = net.conn.default_port,
    /// Map to play (otherwise the map list is used).
    map: ?[]const u8 = null,
    /// File with `random` (0/1) on the first line, then map file names.
    map_list: ?[]const u8 = null,
    /// Unit settings file (default: default_settings.txt, created if missing).
    settings: ?[]const u8 = null,
    /// Server settings file (created if missing).
    server_settings: ?[]const u8 = null,
    /// Teams that get a bot from the start.
    bots: std.EnumSet(k.Team) = .initEmpty(),
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Directory the game data and all file names are relative to.
    data: std.Io.Dir,
    terrain: *game.map.Terrain,
    world: World,
    listener: net.conn.Listener,
    players: std.ArrayList(*Player) = .empty,
    next_player_id: i32 = 0,

    server_settings: ServerSettings = .{},
    server_settings_text: []u8 = &.{},
    map_list: std.ArrayList([]u8) = .empty,
    selectable_maps: std.ArrayList([]u8) = .empty,
    random_maps: bool = false,
    map_index: ?usize = null,
    map_name: std.ArrayList(u8) = .empty,

    vote: ?Vote = null,
    game_on: bool = false,
    next_end_check: f64 = 0,
    reset_time: ?f64 = null,
    next_suggestion_time: f64 = 0,
    clock_origin: std.Io.Timestamp,

    bots: Bots,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data: std.Io.Dir, options: Options) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);

        const terrain = try gpa.create(game.map.Terrain);
        errdefer gpa.destroy(terrain);
        {
            var assets = try data.openDir(io, "assets", .{});
            defer assets.close(io);
            terrain.* = try game.map.Terrain.load(io, assets);
        }

        var listener = try net.conn.Listener.listen(options.port);
        errdefer listener.deinit();

        s.* = .{
            .gpa = gpa,
            .io = io,
            .data = data,
            .terrain = terrain,
            .world = World.init(gpa, terrain, @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)))),
            .listener = listener,
            .clock_origin = std.Io.Clock.awake.now(io),
            .bots = .{ .gpa = gpa, .port = options.port, .terrain = terrain, .seed = @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds))) },
        };
        errdefer s.deinit();

        try s.loadSettings(options);
        try s.loadMapLists(options);
        try s.loadNextMap(options.map);

        var it = options.bots.iterator();
        while (it.next()) |team| s.bots.start(team);

        std.log.info("server listening on port {d}", .{options.port});
        return s;
    }

    pub fn deinit(s: *Server) void {
        const gpa = s.gpa;
        s.bots.deinit();
        for (s.players.items) |p| {
            p.deinit(gpa);
            gpa.destroy(p);
        }
        s.players.deinit(gpa);
        s.world.deinit();
        gpa.destroy(s.terrain);
        s.listener.deinit();
        for (s.map_list.items) |m| gpa.free(m);
        s.map_list.deinit(gpa);
        for (s.selectable_maps.items) |m| gpa.free(m);
        s.selectable_maps.deinit(gpa);
        s.map_name.deinit(gpa);
        gpa.free(s.server_settings_text);
        gpa.destroy(s);
    }

    /// Seconds since the server started.
    pub fn realTime(s: *const Server) f64 {
        const d = s.clock_origin.durationTo(std.Io.Clock.awake.now(s.io));
        return @as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_s;
    }

    /// Run until the process is stopped.
    pub fn run(s: *Server) !void {
        while (true) {
            try s.tick();
            s.bots.update(s.realTime());
            s.io.sleep(.fromMilliseconds(10), .awake) catch return;
        }
    }

    /// One round: network, simulation, messages out.
    pub fn tick(s: *Server) Error!void {
        const now = s.realTime();
        s.world.clock.updateAt(now);

        try s.acceptPlayers();
        try s.receive();
        try s.checkSuggestions(now);
        try s.checkVoteExpired(now);
        try game.sim.step(&s.world);
        try s.checkEndGame(now);
        try s.flushOutbox();
    }

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    fn readFile(s: *Server, path: []const u8) ?[]u8 {
        return s.data.readFileAlloc(s.io, path, s.gpa, .limited(16 << 20)) catch |err| {
            std.log.warn("could not read '{s}': {t}", .{ path, err });
            return null;
        };
    }

    fn writeFile(s: *Server, path: []const u8, data: []const u8) void {
        s.data.writeFile(s.io, .{ .sub_path = path, .data = data }) catch |err|
            std.log.warn("could not write '{s}': {t}", .{ path, err });
    }

    fn loadSettings(s: *Server, options: Options) !void {
        const path = options.settings orelse "default_settings.txt";
        if (s.data.readFileAlloc(s.io, path, s.gpa, .limited(1 << 20))) |text| {
            defer s.gpa.free(text);
            _ = s.world.settings.parse(text);
        } else |_| if (options.settings == null) {
            // Write out the defaults for people to edit.
            var buf: std.Io.Writer.Allocating = .init(s.gpa);
            defer buf.deinit();
            try Settings.defaults.write(&buf.writer);
            s.writeFile(path, buf.written());
        } else {
            std.log.warn("could not read settings '{s}', using defaults", .{path});
        }

        if (options.server_settings) |p| {
            if (s.data.readFileAlloc(s.io, p, s.gpa, .limited(1 << 20))) |text| {
                s.server_settings_text = text;
                s.server_settings.parse(text);
            } else |_| {
                var buf: std.Io.Writer.Allocating = .init(s.gpa);
                defer buf.deinit();
                try s.server_settings.write(&buf.writer);
                s.writeFile(p, buf.written());
            }
        }
    }

    fn readLines(s: *Server, text: []const u8, list: *std.ArrayList([]u8)) Error!void {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const name = std.mem.trim(u8, line, " \t");
            if (name.len == 0) continue;
            try list.append(s.gpa, try s.gpa.dupe(u8, name));
        }
    }

    fn loadMapLists(s: *Server, options: Options) !void {
        if (options.map_list) |path| if (s.readFile(path)) |text| {
            defer s.gpa.free(text);
            const first_end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
            s.random_maps = (std.fmt.parseInt(i32, std.mem.trim(u8, text[0..first_end], " "), 10) catch 0) != 0;
            try s.readLines(text[first_end..], &s.map_list);
        };

        // Maps players may vote for: the list file, else the *.map files in
        // the data folder, else the map list.
        if (s.server_settings.selectable_map_list.len > 0) {
            if (s.readFile(s.server_settings.selectable_map_list)) |text| {
                defer s.gpa.free(text);
                try s.readLines(text, &s.selectable_maps);
            }
        }
        if (s.selectable_maps.items.len == 0) try s.findMaps();
        if (s.selectable_maps.items.len == 0) {
            for (s.map_list.items) |m| try s.selectable_maps.append(s.gpa, try s.gpa.dupe(u8, m));
        }

        if (options.map == null and s.map_list.items.len == 0) {
            s.random_maps = false;
            for (s.selectable_maps.items) |m| try s.map_list.append(s.gpa, try s.gpa.dupe(u8, m));
        }
    }

    fn findMaps(s: *Server) !void {
        var dir = s.data.openDir(s.io, ".", .{ .iterate = true }) catch |err| {
            std.log.warn("could not look for maps: {t}", .{err});
            return;
        };
        defer dir.close(s.io);
        var it = dir.iterate();
        while (it.next(s.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".map")) continue;
            try s.selectable_maps.append(s.gpa, try s.gpa.dupe(u8, entry.name));
        }
        std.mem.sort([]u8, s.selectable_maps.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }

    /// Load `name`, or the next map from the list.
    fn loadNextMap(s: *Server, name: ?[]const u8) Error!void {
        if (name) |n| {
            s.map_name.clearRetainingCapacity();
            try s.map_name.appendSlice(s.gpa, n);
        } else if (s.map_list.items.len > 0) {
            const count = s.map_list.items.len;
            const i = if (s.random_maps)
                s.world.random().uintLessThan(usize, count)
            else if (s.map_index) |i| (i + 1) % count else 0;
            s.map_index = i;
            s.map_name.clearRetainingCapacity();
            try s.map_name.appendSlice(s.gpa, s.map_list.items[i]);
        }

        s.world.clear();
        s.vote = null;
        if (s.map_name.items.len == 0) {
            std.log.warn("no map to load", .{});
        } else if (s.readFile(s.map_name.items)) |bytes| {
            defer s.gpa.free(bytes);
            s.world.loadMap(bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.log.warn("bad map '{s}': {t}", .{ s.map_name.items, err }),
            };
            std.log.info("loaded map '{s}'", .{s.map_name.items});
        }

        if (s.server_settings.start_map_paused) try s.pause();
        s.game_on = true;
        s.reset_time = null;
    }

    // -----------------------------------------------------------------------
    // Players and the network
    // -----------------------------------------------------------------------

    pub fn findPlayer(s: *Server, id: i32) ?*Player {
        for (s.players.items) |p| if (p.id == id) return p;
        return null;
    }

    fn acceptPlayers(s: *Server) Error!void {
        while (s.listener.accept()) |conn| {
            try s.news(.all, "a player connected");
            const p = try s.gpa.create(Player);
            p.* = .{ .id = s.next_player_id, .conn = conn };
            s.next_player_id += 1;
            try s.players.append(s.gpa, p);
            try s.sendPacket(.all, .add_lplayer, protocol.AddRemovePlayer{ .p_id = p.id });
            std.log.info("player {d} connected from {s}", .{ p.id, p.conn.addressSlice() });
        }
    }

    fn receive(s: *Server) Error!void {
        var i: usize = 0;
        while (i < s.players.items.len) {
            const p = s.players.items[i];
            try p.conn.receive(s.gpa);
            while (p.conn.next()) |frame| try s.handle(p, frame);
            if (!p.conn.open) {
                _ = s.players.orderedRemove(i);
                try s.disconnected(p);
                continue;
            }
            i += 1;
        }
    }

    fn disconnected(s: *Server, p: *Player) Error!void {
        std.log.info("player {d} disconnected", .{p.id});
        const id = p.id;
        p.deinit(s.gpa);
        s.gpa.destroy(p);
        try s.news(.all, "a player disconnected");
        try s.sendPacket(.all, .delete_lplayer, protocol.AddRemovePlayer{ .p_id = id });
        try s.checkVote();
    }

    /// Send the queued messages of the world (everything goes through its
    /// outbox so the order is kept).
    fn flushOutbox(s: *Server) Error!void {
        const w = &s.world;
        defer w.outbox.clear();
        for (w.outbox.messages.items) |m| {
            for (s.players.items) |p| {
                const wanted = switch (m.to) {
                    .all => true,
                    .team => |t| p.team == t,
                    .player => |id| p.id == id,
                };
                if (wanted) try p.conn.send(s.gpa, m.id, w.outbox.payload(m));
            }
        }
        for (s.players.items) |p| p.conn.flush();
    }

    pub fn send(s: *Server, to: Audience, id: protocol.Message, payload: []const u8) Error!void {
        try s.world.send(to, id, payload);
    }

    pub fn sendPacket(s: *Server, to: Audience, id: protocol.Message, packet: anytype) Error!void {
        try s.world.sendPacket(to, id, packet);
    }

    pub fn news(s: *Server, to: Audience, text: []const u8) Error!void {
        try s.world.news(to, text, .{});
    }

    pub fn newsFmt(s: *Server, to: Audience, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [512]u8 = undefined;
        try s.news(to, fit(&buf, fmt, args));
    }

    // -----------------------------------------------------------------------
    // Player list relays
    // -----------------------------------------------------------------------

    fn relayName(s: *Server, p: *const Player, to: Audience) Error!void {
        const data = try s.world.outbox.add(s.world.gpa, to, .set_lplayer_name, 4 + p.name.items.len + 1);
        std.mem.writeInt(i32, data[0..4], p.id, .little);
        @memcpy(data[4..][0..p.name.items.len], p.name.items);
        data[data.len - 1] = 0;
    }

    fn relayInt(s: *Server, p: *const Player, to: Audience, id: protocol.Message, value: i32) Error!void {
        try s.sendPacket(to, id, protocol.SetPlayerInt{ .p_id = p.id, .value = value });
    }

    fn relayTeam(s: *Server, p: *const Player, to: Audience) Error!void {
        try s.relayInt(p, to, .set_lplayer_team, @intFromEnum(p.team));
    }

    fn relayMode(s: *Server, p: *const Player, to: Audience) Error!void {
        try s.relayInt(p, to, .set_lplayer_mode, @intFromEnum(p.mode));
    }

    fn relayIgnored(s: *Server, p: *const Player, to: Audience) Error!void {
        try s.relayInt(p, to, .set_lplayer_ignored, @intFromBool(p.ignored));
    }

    fn relayVoteChoice(s: *Server, p: *const Player, to: Audience) Error!void {
        try s.relayInt(p, to, .set_lplayer_voteinfo, @intFromEnum(p.vote));
    }

    fn relayBot(s: *Server, p: *const Player, to: Audience) Error!void {
        try s.sendPacket(to, .set_lplayer_bot, protocol.SetPlayerBot{ .p_id = p.id, .bot = p.bot });
    }

    fn sendPlayerList(s: *Server, to: *const Player) Error!void {
        const audience: Audience = .{ .player = to.id };
        try s.send(audience, .clear_player_list, &.{});
        for (s.players.items) |p| {
            try s.sendPacket(audience, .add_lplayer, protocol.AddRemovePlayer{ .p_id = p.id });
            try s.relayName(p, audience);
            try s.relayTeam(p, audience);
            try s.relayMode(p, audience);
            try s.relayIgnored(p, audience);
            try s.relayBot(p, audience);
            try s.relayVoteChoice(p, audience);
        }
    }

    pub fn changePlayerTeam(s: *Server, p: *Player, team: k.Team) Error!void {
        p.team = team;
        try s.relayTeam(p, .all);
        try s.sendPacket(.{ .player = p.id }, .set_team, protocol.Int{ .value = @intFromEnum(team) });
        try s.newsFmt(.{ .player = p.id }, "you have been set to the {s} team", .{team.name()});
    }

    // -----------------------------------------------------------------------
    // Game state relays
    // -----------------------------------------------------------------------

    fn relayPaused(s: *Server, to: Audience) Error!void {
        try s.sendPacket(to, .update_game_paused, protocol.GamePaused{ .game_paused = s.world.clock.paused });
    }

    fn relaySpeed(s: *Server, to: Audience) Error!void {
        try s.sendPacket(to, .update_game_speed, protocol.Float{ .value = @floatCast(s.world.clock.game_speed) });
    }

    pub fn relayVersion(s: *Server, to: Audience) Error!void {
        var packet: protocol.Version = .{ .version = @splat(0) };
        @memcpy(packet.version[0..k.game_version.len], k.game_version);
        try s.sendPacket(to, .give_version, packet);
    }

    fn relayVoteInfo(s: *Server, to: Audience) Error!void {
        try s.sendPacket(to, .vote_info, protocol.VoteInfo{
            .in_progress = s.vote != null,
            .vote_type = if (s.vote) |v| @intFromEnum(v.kind) else -1,
            .value = if (s.vote) |v| v.value else -1,
        });
    }

    fn sendMap(s: *Server, to: Audience) Error!void {
        const chunk_size = 4096;
        var buf: [4 + chunk_size]u8 = undefined;
        var rest: []const u8 = s.world.map_bytes;
        var n: i32 = 0;
        while (rest.len > 0) : (n += 1) {
            const len = @min(rest.len, chunk_size);
            std.mem.writeInt(i32, buf[0..4], n, .little);
            @memcpy(buf[4..][0..len], rest[0..len]);
            try s.send(to, .store_map, buf[0 .. 4 + len]);
            rest = rest[len..];
        }
        std.mem.writeInt(i32, buf[0..4], -1, .little);
        try s.send(to, .store_map, buf[0..4]);
    }

    fn sendObjects(s: *Server, to: Audience) Error!void {
        const w = &s.world;
        for (w.objects.items) |o| {
            try w.relayNewObject(o, to);
            try w.relayHealth(o, to);
            try w.relayBuildingState(o, to);
            try w.relayGrenadeAmount(o, to);
            try w.relayRallypoints(o, to);
        }
    }

    fn sendZones(s: *Server, to: Audience) Error!void {
        for (s.world.zones.items, 0..) |z, i| {
            try s.sendPacket(to, .set_zone_info, protocol.ZoneInfo{ .zone_number = @intCast(i), .owner = @intCast(@intFromEnum(z.owner)) });
        }
    }

    fn sendMapList(s: *Server, to: Audience) Error!void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(s.gpa);
        for (s.selectable_maps.items, 0..) |m, i| {
            if (i > 0) try text.append(s.gpa, ',');
            try text.appendSlice(s.gpa, m);
        }
        if (text.items.len > 0) try text.append(s.gpa, 0);
        try s.send(to, .give_selectable_map_list, text.items);
    }

    // -----------------------------------------------------------------------
    // Messages from players
    // -----------------------------------------------------------------------

    fn handle(s: *Server, p: *Player, frame: net.conn.Frame) Error!void {
        const me: Audience = .{ .player = p.id };
        const data = frame.payload;
        const w = &s.world;
        switch (frame.id) {
            .debug => try s.newsFmt(me, "hello player {d}", .{p.id}),
            .request_map => try s.sendMap(me),
            .request_objects => try s.sendObjects(me),
            .request_zones => try s.sendZones(me),
            .request_settings => try s.send(me, .set_settings, std.mem.asBytes(&w.settings)),
            .request_player_list => try s.sendPlayerList(p),
            .request_player_id => try s.sendPacket(me, .give_player_id, protocol.PlayerId{ .p_id = p.id }),
            .request_selectable_map_list => try s.sendMapList(me),
            .request_version => try s.relayVersion(me),
            .get_game_paused => try s.relayPaused(me),
            .get_game_speed => try s.relaySpeed(me),

            .set_name => {
                const name = cString(data) orelse return;
                const old = try s.gpa.dupe(u8, p.name.items);
                defer s.gpa.free(old);
                try p.setName(s.gpa, name);
                try s.newsFmt(.all, "player '{s}' set their name to '{s}'", .{ old, p.name.items });
                try s.relayName(p, .all);
            },
            .set_team => {
                const v = protocol.decode(protocol.Int, data) orelse return;
                if (v.value < 0 or v.value >= k.Team.count) return;
                try s.changePlayerTeam(p, @enumFromInt(v.value));
            },
            .set_player_mode => {
                const v = protocol.decode(protocol.PlayerModePacket, data) orelse return;
                if (v.mode < 0 or v.mode >= @typeInfo(k.PlayerMode).@"enum".fields.len) return;
                p.mode = @enumFromInt(v.mode);
                if (p.mode == .bot and s.server_settings.bots_start_ignored and !p.ignored) {
                    p.ignored = true;
                    try s.relayIgnored(p, .all);
                }
                try s.relayMode(p, .all);
            },
            .send_bot_bypass_data => {
                if (data.len == 0) return;
                p.bot = true;
                try p.setName(s.gpa, "Bot");
                try s.relayName(p, .all);
                try s.relayBot(p, .all);
            },
            .send_chat => {
                const text = cString(data) orelse return;
                if (text.len == 0) return;
                if (text[0] == '/') return commands.run(s, p, text[1..]);
                var buf: [600]u8 = undefined;
                const line = fit(&buf, "{s}:: {s}", .{ p.name.items, text });
                const c = teamColor(p.team);
                try w.news(.all, line, .{ .r = @intCast(c[0] * 3 / 10), .g = @intCast(c[1] * 3 / 10), .b = @intCast(c[2] * 3 / 10) });
            },

            .send_waypoints => try s.receiveWaypoints(p, data),
            .send_rallypoints => {
                if (try s.denied(p, "set rally points")) return;
                const o, const list = s.decodeWaypoints(data) orelse return;
                if (try game.sim.setRallypoints(w, o, p.team, list)) try w.relayRallypoints(o, .all);
            },
            .start_building => {
                const v = protocol.decode(protocol.StartBuilding, data) orelse return;
                const o = s.ownBuilding(p, v.ref_id) orelse return;
                if (try s.denied(p, "start production")) return;
                if (try w.setProduction(o, unitOf(v.ot, v.oid) orelse return)) {
                    try w.relayBuildingState(o, .all);
                    try s.sendPacket(me, .comp_msg, protocol.ComputerMsg{ .ref_id = o.ref_id, .sound = @intFromEnum(protocol.CompSound.starting_manufacture) });
                }
            },
            .stop_building => {
                const v = protocol.decode(protocol.Int, data) orelse return;
                const o = s.ownBuilding(p, v.value) orelse return;
                if (try s.denied(p, "stop production")) return;
                if (World.stopProduction(o, true)) {
                    try w.relayBuildingState(o, .all);
                    try s.sendPacket(me, .comp_msg, protocol.ComputerMsg{ .ref_id = o.ref_id, .sound = @intFromEnum(protocol.CompSound.manufacturing_canceled) });
                }
            },
            .add_building_queue => {
                const v = protocol.decode(protocol.AddBuildingQueue, data) orelse return;
                const o = s.ownBuilding(p, v.ref_id) orelse return;
                if (try s.denied(p, "add queue")) return;
                const u = unitOf(v.ot, v.oid) orelse return;
                if (o.building().?.unit == null) {
                    if (try w.setProduction(o, u)) try w.relayBuildingState(o, .all);
                } else if (try w.addToQueue(o, u, false)) {
                    try w.relayQueue(o, .all);
                }
            },
            .cancel_building_queue => {
                const v = protocol.decode(protocol.CancelBuildingQueue, data) orelse return;
                const o = s.ownBuilding(p, v.ref_id) orelse return;
                if (try s.denied(p, "cancel queue")) return;
                if (World.cancelQueued(o, v.list_i, unitOf(v.ot, v.oid) orelse return)) try w.relayQueue(o, .all);
            },
            .place_cannon => {
                const v = protocol.decode(protocol.PlaceCannon, data) orelse return;
                try s.placeCannon(p, v);
            },
            .eject_vehicle => {
                const v = protocol.decode(protocol.EjectVehicle, data) orelse return;
                const o = w.find(v.ref_id) orelse return;
                if (o.owner == .none or o.owner != p.team) return;
                try w.ejectDrivers(o);
            },

            .set_game_paused => {
                const v = protocol.decode(protocol.GamePaused, data) orelse return;
                if (v.game_paused == w.clock.paused) return;
                _ = try s.startVote(if (v.game_paused) .pause else .@"resume", -1, p);
            },
            .set_game_speed => {
                const v = protocol.decode(protocol.Float, data) orelse return;
                _ = try s.startVote(.change_game_speed, @intFromFloat(std.math.clamp(v.value * 100, -1e6, 1e6)), p);
            },
            .start_vote => {
                const v = protocol.decode(protocol.VoteInfo, data) orelse return;
                if (try s.startVote(@enumFromInt(v.vote_type), v.value, p)) try s.castVote(p, .yes);
            },
            .vote_yes => try s.castVote(p, .yes),
            .vote_no => try s.castVote(p, .no),
            .vote_pass => try s.castVote(p, .pass),
            .reshuffle_teams => _ = try s.startVote(.reshuffle_teams, -1, p),
            .start_bot, .stop_bot => {
                const v = protocol.decode(protocol.Int, data) orelse return;
                if (v.value <= 0 or v.value >= k.Team.count) return;
                _ = try s.startVote(if (frame.id == .start_bot) .start_bot else .stop_bot, v.value, p);
            },
            .select_map => {
                const v = protocol.decode(protocol.Int, data) orelse return;
                _ = try s.startVote(.change_map, v.value, p);
            },
            .reset_map => _ = try s.startVote(.reset_game, -1, p),
            else => {},
        }
    }

    /// Ignored players (stopped bots) may not command units.
    fn denied(s: *Server, p: *const Player, what: []const u8) Error!bool {
        if (!p.ignored) return false;
        try s.newsFmt(.{ .player = p.id }, "{s} error: player currently ignored", .{what});
        return true;
    }

    fn ownBuilding(s: *Server, p: *const Player, ref_id: i32) ?*Object {
        const o = s.world.find(ref_id) orelse return null;
        if (!o.producesUnits() or o.owner == .none or o.owner != p.team) return null;
        return o;
    }

    fn decodeWaypoints(s: *Server, data: []const u8) ?struct { *Object, []align(1) const Waypoint } {
        if (data.len < 8) return null;
        const ref_id = std.mem.readInt(i32, data[0..4], .little);
        const count = std.mem.readInt(i32, data[4..8], .little);
        if (count < 0 or data.len != 8 + @as(usize, @intCast(count)) * @sizeOf(Waypoint)) return null;
        const o = s.world.find(ref_id) orelse return null;
        return .{ o, std.mem.bytesAsSlice(Waypoint, data[8..]) };
    }

    fn receiveWaypoints(s: *Server, p: *Player, data: []const u8) Error!void {
        if (try s.denied(p, "move unit")) return;
        const w = &s.world;
        const o, const list = s.decodeWaypoints(data) orelse return;
        const orders = try s.gpa.alloc(Waypoint, list.len);
        defer s.gpa.free(orders);
        for (orders, list) |*dst, src| dst.* = src;
        if (!try game.sim.setOrders(w, o, p.team, orders)) return;

        try w.relayWaypoints(o);
        if (o.waypoints.items.len == 0) {
            if (w.stopMove(o)) try w.relayLocation(o);
            for (o.minions.items) |id| if (w.find(id)) |m| {
                _ = w.stopMove(m);
                try w.relayLocation(m);
            };
        }
    }

    fn placeCannon(s: *Server, p: *Player, v: protocol.PlaceCannon) Error!void {
        const w = &s.world;
        const o = w.find(v.ref_id) orelse return;
        const b = o.building() orelse return;
        if (o.zone == null or o.owner == .none or o.owner != p.team) return;
        const index = std.mem.indexOfScalar(k.Cannon, b.cannons.items, @enumFromInt(v.oid)) orelse return;
        if (!w.cannonPlacable(o, v.tx, v.ty)) return;
        _ = b.cannons.orderedRemove(index);
        const cannon = try w.createObject(.cannon, v.oid, v.tx * 16, v.ty * 16, o.owner, .direct, .{}) orelse return;
        if (w.areaIsFortTurret(v.tx, v.ty)) cannon.kind.cannon.ejectable = false;
        try w.relayNewObject(cannon, .all);
        try w.relayBuiltCannons(o);
    }

    // -----------------------------------------------------------------------
    // Votes
    // -----------------------------------------------------------------------

    fn playersInGame(s: *const Server) usize {
        var n: usize = 0;
        for (s.players.items) |p| n += @intFromBool(p.mode == .player);
        return n;
    }

    /// Half of the votes of those not passing, rounded up.
    fn votesNeeded(s: *const Server) usize {
        var n: usize = 0;
        for (s.players.items) |p| n += @intFromBool(p.vote != .pass);
        return (n + 1) / 2;
    }

    fn votesWith(s: *const Server, choice: k.VoteChoice) usize {
        var n: usize = 0;
        for (s.players.items) |p| n += @intFromBool(p.vote == choice);
        return n;
    }

    /// Start a vote (or just do it when no vote is needed). Returns whether
    /// a vote was started.
    pub fn startVote(s: *Server, kind: VoteType, value: i32, p: ?*Player) Error!bool {
        const me: ?Audience = if (p) |pl| .{ .player = pl.id } else null;
        switch (kind) {
            .change_map => if (value < 0 or value >= s.selectable_maps.items.len) {
                if (me) |a| try s.news(a, "invalid map choice, please type /listmaps");
                return false;
            },
            .start_bot, .stop_bot => if (value <= 0 or value >= k.Team.count) return false,
            .change_game_speed => {
                if (!s.server_settings.allow_game_speed_change) {
                    if (me) |a| try s.news(a, "changing the game speed is not allowed on this server");
                    return false;
                }
                if (value <= 0) {
                    if (me) |a| try s.news(a, "new game speed must be above zero");
                    return false;
                }
            },
            .pause, .@"resume", .reset_game, .reshuffle_teams => {},
            _ => return false,
        }

        if (s.vote) |v| {
            // Starting the same vote again counts as a yes.
            if (p != null and v.kind == kind and v.value == value) try s.castVote(p.?, .yes);
            return false;
        }

        // Alone (or with a majority on your own) there is nothing to vote on.
        if (s.playersInGame() < 2 or s.votesNeeded() <= 1) {
            try s.applyVote(kind, value);
            return false;
        }

        s.vote = .{ .kind = kind, .value = value, .end_time = s.realTime() + vote_time };
        if (p) |pl| {
            var buf: [256]u8 = undefined;
            const extra = s.voteDescription(&buf, kind, value);
            if (extra.len > 0)
                try s.newsFmt(.all, "vote started by {s} to {s}: {s}", .{ pl.name.items, kind.description(), extra })
            else
                try s.newsFmt(.all, "vote started by {s} to {s}", .{ pl.name.items, kind.description() });
        }
        try s.clearVotes();
        if (p) |pl| try s.castVote(pl, .yes);
        try s.relayVoteInfo(.all);
        return true;
    }

    fn voteDescription(s: *const Server, buf: []u8, kind: VoteType, value: i32) []const u8 {
        return switch (kind) {
            .change_map => if (value >= 0 and value < s.selectable_maps.items.len)
                fit(buf, "{d}. {s}", .{ value, s.selectable_maps.items[@intCast(value)] })
            else
                "",
            .start_bot, .stop_bot => if (value >= 0 and value < k.Team.count) @as(k.Team, @enumFromInt(value)).name() else "",
            else => "",
        };
    }

    fn castVote(s: *Server, p: *Player, choice: k.VoteChoice) Error!void {
        if (s.vote == null) return;
        const me: Audience = .{ .player = p.id };
        if (p.vote != .none) return s.news(me, "you have already voted");
        p.vote = choice;
        try s.relayVoteChoice(p, .all);
        try s.checkVote();
        try s.news(me, switch (choice) {
            .yes => "you have voted yes",
            .no => "you have voted no",
            else => "you have passed on voting",
        });
    }

    fn checkVote(s: *Server) Error!void {
        const v = s.vote orelse return;
        const needed = s.votesNeeded();
        if (s.votesWith(.yes) >= needed) {
            try s.killVote();
            try s.applyVote(v.kind, v.value);
        } else if (s.votesWith(.no) >= needed) {
            try s.killVote();
        }
    }

    fn checkVoteExpired(s: *Server, now: f64) Error!void {
        const v = s.vote orelse return;
        if (now < v.end_time) return;
        try s.killVote();
        try s.news(.all, "vote has expired");
    }

    fn killVote(s: *Server) Error!void {
        if (s.vote == null) return;
        s.vote = null;
        try s.clearVotes();
        try s.relayVoteInfo(.all);
    }

    fn clearVotes(s: *Server) Error!void {
        for (s.players.items) |p| {
            p.vote = .none;
            try s.relayVoteChoice(p, .all);
        }
    }

    fn applyVote(s: *Server, kind: VoteType, value: i32) Error!void {
        switch (kind) {
            .pause => try s.pause(),
            .@"resume" => try s.unpause(),
            .change_map => if (value >= 0 and value < s.selectable_maps.items.len) {
                try s.resetGame(s.selectable_maps.items[@intCast(value)]);
            },
            .start_bot => if (value > 0 and value < k.Team.count) {
                const team: k.Team = @enumFromInt(value);
                if (!s.teamHasBot(team, false)) s.bots.start(team);
                try s.setBotsIgnored(team, false);
            },
            .stop_bot => if (value > 0 and value < k.Team.count) try s.setBotsIgnored(@enumFromInt(value), true),
            .reset_game => {
                const name = try s.gpa.dupe(u8, s.map_name.items);
                defer s.gpa.free(name);
                try s.resetGame(name);
            },
            .reshuffle_teams => try s.reshuffleTeams(),
            .change_game_speed => if (value > 0) {
                s.world.clock.setGameSpeedAt(@as(f64, @floatFromInt(value)) / 100.0, s.realTime());
                try s.relaySpeed(.all);
                try s.newsFmt(.all, "game speed changed to {d}%", .{@as(i64, @intFromFloat(s.world.clock.game_speed * 100))});
            },
            _ => {},
        }
    }

    // -----------------------------------------------------------------------
    // Game flow
    // -----------------------------------------------------------------------

    pub fn pause(s: *Server) Error!void {
        if (s.world.clock.paused) return;
        s.world.clock.pauseAt(s.realTime());
        try s.relayPaused(.all);
    }

    pub fn unpause(s: *Server) Error!void {
        if (!s.world.clock.paused) return;
        s.world.clock.resumeAt(s.realTime());
        try s.relayPaused(.all);
    }

    /// Start a new game on `map` (null: the next one from the list).
    pub fn resetGame(s: *Server, map: ?[]const u8) Error!void {
        try s.loadNextMap(map);
        try s.news(.all, "A new game has started");
        try s.send(.all, .reset_game, &.{});
    }

    fn checkEndGame(s: *Server, now: f64) Error!void {
        if (!s.game_on) {
            if (s.reset_time) |t| if (now >= t) try s.resetGame(null);
            return;
        }
        const t = s.world.now();
        if (t < s.next_end_check) return;
        s.next_end_check = t + 1.0;
        if (!s.world.endGameRequirementsMet()) return;

        // The teams left have won.
        const alive = s.world.teamsWithUnits();
        for (alive[1..], 1..) |a, team| {
            if (a) try s.sendPacket(.all, .team_ended, protocol.TeamEnded{ .team = @intCast(team), .won = true });
        }
        s.game_on = false;
        if (s.map_list.items.len > 0) s.reset_time = now + reset_delay;
        try s.news(.all, "<<<< The game has ended >>>>");
        try s.send(.all, .end_game, &.{});
    }

    pub fn teamHasBot(s: *const Server, team: k.Team, active_only: bool) bool {
        for (s.players.items) |p| {
            if (p.team == team and p.mode == .bot and (!active_only or !p.ignored)) return true;
        }
        return false;
    }

    fn setBotsIgnored(s: *Server, team: k.Team, ignored: bool) Error!void {
        var changed = false;
        for (s.players.items) |p| {
            if (p.team != team or p.mode != .bot or p.ignored == ignored) continue;
            p.ignored = ignored;
            try s.relayIgnored(p, .all);
            changed = true;
        }
        if (changed) try s.newsFmt(.all, "the {s} team bot has been {s}", .{ team.name(), if (ignored) "stopped" else "started" });
    }

    fn reshuffleTeams(s: *Server) Error!void {
        var players: std.ArrayList(*Player) = .empty;
        defer players.deinit(s.gpa);
        for (s.players.items) |p| if (p.mode == .player) try players.append(s.gpa, p);
        if (players.items.len == 0) return s.news(.all, "reshuffle teams error: no players to shuffle");

        var teams: std.ArrayList(k.Team) = .empty;
        defer teams.deinit(s.gpa);
        const alive = s.world.teamsWithUnits();
        for (alive[1..], 1..) |a, i| {
            const team: k.Team = @enumFromInt(i);
            if (a and !s.teamHasBot(team, true)) try teams.append(s.gpa, team);
        }
        if (teams.items.len == 0) return s.news(.all, "reshuffle teams error: no available teams to shuffle to");

        var available = try teams.clone(s.gpa);
        defer available.deinit(s.gpa);
        for (players.items) |p| {
            if (available.items.len == 0) try available.appendSlice(s.gpa, teams.items);
            const i = s.world.random().uintLessThan(usize, available.items.len);
            try s.changePlayerTeam(p, available.swapRemove(i));
        }
        try s.news(.all, "the teams have been reshuffled");
    }

    /// Every 30s, if all players are on one team with nobody to fight,
    /// tell them how to get opponents.
    fn checkSuggestions(s: *Server, now: f64) Error!void {
        if (now < s.next_suggestion_time) return;
        s.next_suggestion_time = now + 30;

        var players: [k.Team.count]u32 = @splat(0);
        var bots: [k.Team.count]u32 = @splat(0);
        for (s.players.items) |p| {
            if (p.ignored) continue;
            switch (p.mode) {
                .player => players[@intFromEnum(p.team)] += 1,
                .bot => bots[@intFromEnum(p.team)] += 1,
                else => {},
            }
        }
        var only: ?usize = null;
        for (players[1..], 1..) |n, i| if (n > 0) {
            if (only != null) return;
            only = i;
        };
        const team = only orelse return;
        for (bots[1..], 1..) |n, i| if (n > 0 and i != team) return;
        try s.news(.all, if (players[team] > 1)
            "please type in /help to learn about the commands /changeteam, /reshuffleteams, and /startbot"
        else
            "please type in /help to learn about the command /startbot");
    }
};

fn cString(data: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    return data[0..end];
}

fn unitOf(ot: u8, oid: u8) ?game.object.Unit {
    const kind: k.ObjectType = @enumFromInt(ot);
    return switch (kind) {
        .robot, .vehicle, .cannon => .{ .kind = kind, .id = oid },
        else => null,
    };
}

/// Chat colors (news text is drawn in 30% of the team color).
fn teamColor(t: k.Team) [3]u16 {
    return switch (t) {
        .none => .{ 115, 115, 115 },
        .red => .{ 223, 0, 0 },
        .blue => .{ 19, 55, 251 },
        .green => .{ 23, 143, 19 },
        .yellow => .{ 203, 99, 47 },
        .purple => .{ 160, 32, 240 },
        .teal => .{ 0, 128, 128 },
        .white => .{ 230, 230, 230 },
        .black => .{ 40, 40, 40 },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A client for tests: collects what the server sends.
const TestClient = struct {
    conn: Conn,
    got: std.ArrayList(struct { id: protocol.Message, payload: []u8 }) = .empty,

    fn deinit(c: *TestClient) void {
        for (c.got.items) |m| testing.allocator.free(m.payload);
        c.got.deinit(testing.allocator);
        c.conn.deinit(testing.allocator);
    }

    fn poll(c: *TestClient) !void {
        try c.conn.receive(testing.allocator);
        while (c.conn.next()) |f| try c.got.append(testing.allocator, .{ .id = f.id, .payload = try testing.allocator.dupe(u8, f.payload) });
    }

    fn count(c: *const TestClient, id: protocol.Message) usize {
        var n: usize = 0;
        for (c.got.items) |m| n += @intFromBool(m.id == id);
        return n;
    }
};

test "a client connects, gets the map and objects, and orders units" {
    const io = testing.io;
    const gpa = testing.allocator;
    var data = try std.Io.Dir.cwd().openDir(io, "bin", .{});
    defer data.close(io);

    const port = 18123;
    const s = try Server.init(gpa, io, data, .{
        .port = port,
        .map = "../Data/Campaing/Z_original/p02_bb_orig01.map",
        .settings = "default_settings.txt",
    });
    defer s.deinit();

    var client: TestClient = .{ .conn = try Conn.connect("127.0.0.1", port) };
    defer client.deinit();

    // The handshake of the original client.
    try client.conn.sendPacket(gpa, .request_version, protocol.Int{ .value = 0 });
    try client.conn.send(gpa, .get_game_paused, &.{});
    try client.conn.send(gpa, .request_settings, &.{});
    try client.conn.sendString(gpa, .set_name, "tester");
    try client.conn.sendPacket(gpa, .set_team, protocol.Int{ .value = @intFromEnum(k.Team.red) });
    try client.conn.sendPacket(gpa, .set_player_mode, protocol.PlayerModePacket{ .mode = @intFromEnum(k.PlayerMode.player) });
    try client.conn.send(gpa, .request_player_list, &.{});
    try client.conn.send(gpa, .request_map, &.{});
    try client.conn.send(gpa, .request_objects, &.{});
    try client.conn.send(gpa, .request_zones, &.{});
    client.conn.flush();

    for (0..50) |_| {
        try s.tick();
        try client.poll();
    }
    try testing.expectEqual(@as(usize, 1), client.count(.give_version));
    try testing.expectEqual(@as(usize, 1), client.count(.set_settings));
    try testing.expect(client.count(.store_map) >= 2);
    try testing.expect(client.count(.add_new_object) > 10);
    try testing.expect(client.count(.set_zone_info) > 0);
    try testing.expect(client.count(.set_team) == 1);

    // The map arrives intact.
    var map_bytes: std.ArrayList(u8) = .empty;
    defer map_bytes.deinit(gpa);
    for (client.got.items) |m| if (m.id == .store_map and m.payload.len > 4) try map_bytes.appendSlice(gpa, m.payload[4..]);
    try testing.expectEqualSlices(u8, s.world.map_bytes, map_bytes.items);

    // Alone on the server, pausing needs no vote. Resume and move a unit.
    try client.conn.sendPacket(gpa, .set_game_paused, protocol.GamePaused{ .game_paused = false });
    var unit: ?*Object = null;
    for (s.world.objects.items) |o| if (o.owner == .red and o.canMove() and o.leader == null) {
        unit = o;
        break;
    };
    const u = unit.?;
    var order: [8 + @sizeOf(Waypoint)]u8 = undefined;
    std.mem.writeInt(i32, order[0..4], u.ref_id, .little);
    std.mem.writeInt(i32, order[4..8], 1, .little);
    const wp: Waypoint = .{ .mode = .move, .x = u.center_x + 64, .y = u.center_y, .player_given = true };
    @memcpy(order[8..], std.mem.asBytes(&wp));
    try client.conn.send(gpa, .send_waypoints, &order);
    client.conn.flush();

    const start_x = u.x;
    for (0..100) |_| {
        try s.tick();
        try client.poll();
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(!s.world.clock.paused);
    try testing.expect(client.count(.send_waypoints) >= 1);
    try testing.expect(client.count(.send_loc) >= 1);
    try testing.expect(u.x != start_x);
}
