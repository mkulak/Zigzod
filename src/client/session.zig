//! The client's view of a game: the connection to the server and the game
//! state it keeps in sync (from ZClient and ZPlayer's event handlers).
//! Knows nothing about graphics; `events` tells the UI what happened.

const std = @import("std");
const game = @import("../game.zig");
const net = @import("../net.zig");

const k = game.constants;
const protocol = net.protocol;
const World = game.world.World;
const Object = game.object.Object;
const Waypoint = game.object.Waypoint;
const Conn = net.conn.Conn;

pub const Error = std.mem.Allocator.Error;

pub const Player = struct {
    id: i32,
    name: std.ArrayList(u8) = .empty,
    team: k.Team = .none,
    mode: k.PlayerMode = .nobody,
    ignored: bool = false,
    bot: bool = false,
    vote: k.VoteChoice = .none,
};

/// Where an object is heading: the server sends position and velocity, the
/// client moves it along until the next update (SmoothMove).
pub const Motion = struct {
    x: i32,
    y: i32,
    time: f64,
};

/// Things the UI may want to react to (sounds, effects, animations).
pub const Event = union(enum) {
    map_loaded,
    reset_game,
    end_game,
    new_object: i32,
    deleted_object: i32,
    health_changed: struct { ref_id: i32, old: i32 },
    fired_missile: struct { ref_id: i32, x: i32, y: i32 },
    destroyed: struct { ref_id: i32, killer: i32, fire_death: bool, missile_death: bool, destroy: bool, missiles: []protocol.FireMissileInfo },
    team_changed: i32,
    news: struct { text: []u8, color: [3]u8 },
    comp_msg: protocol.ComputerMsg,
    portrait_anim: protocol.DoPortraitAnim,
    crane_anim: protocol.CraneAnim,
    repair_anim: protocol.RepairBuildingAnim,
    lid: protocol.SetLidState,
    snipe: i32,
    driver_hit: i32,
    pickup_grenades: i32,
    team_ended: protocol.TeamEnded,
    version: []u8,
    buy_regkey,
    regkey: [16]u8,

    fn deinit(e: Event, gpa: std.mem.Allocator) void {
        switch (e) {
            .news => |n| gpa.free(n.text),
            .destroyed => |d| gpa.free(d.missiles),
            .version => |v| gpa.free(v),
            else => {},
        }
    }
};

pub const Vote = struct {
    in_progress: bool = false,
    kind: i32 = -1,
    value: i32 = -1,
};

pub const Options = struct {
    name: []const u8 = "Player",
    team: k.Team = .red,
    mode: k.PlayerMode = .player,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    conn: Conn,
    world: World,
    options: Options,

    /// Our player id and team, as the server says.
    id: i32 = -1,
    team: k.Team = .none,
    players: std.ArrayList(Player) = .empty,
    selectable_maps: std.ArrayList([]u8) = .empty,
    vote: Vote = .{},
    server_version: std.ArrayList(u8) = .empty,
    map_download: std.ArrayList(u8) = .empty,
    map_loaded: bool = false,
    /// Real time the game clock is based on.
    real_time: f64 = 0,

    motion: std.AutoHashMapUnmanaged(i32, Motion) = .empty,
    events: std.ArrayList(Event) = .empty,

    pub fn init(gpa: std.mem.Allocator, conn: Conn, terrain: *const game.map.Terrain, options: Options) Session {
        return .{
            .gpa = gpa,
            .conn = conn,
            .world = World.init(gpa, terrain, 0),
            .options = options,
        };
    }

    pub fn deinit(s: *Session) void {
        const gpa = s.gpa;
        s.conn.deinit(gpa);
        s.world.deinit();
        for (s.players.items) |*p| p.name.deinit(gpa);
        s.players.deinit(gpa);
        for (s.selectable_maps.items) |m| gpa.free(m);
        s.selectable_maps.deinit(gpa);
        s.server_version.deinit(gpa);
        s.map_download.deinit(gpa);
        s.motion.deinit(gpa);
        s.clearEvents();
        s.events.deinit(gpa);
    }

    pub fn clearEvents(s: *Session) void {
        for (s.events.items) |e| e.deinit(s.gpa);
        s.events.clearRetainingCapacity();
    }

    fn emit(s: *Session, e: Event) Error!void {
        try s.events.append(s.gpa, e);
    }

    // -----------------------------------------------------------------------
    // Sending
    // -----------------------------------------------------------------------

    pub fn send(s: *Session, id: protocol.Message, payload: []const u8) Error!void {
        try s.conn.send(s.gpa, id, payload);
    }

    pub fn sendPacket(s: *Session, id: protocol.Message, packet: anytype) Error!void {
        try s.conn.sendPacket(s.gpa, id, packet);
    }

    /// The opening requests (ZClient::ProcessConnect).
    pub fn start(s: *Session) Error!void {
        try s.send(.request_version, &.{});
        try s.send(.get_game_paused, &.{});
        try s.send(.get_game_speed, &.{});
        try s.send(.request_settings, &.{});
        try s.conn.sendString(s.gpa, .set_name, s.options.name);
        try s.sendPacket(.set_team, protocol.Int{ .value = @intFromEnum(s.options.team) });
        try s.sendPacket(.set_player_mode, protocol.PlayerModePacket{ .mode = @intCast(@intFromEnum(s.options.mode)) });
        try s.send(.request_player_id, &.{});
        try s.send(.request_player_list, &.{});
        try s.send(.request_selectable_map_list, &.{});
        try s.send(.request_map, &.{});
        s.conn.flush();
    }

    pub fn chat(s: *Session, text: []const u8) Error!void {
        try s.conn.sendString(s.gpa, .send_chat, text);
    }

    /// Give a unit its orders.
    pub fn sendWaypoints(s: *Session, ref_id: i32, list: []const Waypoint, rally: bool) Error!void {
        const data = try s.gpa.alloc(u8, 8 + list.len * @sizeOf(Waypoint));
        defer s.gpa.free(data);
        std.mem.writeInt(i32, data[0..4], ref_id, .little);
        std.mem.writeInt(i32, data[4..8], @intCast(list.len), .little);
        @memcpy(data[8..], std.mem.sliceAsBytes(list));
        try s.send(if (rally) .send_rallypoints else .send_waypoints, data);
    }

    // -----------------------------------------------------------------------
    // Receiving
    // -----------------------------------------------------------------------

    /// Read the network, apply what arrived and advance the game clock.
    pub fn update(s: *Session, real_time: f64) Error!void {
        s.real_time = real_time;
        try s.conn.receive(s.gpa);
        while (s.conn.next()) |frame| try s.handle(frame.id, frame.payload);
        s.world.clock.updateAt(real_time);
        s.smoothMove();
        s.conn.flush();
    }

    pub fn connected(s: *const Session) bool {
        return s.conn.open;
    }

    pub fn find(s: *const Session, ref_id: i32) ?*Object {
        return s.world.find(ref_id);
    }

    /// Move objects along their last known velocity.
    fn smoothMove(s: *Session) void {
        const t = s.world.now();
        for (s.world.objects.items) |o| {
            const m = s.motion.get(o.ref_id) orelse continue;
            var x = o.x;
            var y = o.y;
            if (!game.object.isZero(o.dx)) x = m.x + @as(i32, @intFromFloat(@floor(o.dx * (t - m.time))));
            if (!game.object.isZero(o.dy)) y = m.y + @as(i32, @intFromFloat(@floor(o.dy * (t - m.time))));
            o.setPosition(x, y);
        }
    }

    fn player(s: *Session, id: i32) ?*Player {
        for (s.players.items) |*p| if (p.id == id) return p;
        return null;
    }

    fn handle(s: *Session, id: protocol.Message, data: []const u8) Error!void {
        const w = &s.world;
        switch (id) {
            .store_map => try s.mapChunk(data),
            .add_new_object => try s.newObject(data),
            .delete_object => {
                const v = protocol.decode(protocol.Int, data) orelse return;
                const i = s.indexOf(v.value) orelse return;
                try s.removeObject(i);
                try s.emit(.{ .deleted_object = v.value });
            },
            .set_zone_info => {
                const v = protocol.decode(protocol.ZoneInfo, data) orelse return;
                if (v.owner < 0 or v.owner >= k.Team.count or v.zone_number < 0 or v.zone_number >= w.zones.items.len) return;
                w.zones.items[@intCast(v.zone_number)].owner = @enumFromInt(v.owner);
            },
            .send_loc => {
                if (data.len != 4 + @sizeOf(protocol.Location)) return;
                const o = s.find(std.mem.readInt(i32, data[0..4], .little)) orelse return;
                const loc = std.mem.bytesToValue(protocol.Location, data[4..]);
                o.dx = loc.dx;
                o.dy = loc.dy;
                o.setPosition(loc.x, loc.y);
                try s.motion.put(s.gpa, o.ref_id, .{ .x = loc.x, .y = loc.y, .time = w.now() });
            },
            .send_waypoints, .send_rallypoints => {
                if (data.len < 8) return;
                const o = s.find(std.mem.readInt(i32, data[0..4], .little)) orelse return;
                const n = std.mem.readInt(i32, data[4..8], .little);
                if (n < 0 or data.len != 8 + @as(usize, @intCast(n)) * @sizeOf(Waypoint)) return;
                const list = if (id == .send_waypoints) &o.waypoints else &o.rallypoints;
                list.clearRetainingCapacity();
                for (std.mem.bytesAsSlice(Waypoint, data[8..])) |wp| try list.append(s.gpa, wp);
            },
            .set_object_team => {
                if (data.len < @sizeOf(protocol.ObjectTeam)) return;
                const v = std.mem.bytesToValue(protocol.ObjectTeam, data[0..@sizeOf(protocol.ObjectTeam)]);
                const n: usize = @intCast(@max(v.driver_amount, 0));
                if (data.len != @sizeOf(protocol.ObjectTeam) + n * @sizeOf(protocol.DriverInfo)) return;
                if (v.owner < 0 or v.owner >= k.Team.count) return;
                const o = s.find(v.ref_id) orelse return;
                o.owner = @enumFromInt(v.owner);
                if (v.driver_type >= 0 and v.driver_type < k.Robot.count) o.setDriverType(&w.settings, @enumFromInt(v.driver_type));
                o.drivers.clearRetainingCapacity();
                for (std.mem.bytesAsSlice(protocol.DriverInfo, data[@sizeOf(protocol.ObjectTeam)..])) |d| try o.drivers.append(s.gpa, d);
                try s.emit(.{ .team_changed = o.ref_id });
            },
            .set_attack_object => {
                const v = protocol.decode(protocol.AttackObject, data) orelse return;
                const o = s.find(v.ref_id) orelse return;
                o.attack_target = if (s.find(v.attack_object_ref_id) != null) v.attack_object_ref_id else null;
            },
            .update_health => {
                const v = protocol.decode(protocol.ObjectHealth, data) orelse return;
                const o = s.find(v.ref_id) orelse return;
                const old = o.health;
                w.setHealth(o, v.health);
                if (old != o.health) try s.emit(.{ .health_changed = .{ .ref_id = o.ref_id, .old = old } });
            },
            .fire_missile => {
                const v = protocol.decode(protocol.FireMissile, data) orelse return;
                if (s.find(v.ref_id) == null) return;
                try s.emit(.{ .fired_missile = .{ .ref_id = v.ref_id, .x = v.x, .y = v.y } });
            },
            .destroy_object => try s.destroyObject(data),
            .set_building_state => {
                const v = protocol.decode(protocol.SetBuildingState, data) orelse return;
                const o = s.find(v.ref_id) orelse return;
                const b = o.building() orelse return;
                if (v.state < 0 or v.state > 3) return;
                b.state = @enumFromInt(v.state);
                b.unit = if (v.ot == 255) null else .{ .kind = @enumFromInt(v.ot), .id = v.oid };
                b.init_time = w.now() + v.init_offset;
                b.final_time = b.init_time + v.prod_time;
            },
            .set_building_queue_list => {
                if (data.len < 8) return;
                const o = s.find(std.mem.readInt(i32, data[0..4], .little)) orelse return;
                const b = o.building() orelse return;
                const n = std.mem.readInt(i32, data[4..8], .little);
                if (n < 0 or data.len != 8 + 2 * @as(usize, @intCast(n))) return;
                b.queue.clearRetainingCapacity();
                var i: usize = 8;
                while (i < data.len) : (i += 2) try b.queue.append(s.gpa, .{ .kind = @enumFromInt(data[i]), .id = data[i + 1] });
            },
            .set_built_cannon_amount => {
                if (data.len < 8) return;
                const o = s.find(std.mem.readInt(i32, data[0..4], .little)) orelse return;
                const b = o.building() orelse return;
                const n = std.mem.readInt(i32, data[4..8], .little);
                if (n < 0 or data.len != 8 + @as(usize, @intCast(n))) return;
                b.cannons.clearRetainingCapacity();
                for (data[8..]) |cn| if (cn < k.Cannon.count) try b.cannons.append(s.gpa, @enumFromInt(cn));
            },
            .object_group_info => try s.groupInfo(data),
            .set_lid_open => {
                const v = protocol.decode(protocol.SetLidState, data) orelse return;
                const o = s.find(v.ref_id) orelse return;
                switch (o.kind) {
                    .vehicle => |*veh| veh.lid_open = v.lid_open,
                    else => {},
                }
                try s.emit(.{ .lid = v });
            },
            .set_grenade_amount => {
                const v = protocol.decode(protocol.GrenadeAmount, data) orelse return;
                const o = s.find(v.ref_id) orelse return;
                o.grenades = v.grenade_amount;
            },
            .set_settings => {
                if (data.len != @sizeOf(game.settings.Settings)) return;
                w.settings = std.mem.bytesToValue(game.settings.Settings, data);
            },
            .news => {
                if (data.len < 4) return;
                const text = protocol.decodeString(data[3..]);
                try s.emit(.{ .news = .{ .text = try s.gpa.dupe(u8, text), .color = data[0..3].* } });
            },
            .comp_msg => if (protocol.decode(protocol.ComputerMsg, data)) |v| try s.emit(.{ .comp_msg = v }),
            .do_portrait_anim => if (protocol.decode(protocol.DoPortraitAnim, data)) |v| try s.emit(.{ .portrait_anim = v }),
            .do_crane_anim => if (protocol.decode(protocol.CraneAnim, data)) |v| try s.emit(.{ .crane_anim = v }),
            .set_repair_anim => {
                const v = protocol.decode(protocol.RepairBuildingAnim, data) orelse return;
                try s.emit(.{ .repair_anim = v });
            },
            .snipe_object => if (protocol.decode(protocol.SnipeObject, data)) |v| try s.emit(.{ .snipe = v.ref_id }),
            .driver_hit_effect => if (protocol.decode(protocol.DriverHit, data)) |v| try s.emit(.{ .driver_hit = v.ref_id }),
            .pickup_grenade_anim => if (protocol.decode(protocol.Int, data)) |v| try s.emit(.{ .pickup_grenades = v.value }),
            .team_ended => if (protocol.decode(protocol.TeamEnded, data)) |v| try s.emit(.{ .team_ended = v }),
            .end_game => try s.emit(.end_game),
            .reset_game => {
                s.world.clear();
                s.motion.clearRetainingCapacity();
                s.map_loaded = false;
                try s.send(.request_map, &.{});
                try s.emit(.reset_game);
            },

            .clear_player_list => {
                for (s.players.items) |*p| p.name.deinit(s.gpa);
                s.players.clearRetainingCapacity();
            },
            .add_lplayer => {
                const v = protocol.decode(protocol.AddRemovePlayer, data) orelse return;
                if (s.player(v.p_id) == null) try s.players.append(s.gpa, .{ .id = v.p_id });
            },
            .delete_lplayer => {
                const v = protocol.decode(protocol.AddRemovePlayer, data) orelse return;
                for (s.players.items, 0..) |*p, i| if (p.id == v.p_id) {
                    p.name.deinit(s.gpa);
                    _ = s.players.orderedRemove(i);
                    break;
                };
            },
            .set_lplayer_name => {
                if (data.len < 5 or data[data.len - 1] != 0) return;
                const p = s.player(std.mem.readInt(i32, data[0..4], .little)) orelse return;
                p.name.clearRetainingCapacity();
                try p.name.appendSlice(s.gpa, protocol.decodeString(data[4..]));
            },
            .set_lplayer_team, .set_lplayer_mode, .set_lplayer_ignored, .set_lplayer_voteinfo => {
                const v = protocol.decode(protocol.SetPlayerInt, data) orelse return;
                const p = s.player(v.p_id) orelse return;
                switch (id) {
                    .set_lplayer_team => if (v.value >= 0 and v.value < k.Team.count) {
                        p.team = @enumFromInt(v.value);
                    },
                    .set_lplayer_mode => if (v.value >= 0 and v.value < @typeInfo(k.PlayerMode).@"enum".fields.len) {
                        p.mode = @enumFromInt(v.value);
                    },
                    .set_lplayer_ignored => p.ignored = v.value != 0,
                    else => if (v.value >= 0 and v.value < @typeInfo(k.VoteChoice).@"enum".fields.len) {
                        p.vote = @enumFromInt(v.value);
                    },
                }
            },
            .set_lplayer_loginfo => {
                const v = protocol.decode(protocol.SetPlayerLogInfo, data) orelse return;
                const p = s.player(v.p_id) orelse return;
                p.bot = v.bot_logged_in;
            },
            .give_player_id => if (protocol.decode(protocol.PlayerId, data)) |v| {
                s.id = v.p_id;
            },
            .set_team => {
                const v = protocol.decode(protocol.Int, data) orelse return;
                if (v.value >= 0 and v.value < k.Team.count) s.team = @enumFromInt(v.value);
            },
            .update_game_paused => {
                const v = protocol.decode(protocol.GamePaused, data) orelse return;
                if (v.game_paused) w.clock.pauseAt(s.real_time) else w.clock.resumeAt(s.real_time);
            },
            .update_game_speed => {
                const v = protocol.decode(protocol.Float, data) orelse return;
                w.clock.setGameSpeedAt(v.value, s.real_time);
            },
            .vote_info => {
                const v = protocol.decode(protocol.VoteInfo, data) orelse return;
                s.vote = .{ .in_progress = v.in_progress, .kind = v.vote_type, .value = v.value };
            },
            .give_selectable_map_list => {
                for (s.selectable_maps.items) |m| s.gpa.free(m);
                s.selectable_maps.clearRetainingCapacity();
                var it = std.mem.tokenizeScalar(u8, protocol.decodeString(data), ',');
                while (it.next()) |m| try s.selectable_maps.append(s.gpa, try s.gpa.dupe(u8, m));
            },
            .give_version => {
                const v = protocol.decode(protocol.Version, data) orelse return;
                s.server_version.clearRetainingCapacity();
                try s.server_version.appendSlice(s.gpa, protocol.decodeString(&v.version));
                try s.emit(.{ .version = try s.gpa.dupe(u8, s.server_version.items) });
            },
            .poll_buy_regkey => try s.emit(.buy_regkey),
            .return_regkey => if (protocol.decode(protocol.BuyRegistration, data)) |v| try s.emit(.{ .regkey = v.buf }),
            else => {},
        }
    }

    fn mapChunk(s: *Session, data: []const u8) Error!void {
        if (data.len < 4) return;
        const n = std.mem.readInt(i32, data[0..4], .little);
        if (n == 0) s.map_download.clearRetainingCapacity();
        if (n != -1) return s.map_download.appendSlice(s.gpa, data[4..]);

        // The whole map arrived.
        if (s.map_download.items.len > 0) {
            s.motion.clearRetainingCapacity();
            s.world.setMap(s.map_download.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.log.warn("bad map from server: {t}", .{err}),
            };
            s.map_download.clearRetainingCapacity();
            s.map_loaded = s.world.map != null;
            if (s.map_loaded) try s.emit(.map_loaded);
        }
        try s.send(.request_objects, &.{});
        try s.send(.request_zones, &.{});
    }

    fn newObject(s: *Session, data: []const u8) Error!void {
        const v = protocol.decode(protocol.ObjectInit, data) orelse return;
        if (v.owner < -1 or v.owner >= k.Team.count) return;
        if (s.find(v.ref_id) != null) return;
        const w = &s.world;
        const o = try w.createObjectWithId(v.ref_id, @enumFromInt(v.object_type), v.object_id, v.x, v.y, k.Team.fromByte(v.owner), .direct, .{
            .level = @intCast(@max(v.blevel, 0)),
            .extra_links = v.extra_links,
        }) orelse return;
        w.setHealth(o, v.health);
        o.processed_death = o.isDestroyed();
        try s.motion.put(s.gpa, o.ref_id, .{ .x = o.x, .y = o.y, .time = w.now() });
        try s.emit(.{ .new_object = o.ref_id });
    }

    fn indexOf(s: *const Session, ref_id: i32) ?usize {
        for (s.world.objects.items, 0..) |o, i| if (o.ref_id == ref_id) return i;
        return null;
    }

    fn removeObject(s: *Session, i: usize) Error!void {
        const w = &s.world;
        const o = w.objects.items[i];
        if (w.grid) |*g| o.unsetImpassables(g);
        for (w.objects.items) |other| {
            if (other.attack_target == o.ref_id) other.attack_target = null;
            if (other.leader == o.ref_id) other.leader = null;
            var j: usize = 0;
            while (j < other.minions.items.len) {
                if (other.minions.items[j] == o.ref_id) _ = other.minions.orderedRemove(j) else j += 1;
            }
        }
        _ = s.motion.remove(o.ref_id);
        _ = w.objects.orderedRemove(i);
        o.deinit(s.gpa);
        s.gpa.destroy(o);
    }

    fn destroyObject(s: *Session, data: []const u8) Error!void {
        const size = @sizeOf(protocol.DestroyObject);
        if (data.len < size) return;
        const v = std.mem.bytesToValue(protocol.DestroyObject, data[0..size]);
        const n: usize = @intCast(@max(v.fire_missile_amount, 0));
        if (data.len != size + n * @sizeOf(protocol.FireMissileInfo)) return;
        const o = s.find(v.ref_id) orelse return;
        s.world.setHealth(o, 0);
        const missiles = try s.gpa.alloc(protocol.FireMissileInfo, n);
        for (missiles, std.mem.bytesAsSlice(protocol.FireMissileInfo, data[size..])) |*dst, src| dst.* = src;
        try s.emit(.{ .destroyed = .{
            .ref_id = v.ref_id,
            .killer = v.killer_ref_id,
            .fire_death = v.do_fire_death,
            .missile_death = v.do_missile_death,
            .destroy = v.destroy_object,
            .missiles = missiles,
        } });
    }

    /// OBJECT_GROUP_INFO: `ref_id, leader, count, ids...`, except that the
    /// original server wrote the ids from the count's slot on (see
    /// World.relayGroupInfo), so the count is derived from the size.
    fn groupInfo(s: *Session, data: []const u8) Error!void {
        if (data.len < 12 or data.len % 4 != 0) return;
        const ints = std.mem.bytesAsSlice(i32, data);
        const o = s.find(std.mem.littleToNative(i32, ints[0])) orelse return;
        const n = ints.len - 3;
        o.leader = if (s.find(std.mem.littleToNative(i32, ints[1])) != null) std.mem.littleToNative(i32, ints[1]) else null;
        o.minions.clearRetainingCapacity();
        for (ints[2 .. 2 + n]) |id| {
            const ref_id = std.mem.littleToNative(i32, id);
            if (s.find(ref_id) != null) try o.minions.append(s.gpa, ref_id);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a session follows a game on the Zig server" {
    const io = testing.io;
    const gpa = testing.allocator;
    const Server = @import("../server.zig").Server;
    var data = try std.Io.Dir.cwd().openDir(io, "bin", .{});
    defer data.close(io);

    const port = 18124;
    const server = try Server.init(gpa, io, data, .{
        .port = port,
        .map = "../Data/Campaing/Z_original/p02_bb_orig01.map",
        .settings = "default_settings.txt",
    });
    defer server.deinit();

    var s = Session.init(gpa, try Conn.connect("127.0.0.1", port), server.terrain, .{ .name = "zig", .team = .red });
    defer s.deinit();
    try s.start();

    var t: f64 = 0;
    for (0..60) |_| {
        try server.tick();
        t += 0.01;
        try s.update(t);
    }
    try testing.expect(s.map_loaded);
    try testing.expectEqual(k.Team.red, s.team);
    try testing.expect(s.id >= 0);
    try testing.expectEqual(server.world.objects.items.len, s.world.objects.items.len);
    try testing.expectEqualStrings(k.game_version, s.server_version.items);
    try testing.expect(s.players.items.len == 1);
    try testing.expectEqualStrings("zig", s.players.items[0].name.items);
    // Same objects in the same places.
    for (server.world.objects.items, s.world.objects.items) |a, b| {
        try testing.expectEqual(a.ref_id, b.ref_id);
        try testing.expectEqual(a.x, b.x);
        try testing.expectEqual(a.owner, b.owner);
        try testing.expectEqual(a.health, b.health);
    }
    for (server.world.zones.items, s.world.zones.items) |a, b| try testing.expectEqual(a.owner, b.owner);
}
