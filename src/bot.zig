//! A computer player (ZBot). It connects like any player, keeps the same
//! view of the game as the client (`Session`) and once a second of game
//! time sends its units after flags, empty vehicles, grenades, repair
//! stations and, when it holds its share of the map, the enemy; it also
//! keeps its factories building its favourite units.
//!
//! Only the C++ bot's third AI was in use; the two older ones are not
//! ported.

const std = @import("std");
const game = @import("game.zig");
const net = @import("net.zig");
const Session = @import("client/session.zig").Session;

const k = game.constants;
const Object = game.object.Object;
const Unit = game.buildlist.Unit;
const World = game.world.World;

/// What the factories build: the first of these their level allows.
const favourites = [_]Unit{
    .{ .kind = .vehicle, .id = @intFromEnum(k.Vehicle.medium) },
    .{ .kind = .vehicle, .id = @intFromEnum(k.Vehicle.light) },
    .{ .kind = .vehicle, .id = @intFromEnum(k.Vehicle.jeep) },
    .{ .kind = .robot, .id = @intFromEnum(k.Robot.pyro) },
    .{ .kind = .robot, .id = @intFromEnum(k.Robot.tough) },
    .{ .kind = .robot, .id = @intFromEnum(k.Robot.sniper) },
    .{ .kind = .robot, .id = @intFromEnum(k.Robot.psycho) },
};

pub const Bot = struct {
    gpa: std.mem.Allocator,
    session: Session,
    prng: std.Random.DefaultPrng,
    next_think: f64 = 0,
    last_orders: f64 = 0,

    /// Join the game at host:port for `team`.
    pub fn connect(gpa: std.mem.Allocator, host: [:0]const u8, port: u16, terrain: *const game.map.Terrain, team: k.Team, seed: u64) !*Bot {
        const conn = try net.conn.Conn.connect(host, port);
        const b = try gpa.create(Bot);
        b.* = .{
            .gpa = gpa,
            .session = Session.init(gpa, conn, terrain, .{ .name = "Bot", .team = team, .mode = .bot }),
            .prng = .init(seed),
        };
        errdefer b.deinit();
        try b.session.start();
        // Marks us as a bot (any data does for the Zig server).
        try b.session.send(.send_bot_bypass_data, "zig bot");
        b.session.conn.flush();
        return b;
    }

    pub fn deinit(b: *Bot) void {
        b.session.deinit();
        b.gpa.destroy(b);
    }

    pub fn connected(b: *const Bot) bool {
        return b.session.connected();
    }

    /// Read the network and, once a second of game time, think.
    pub fn update(b: *Bot, real_time: f64) !void {
        try b.session.update(real_time);
        b.session.clearEvents();
        const w = &b.session.world;
        const now = w.now();
        if (now < b.next_think) return;
        b.next_think = now + 1;
        if (w.map == null or b.session.team == .none or b.ignored()) return;
        try b.giveOrders(now);
        try b.chooseProduction();
        b.session.conn.flush();
    }

    fn ignored(b: *const Bot) bool {
        for (b.session.players.items) |p| if (p.id == b.session.id) return p.ignored;
        return false;
    }

    // -----------------------------------------------------------------------
    // Orders (ZBot::Stage1AI_3)
    // -----------------------------------------------------------------------

    const Plan = struct {
        /// Attack enemy units and forts too, not only take what's free.
        all_out: bool = false,
        /// Share of the idle units that get new orders each time.
        share: f64 = 0.35,
        /// Seconds between rounds of orders.
        delay: f64 = 4,
    };

    /// The more of the map we hold, the more we attack, and the calmer.
    fn plan(b: *const Bot) Plan {
        const w = &b.session.world;
        var owners: std.EnumSet(k.Team) = .initEmpty();
        var flags: usize = 0;
        var ours: usize = 0;
        for (w.objects.items) |o| if (o.isItem(.flag)) {
            owners.insert(o.owner);
            flags += 1;
            if (o.owner == b.session.team) ours += 1;
        };
        if (flags == 0) return .{ .all_out = true };
        const owned = @as(f64, @floatFromInt(ours)) / @as(f64, @floatFromInt(flags));
        const fair = 1 / @as(f64, @floatFromInt(owners.count()));
        if (owned >= fair) return .{ .all_out = true, .share = 0.15, .delay = 12 };
        if (owned >= fair * 0.5) return .{ .share = 0.15, .delay = 8 };
        if (owned >= fair * 0.25) return .{ .share = 0.25, .delay = 5 };
        return .{};
    }

    fn giveOrders(b: *Bot, now: f64) !void {
        const p = b.plan();
        if (now < b.last_orders + p.delay) return;
        b.last_orders = now;

        const gpa = b.gpa;
        var units: std.ArrayList(*Object) = .empty;
        defer units.deinit(gpa);
        var busy_with: std.ArrayList(*Object) = .empty;
        defer busy_with.deinit(gpa);
        var targets: std.ArrayList(*Object) = .empty;
        defer targets.deinit(gpa);
        try b.collectUnits(&units, &busy_with);
        try b.collectTargets(&targets, p.all_out);
        b.keepSome(&units, p.share);

        // Leave alone what others are already after, unless that is most.
        var fresh: std.ArrayList(*Object) = .empty;
        defer fresh.deinit(gpa);
        for (targets.items) |t| {
            if (std.mem.indexOfScalar(*Object, busy_with.items, t) == null) try fresh.append(gpa, t);
        }
        const use_fresh = fresh.items.len * 4 > targets.items.len;
        try b.assign(&units, if (use_fresh) fresh.items else targets.items);
        // Units left without a target try all of them.
        if (units.items.len > 0 and use_fresh and fresh.items.len != targets.items.len) try b.assign(&units, targets.items);
    }

    /// Our idle units, and what the busy ones are after.
    fn collectUnits(b: *const Bot, units: *std.ArrayList(*Object), busy_with: *std.ArrayList(*Object)) !void {
        const w = &b.session.world;
        for (w.objects.items) |o| {
            if (o.owner != b.session.team or !o.isMobile() or o.isDestroyed()) continue;
            // Squad members follow their leader.
            if (o.leader != null) continue;
            if (o.waypoints.items.len > 0) {
                const wp = o.waypoints.items[0];
                if (w.find(wp.ref_id)) |t| {
                    // Going to a flag that has become ours: free again.
                    if (t.isItem(.flag)) {
                        if (t.owner != b.session.team) {
                            try busy_with.append(b.gpa, t);
                            continue;
                        }
                    } else {
                        // Many may use a repair station at once.
                        if (!isBuilding(t, .repair)) try busy_with.append(b.gpa, t);
                        continue;
                    }
                }
                if (wp.mode == .dodge) continue;
            }
            try units.append(b.gpa, o);
        }
    }

    /// Everything worth going to.
    fn collectTargets(b: *const Bot, targets: *std.ArrayList(*Object), all_out: bool) !void {
        const team = b.session.team;
        for (b.session.world.objects.items) |t| {
            const enemy = t.owner != team and t.owner != .none and !t.isDestroyed();
            const wanted = switch (t.kind) {
                .item => (t.isItem(.flag) and t.owner != team) or t.isItem(.grenades),
                .building => |*bd| (bd.isFort() and enemy) or
                    (bd.type == .repair and t.owner == team and !t.isDestroyed()) or
                    t.canBeRepairedByCrane(team),
                .cannon, .vehicle => t.canBeEntered() or (all_out and enemy),
                .robot => all_out and enemy,
                else => false,
            };
            if (wanted) try targets.append(b.gpa, t);
        }
    }

    /// A random part of the units (at least one).
    fn keepSome(b: *Bot, units: *std.ArrayList(*Object), share: f64) void {
        if (share >= 0.95 or units.items.len <= 1) return;
        const n = units.items.len;
        const keep = @min(@as(usize, @intFromFloat(share * @as(f64, @floatFromInt(n)))) + 1, n);
        b.prng.random().shuffle(*Object, units.items);
        units.shrinkRetainingCapacity(keep);
    }

    /// Whether unit `u` would go for `t`.
    fn suits(b: *const Bot, u: *const Object, t: *const Object) bool {
        const w = &b.session.world;
        const team = b.session.team;
        const tp = if (t.kind == .building) [2]i32{ t.center_x, t.center_y } else [2]i32{ t.x + 8, t.y + 8 };
        if (w.grid) |*g| if (!g.inSameRegion(u.x + 8, u.y + 8, tp[0], tp[1], u.isRobot())) return false;
        return switch (t.kind) {
            .item => (t.isItem(.flag) and t.owner != team) or (t.isItem(.grenades) and u.canPickupGrenades()),
            .building => |*bd| (bd.isFort() and t.owner != team and t.owner != .none and !t.isDestroyed()) or
                (bd.type == .repair and t.owner == team and !t.isDestroyed() and u.canBeRepaired()) or
                (t.canBeRepairedByCrane(team) and u.isVehicle(.crane)),
            .cannon, .vehicle => if (t.canBeEntered()) u.isRobot() else game.sim.canAttackObject(w, u, t),
            .robot => game.sim.canAttackObject(w, u, t),
            else => false,
        };
    }

    /// Pair units and targets that are each other's nearest (among those
    /// that suit each other), round after round, and send the orders.
    /// Units that got orders leave `units`.
    fn assign(b: *Bot, units: *std.ArrayList(*Object), targets: []const *Object) !void {
        const n = units.items.len;
        const m = targets.len;
        if (n == 0 or m == 0) return;
        const gpa = b.gpa;
        // Which targets each unit considers, and which units each target
        // still considers; a unit whose targets all got taken falls back
        // to all of its original ones.
        const suit = try gpa.alloc(bool, n * m);
        defer gpa.free(suit);
        const unit_wants = try gpa.alloc(bool, n * m);
        defer gpa.free(unit_wants);
        const target_wants = try gpa.alloc(bool, n * m);
        defer gpa.free(target_wants);
        for (units.items, 0..) |u, i| for (targets, 0..) |t, j| {
            suit[i * m + j] = b.suits(u, t);
        };
        @memcpy(unit_wants, suit);
        @memcpy(target_wants, suit);
        const done = try gpa.alloc(bool, n);
        defer gpa.free(done);
        @memset(done, false);

        while (true) {
            var progress = false;
            for (units.items, 0..) |u, i| {
                if (done[i]) continue;
                const row = unit_wants[i * m ..][0..m];
                if (std.mem.indexOfScalar(bool, row, true) == null) @memcpy(row, suit[i * m ..][0..m]);
                const j = nearest(u, targets, row) orelse {
                    // Nothing for this one.
                    done[i] = true;
                    for (0..m) |jj| target_wants[i * m + jj] = false;
                    progress = true;
                    continue;
                };
                // Is it the target's nearest too?
                var best: ?usize = null;
                var best_d: f64 = 0;
                for (units.items, 0..) |other, ii| {
                    if (done[ii] or !target_wants[ii * m + j]) continue;
                    const d = targets[j].distanceToObject(other);
                    if (best == null or d < best_d) {
                        best = ii;
                        best_d = d;
                    }
                }
                if (best != null and best.? != i) continue;
                try b.order(u, targets[j]);
                done[i] = true;
                progress = true;
                for (0..m) |jj| target_wants[i * m + jj] = false;
                for (0..n) |ii| unit_wants[ii * m + j] = false;
            }
            if (!progress) break;
        }
        // Keep the units that got nothing.
        var kept: usize = 0;
        for (units.items, 0..) |u, i| if (!done[i]) {
            units.items[kept] = u;
            kept += 1;
        };
        units.shrinkRetainingCapacity(kept);
    }

    fn nearest(u: *const Object, targets: []const *Object, allowed: []const bool) ?usize {
        var best: ?usize = null;
        var best_d: f64 = 0;
        for (targets, allowed, 0..) |t, ok, j| {
            if (!ok) continue;
            const d = u.distanceToObject(t);
            if (best == null or d < best_d) {
                best = j;
                best_d = d;
            }
        }
        return best;
    }

    /// Send `u` to do what fits `t`.
    fn order(b: *Bot, u: *const Object, t: *const Object) !void {
        const w = &b.session.world;
        const team = b.session.team;
        const mode: game.object.WaypointMode = switch (t.kind) {
            .item => if (t.isItem(.flag) and t.owner != team) .move else if (t.isItem(.grenades)) .pickup_grenades else return,
            .building => |*bd| if (t.canBeRepairedByCrane(team))
                .crane_repair
            else if (bd.isFort() and t.owner != team and t.owner != .none and !t.isDestroyed())
                .enter_fort
            else if (bd.type == .repair and t.owner == team and !t.isDestroyed())
                .unit_repair
            else
                return,
            .cannon, .vehicle => if (t.owner == .none and !t.isDestroyed())
                .enter
            else if (game.sim.canAttackObject(w, u, t)) .attack else return,
            .robot => if (game.sim.canAttackObject(w, u, t)) .attack else return,
            else => return,
        };
        const at = if (mode == .attack) [2]i32{ t.x + 8, t.y + 8 } else [2]i32{ t.center_x, t.center_y };
        const wp: game.object.Waypoint = .{ .mode = mode, .ref_id = t.ref_id, .x = at[0], .y = at[1], .attack_to = true, .player_given = true };
        try b.session.sendWaypoints(u.ref_id, &.{wp}, false);
    }

    // -----------------------------------------------------------------------
    // Production (ZBot::ChooseBuildOrders)
    // -----------------------------------------------------------------------

    fn chooseProduction(b: *Bot) !void {
        const P = net.protocol;
        for (b.session.world.objects.items) |o| {
            if (o.owner != b.session.team) continue;
            const bd = switch (o.kind) {
                .building => |*bd| bd,
                else => continue,
            };
            if (!bd.producesUnits()) continue;
            const want = for (favourites) |f| {
                if (game.buildlist.contains(bd.type, bd.level, f)) break f;
            } else continue;
            if (bd.unit) |cur| if (cur.kind == want.kind and cur.id == want.id) continue;
            try b.session.sendPacket(.stop_building, P.Int{ .value = o.ref_id });
            try b.session.sendPacket(.start_building, P.StartBuilding{ .ref_id = o.ref_id, .ot = @intFromEnum(want.kind), .oid = want.id });
        }
    }
};

fn isBuilding(o: *const Object, t: k.Building) bool {
    return switch (o.kind) {
        .building => |bd| bd.type == t,
        else => false,
    };
}

test "a bot plays against a server" {
    const testing = std.testing;
    const Server = @import("server/server.zig").Server;
    const gpa = testing.allocator;
    const io = testing.io;
    var data = std.Io.Dir.cwd().openDir(io, "bin", .{}) catch return error.SkipZigTest;
    defer data.close(io);
    const port: u16 = 18_431;
    const server = try Server.init(gpa, io, data, .{
        .port = port,
        .map = "../Data/Campaing/Z_original/p02_bb_orig01.map",
        .settings = "default_settings.txt",
    });
    defer server.deinit();
    try server.unpause();
    const bot = try Bot.connect(gpa, "localhost", port, server.terrain, .blue, 1);
    defer bot.deinit();

    // It gives orders after a few seconds.
    var orders_seen = false;
    var t: usize = 0;
    while (t < 1500 and !orders_seen) : (t += 1) {
        try server.tick();
        try bot.update(server.realTime());
        for (server.world.objects.items) |o| {
            if (o.owner == .blue and o.isMobile() and o.waypoints.items.len > 0) orders_seen = true;
        }
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(bot.session.team == .blue);
    try testing.expect(orders_seen);
    // Its fort builds its favourite.
    var building = false;
    for (server.world.objects.items) |o| if (o.owner == .blue and o.isFort()) if (o.building().?.unit != null) {
        building = true;
    };
    try testing.expect(building);
}
