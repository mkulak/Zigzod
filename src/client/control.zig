//! The player's control over their units (the selection and order parts
//! of ZPlayer): selecting units with the mouse, control groups, what the
//! mouse is over, giving orders, and drawing selections and routes.

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const font = @import("font.zig");
const cursor = @import("cursor.zig");
const Session = @import("session.zig").Session;

const k = game.constants;
const protocol = @import("../net/protocol.zig");
const Object = game.object.Object;
const World = game.world.World;
const Waypoint = protocol.Waypoint;
const Canvas = gfx.Canvas;
const Rect = gfx.Rect;

/// What the selected units can do together (selection_info).
pub const Abilities = struct {
    have_explosives: bool = false,
    can_pickup_grenades: bool = false,
    can_move: bool = false,
    can_equip: bool = false,
    can_attack: bool = false,
    can_repair: bool = false,
    can_be_repaired: bool = false,
};

/// The object the mouse is over, if it can be targeted there.
pub const Hover = struct {
    id: i32,
    /// Over the part of a fort robots can walk into.
    enter_fort: bool,
};

pub const UnitKind = enum { robot, vehicle, cannon };

/// Something to look at with the space bar (SpaceBarEvent).
pub const Notice = struct {
    id: i32,
    /// Select it when jumping there.
    select: bool = false,
    /// Open its window (new guns go into place from there).
    open_gui: bool = false,
    time: f64 = 0,

    const max = 5;
    const lifetime = 10;

    fn same(a: Notice, b: Notice) bool {
        return a.id == b.id and a.select == b.select and a.open_gui == b.open_gui;
    }
};

pub const Control = struct {
    gpa: std.mem.Allocator,
    team: k.Team = .none,
    selected: std.ArrayList(i32) = .empty,
    groups: [10]std.ArrayList(i32) = @splat(.empty),
    abilities: Abilities = .{},
    /// The unit the HUD shows.
    hud_unit: ?i32 = null,
    hover: ?Hover = null,
    /// Orders collected while shift is held (sent when it is released).
    pending: std.AutoHashMapUnmanaged(i32, std.ArrayList(Waypoint)) = .empty,
    /// Routes of the selected units show for a while after selecting or
    /// ordering.
    show_routes_until: f64 = 0,
    /// Where the last order went.
    marker: ?struct { kind: cursor.Kind, x: i32, y: i32, until: f64 } = null,
    /// Selecting the next unit of a kind cycles for a while, then starts
    /// with the one nearest the mouse again.
    cycle: [3]struct { last: i32 = -1, time: f64 = -100 } = @splat(.{}),
    /// Recent happenings the space bar jumps to, newest first.
    notices: std.ArrayList(Notice) = .empty,

    pub fn init(gpa: std.mem.Allocator) Control {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Control) void {
        c.selected.deinit(c.gpa);
        for (&c.groups) |*g| g.deinit(c.gpa);
        c.clearPending();
        c.pending.deinit(c.gpa);
        c.notices.deinit(c.gpa);
    }

    /// A new game or team: forget everything.
    pub fn reset(c: *Control, team: k.Team) void {
        c.team = team;
        c.selected.clearRetainingCapacity();
        for (&c.groups) |*g| g.clearRetainingCapacity();
        c.clearPending();
        c.abilities = .{};
        c.hud_unit = null;
        c.hover = null;
        c.marker = null;
        c.notices.clearRetainingCapacity();
    }

    /// Remember something the space bar can jump to.
    pub fn notice(c: *Control, n: Notice) void {
        var i: usize = 0;
        while (i < c.notices.items.len) {
            if (c.notices.items[i].same(n)) _ = c.notices.orderedRemove(i) else i += 1;
        }
        c.notices.insert(c.gpa, 0, n) catch return;
        if (c.notices.items.len > Notice.max) c.notices.shrinkRetainingCapacity(Notice.max);
    }

    /// The next notice to look at (it goes to the back of the list);
    /// stale ones are dropped. `real_time` is the notices' clock.
    pub fn nextNotice(c: *Control, world: *const World, real_time: f64, rng: std.Random) ?*Object {
        while (c.notices.items.len > 0) {
            const n = c.notices.orderedRemove(0);
            const obj = world.find(n.id) orelse continue;
            if (real_time > n.time + Notice.lifetime) continue;
            const o = world.findOpt(obj.leader) orelse obj;
            if (n.select and !c.isSelected(o.ref_id)) c.select(world, o.ref_id, rng);
            c.notices.append(c.gpa, n) catch {};
            return o;
        }
        return null;
    }

    fn clearPending(c: *Control) void {
        var it = c.pending.valueIterator();
        while (it.next()) |l| l.deinit(c.gpa);
        c.pending.clearRetainingCapacity();
    }

    pub fn isSelected(c: *const Control, id: i32) bool {
        return std.mem.indexOfScalar(i32, c.selected.items, id) != null;
    }

    /// An object is gone (or no longer ours).
    pub fn forget(c: *Control, id: i32) void {
        remove(&c.selected, id);
        for (&c.groups) |*g| remove(g, id);
        if (c.pending.fetchRemove(id)) |kv| {
            var l = kv.value;
            l.deinit(c.gpa);
        }
        if (c.hud_unit == id) c.hud_unit = null;
        if (c.hover) |h| if (h.id == id) {
            c.hover = null;
        };
    }

    fn remove(list: *std.ArrayList(i32), id: i32) void {
        if (std.mem.indexOfScalar(i32, list.items, id)) |i| _ = list.orderedRemove(i);
    }

    // -----------------------------------------------------------------------
    // Selecting
    // -----------------------------------------------------------------------

    fn selectable(c: *const Control, o: *const Object) bool {
        return o.selectable and o.leader == null and o.owner == c.team and c.team != .none;
    }

    /// Recompute what the selection can do, show its routes, pick the unit
    /// the HUD shows (SetupGroupDetails + GiveHudSelected).
    fn selectionChanged(c: *Control, world: *const World, rng: std.Random) void {
        var a: Abilities = .{};
        for (c.selected.items) |id| {
            const o = world.find(id) orelse continue;
            switch (o.kind) {
                .robot => a.can_equip = true,
                .vehicle => |v| if (v.type == .crane) {
                    a.can_repair = true;
                },
                else => {},
            }
            if (o.kind != .cannon) a.can_move = true;
            if (o.hasExplosives(world.findOpt(o.leader))) a.have_explosives = true;
            if (o.canAttack()) a.can_attack = true;
            if (o.canBeRepaired()) a.can_be_repaired = true;
            if (o.canPickupGrenades()) a.can_pickup_grenades = true;
        }
        c.abilities = a;
        c.show_routes_until = world.now() + 3;
        // The HUD keeps showing its unit while it stays selected.
        if (c.hud_unit) |id| if (c.isSelected(id)) return;
        c.hud_unit = if (c.selected.items.len > 0) c.selected.items[rng.uintLessThan(usize, c.selected.items.len)] else null;
    }

    pub fn clear(c: *Control, world: *const World, rng: std.Random) void {
        c.selected.clearRetainingCapacity();
        c.selectionChanged(world, rng);
    }

    /// Select one object (its group's leader if it follows one).
    pub fn select(c: *Control, world: *const World, id: i32, rng: std.Random) void {
        var o = world.find(id) orelse return;
        if (world.findOpt(o.leader)) |l| o = l;
        if (!c.selectable(o)) return;
        c.dropPendingOfSelected();
        c.selected.clearRetainingCapacity();
        c.selected.append(c.gpa, o.ref_id) catch return;
        c.selectionChanged(world, rng);
    }

    /// The units in the box between two map points; a click (a tiny box)
    /// picks one unit there, or its leader (CollectSelectables).
    pub fn selectBox(c: *Control, world: *const World, x0: i32, y0: i32, x1: i32, y1: i32, rng: std.Random) void {
        const left = @min(x0, x1);
        const right = @max(x0, x1);
        const top = @min(y0, y1);
        const bottom = @max(y0, y1);
        c.dropPendingOfSelected();
        c.selected.clearRetainingCapacity();
        const single = right - left <= 1 and bottom - top <= 1;
        for (world.objects.items) |obj| {
            if (obj.owner != c.team) continue;
            if (!obj.withinSelection(left, right, top, bottom)) continue;
            const o = if (single) world.findOpt(obj.leader) orelse obj else obj;
            if (!c.selectable(o) or c.isSelected(o.ref_id)) continue;
            c.selected.append(c.gpa, o.ref_id) catch break;
        }
        if (single and c.selected.items.len > 1) {
            // Several overlap: take one of them.
            const pick = c.selected.items[rng.uintLessThan(usize, c.selected.items.len)];
            c.selected.clearRetainingCapacity();
            c.selected.appendAssumeCapacity(pick);
        }
        c.selectionChanged(world, rng);
    }

    fn unitKind(o: *const Object) ?UnitKind {
        return switch (o.kind) {
            .robot => .robot,
            .vehicle => .vehicle,
            .cannon => .cannon,
            else => null,
        };
    }

    /// All our units of a kind (robots and vehicles for null).
    pub fn selectAll(c: *Control, world: *const World, kind: ?UnitKind, rng: std.Random) void {
        c.dropPendingOfSelected();
        c.selected.clearRetainingCapacity();
        for (world.objects.items) |o| {
            const uk = unitKind(o) orelse continue;
            if (kind) |want| {
                if (uk != want) continue;
            } else if (uk == .cannon) continue;
            if (!c.selectable(o)) continue;
            c.selected.append(c.gpa, o.ref_id) catch break;
        }
        c.selectionChanged(world, rng);
    }

    /// Select the next unit of a kind; the first time (or after a pause)
    /// the one nearest to (x, y). Returns it to look at
    /// (OrderlySelectUnitType).
    pub fn selectNext(c: *Control, world: *const World, kind: UnitKind, x: i32, y: i32, real_time: f64, rng: std.Random) ?*Object {
        if (c.team == .none) return null;
        const cy = &c.cycle[@intFromEnum(kind)];
        var choice: ?*Object = null;
        if (real_time - cy.time < 7) {
            // Lowest id above the last one, wrapping around.
            var first: ?*Object = null;
            for (world.objects.items) |o| {
                if (unitKind(o) != kind or !c.selectable(o)) continue;
                if (first == null) first = o;
                if (o.ref_id > cy.last and choice == null) choice = o;
            }
            if (choice == null) choice = first;
        } else {
            var best: f64 = std.math.inf(f64);
            for (world.objects.items) |o| {
                if (unitKind(o) != kind or !c.selectable(o)) continue;
                const d = o.distanceTo(x, y);
                if (d < best) {
                    best = d;
                    choice = o;
                }
            }
        }
        const o = choice orelse return null;
        c.select(world, o.ref_id, rng);
        cy.last = o.ref_id;
        cy.time = real_time;
        return o;
    }

    /// Ctrl+number: remember the selection as a group.
    pub fn setGroup(c: *Control, n: usize) void {
        c.groups[n].clearRetainingCapacity();
        c.groups[n].appendSlice(c.gpa, c.selected.items) catch {};
    }

    /// Number: select the group; if it already is selected, return where
    /// it is to look there (LoadControlGroup).
    pub fn loadGroup(c: *Control, world: *const World, n: usize, rng: std.Random) ?[2]i32 {
        const g = c.groups[n].items;
        if (g.len > 0 and std.mem.eql(i32, g, c.selected.items)) {
            var sx: i64 = 0;
            var sy: i64 = 0;
            var count: i64 = 0;
            for (g) |id| if (world.find(id)) |o| {
                sx += o.center_x;
                sy += o.center_y;
                count += 1;
            };
            if (count == 0) return null;
            return .{ @intCast(@divTrunc(sx, count)), @intCast(@divTrunc(sy, count)) };
        }
        c.dropPendingOfSelected();
        c.selected.clearRetainingCapacity();
        c.selected.appendSlice(c.gpa, g) catch {};
        c.selectionChanged(world, rng);
        return null;
    }

    /// Lowest control group a unit is in (shown next to it).
    fn groupOf(c: *const Control, id: i32) ?usize {
        for (c.groups, 0..) |g, i| {
            if (std.mem.indexOfScalar(i32, g.items, id) != null) return i;
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // What the mouse is over
    // -----------------------------------------------------------------------

    /// Forts can only be attacked on their walls and entered through the
    /// gate; bridges only at their ends (unless destroyed).
    fn targetableAt(o: *const Object, x: i32, y: i32) struct { attack: bool, enter_fort: bool } {
        const rx = x - o.x;
        const ry = y - o.y;
        const in = struct {
            fn f(px: i32, py: i32, ax: i32, ay: i32, w: i32, h: i32) bool {
                return px >= ax and py >= ay and px <= ax + w and py <= ay + h;
            }
        }.f;
        const t = 16;
        const b = switch (o.kind) {
            .building => |b| b,
            else => return .{ .attack = true, .enter_fort = false },
        };
        return switch (b.type) {
            .fort_front, .fort_back => .{
                .attack = in(rx, ry, t, t, t * 8, t * 7) or in(rx, ry, 0, t * 3, t * 10, t * 4) or
                    in(rx, ry, t, 0, t * 2, t) or in(rx, ry, t * 7, 0, t * 2, t) or
                    in(rx, ry, t * 2, t * 8, t, t) or in(rx, ry, t * 7, t * 8, t, t),
                .enter_fort = if (b.type == .fort_front) in(rx, ry, t * 4, t * 2, 32, t * 6) else in(rx, ry, t * 4, t, 32, t * 4),
            },
            .bridge_vert => .{ .attack = o.isDestroyed() or in(rx, ry, 0, 0, t, o.height_pix) or in(rx, ry, t * 3, 0, t, o.height_pix), .enter_fort = false },
            .bridge_horz => .{ .attack = o.isDestroyed() or in(rx, ry, 0, 0, o.width_pix, t) or in(rx, ry, 0, t * 3, o.width_pix, t), .enter_fort = false },
            else => .{ .attack = true, .enter_fort = false },
        };
    }

    /// Find what is under map point (x, y) (the last one drawn wins).
    pub fn updateHover(c: *Control, world: *const World, x: i32, y: i32) void {
        c.hover = null;
        for (world.objects.items) |o| {
            if (!o.underPoint(x, y)) continue;
            const t = targetableAt(o, x, y);
            if (!t.attack and !t.enter_fort) continue;
            c.hover = .{ .id = o.ref_id, .enter_fort = t.enter_fort };
        }
    }

    /// The cursor for the mouse's position (DetermineCursor).
    pub fn cursorKind(c: *const Control, world: *const World, selecting: bool) cursor.Kind {
        if (selecting or c.selected.items.len == 0) return .cursor;
        const a = c.abilities;
        const h = c.hover orelse return if (a.can_move) .place else .cannon;
        const o = world.find(h.id) orelse return if (a.can_move) .place else .cannon;
        if (a.can_repair and o.canBeRepairedByCrane(c.team)) return .repair;
        if (a.can_be_repaired and o.canRepairUnit(c.team)) return .repair;
        if (o.owner == c.team) {
            // Clicking a lone APC or cannon lets its drivers out.
            if (o.canEjectDrivers() and c.selected.items.len == 1 and c.isSelected(o.ref_id)) return .exit;
            return .place;
        }
        const is_flag = o.kind == .item and o.kind.item == .flag;
        if (a.can_move) {
            if (o.kind == .item and o.kind.item == .grenades and a.can_pickup_grenades) return .grab;
            if (is_flag) return .grab;
            if ((o.kind == .cannon or o.kind == .vehicle) and o.owner == .none and a.can_equip) return .enter;
        } else if (is_flag) return .cannon;
        if (h.enter_fort) return .place;
        if (!a.can_attack or (!a.have_explosives and o.attacked_by_explosives)) return .nono;
        return .attack;
    }

    // -----------------------------------------------------------------------
    // Orders
    // -----------------------------------------------------------------------

    /// Forget orders not sent yet.
    pub fn forgetOrders(c: *Control) void {
        c.dropPendingOfSelected();
    }

    fn dropPendingOfSelected(c: *Control) void {
        for (c.selected.items) |id| if (c.pending.fetchRemove(id)) |kv| {
            var l = kv.value;
            l.deinit(c.gpa);
        };
    }

    pub const OrderOptions = struct {
        /// The point came from the minimap: never targets an object.
        from_minimap: bool = false,
        /// Ctrl: attack whatever is met on the way.
        attack_to: bool = false,
        /// Alt: just go there.
        no_attack_to: bool = false,
    };

    /// Enemies close enough to fight? Then a move order is just a move.
    fn nearHostiles(world: *const World, o: *const Object) bool {
        for (world.objects.items) |e| {
            if (e == o or e.owner == o.owner or e.owner == .none or e.isDestroyed()) continue;
            if (!e.isUnit()) continue;
            if (game.sim.withinAgroRadius(world, o, e)) return true;
        }
        return false;
    }

    /// Right click at map point (x, y): add an order for every selected
    /// unit, depending on what is there (AddDevWayPointToSelected).
    pub fn addOrder(c: *Control, world: *const World, x: i32, y: i32, opt: OrderOptions) void {
        const target = if (opt.from_minimap) null else if (c.hover) |h| world.find(h.id) else null;
        for (c.selected.items) |id| {
            const o = world.find(id) orelse continue;
            var wp: Waypoint = .{ .mode = .move, .ref_id = -1, .x = x, .y = y, .attack_to = true, .player_given = true };
            if (nearHostiles(world, o)) wp.attack_to = false;
            if (opt.attack_to) wp.attack_to = true;
            if (opt.no_attack_to) wp.attack_to = false;
            if (target) |t| {
                wp.ref_id = t.ref_id;
                orderAt(c, o, t, &wp);
            }
            const gop = c.pending.getOrPut(c.gpa, id) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(c.gpa, wp) catch {};
        }
    }

    /// What a unit does when sent to object `t`.
    fn orderAt(c: *const Control, o: *const Object, t: *const Object, wp: *Waypoint) void {
        const enemy = t.owner != c.team;
        const is_flag = t.kind == .item and t.kind.item == .flag;
        const enter_fort = if (c.hover) |h| h.id == t.ref_id and h.enter_fort else false;
        if (o.canBeRepaired() and t.canRepairUnit(c.team)) {
            wp.mode = .unit_repair;
            wp.x = t.center_x - 8;
            wp.y = t.center_y;
            return;
        }
        if (is_flag) return;
        switch (o.kind) {
            .cannon => if (enemy) {
                wp.mode = .attack;
            },
            .vehicle => |v| {
                if (v.type == .crane and t.canBeRepairedByCrane(c.team)) {
                    wp.mode = .crane_repair;
                    if (t.craneCenter()) |p| {
                        wp.x = p.x;
                        wp.y = p.y;
                    }
                } else if (enter_fort) {
                    wp.mode = .enter_fort;
                } else if (enemy) wp.mode = .attack;
            },
            .robot => {
                if (t.kind == .item and t.kind.item == .grenades and o.canPickupGrenades()) {
                    wp.mode = .pickup_grenades;
                } else if (t.owner == .none and (t.kind == .cannon or t.kind == .vehicle)) {
                    wp.mode = .enter;
                } else if (enter_fort) {
                    wp.mode = .enter_fort;
                } else if (enemy) wp.mode = .attack;
            },
            else => {},
        }
    }

    /// Send the collected orders. With `nearest_only` only the unit closest
    /// to the first order's spot goes, and leaves the selection. Returns
    /// where to show the order marker.
    pub fn sendOrders(c: *Control, session: *Session, nearest_only: bool, rng: std.Random) !void {
        const world = &session.world;
        if (c.selected.items.len == 0) return;
        var marker_at: ?Waypoint = null;
        const first_list = c.pending.get(c.selected.items[0]);
        if (first_list) |l| if (l.items.len > 0) {
            marker_at = l.items[l.items.len - 1];
        };
        if (nearest_only) {
            const wp = (first_list orelse return).items[0];
            var best: ?*Object = null;
            var best_d: f64 = std.math.inf(f64);
            for (c.selected.items) |id| if (world.find(id)) |o| {
                const d = o.distanceTo(wp.x, wp.y);
                if (d < best_d) {
                    best_d = d;
                    best = o;
                }
            };
            if (best) |o| {
                if (c.pending.get(o.ref_id)) |l| try session.sendWaypoints(o.ref_id, l.items, false);
                c.dropPendingOfSelected();
                remove(&c.selected, o.ref_id);
                c.selectionChanged(world, rng);
            }
        } else {
            for (c.selected.items) |id| {
                if (c.pending.get(id)) |l| try session.sendWaypoints(id, l.items, false);
            }
            c.dropPendingOfSelected();
        }
        if (marker_at) |m| {
            c.marker = .{ .kind = c.markerKind(world, m), .x = markerX(world, m)[0], .y = markerX(world, m)[1], .until = world.now() + 3 };
        }
        c.show_routes_until = world.now() + 3;
    }

    fn markerKind(_: *const Control, world: *const World, wp: Waypoint) cursor.Kind {
        return switch (wp.mode) {
            .attack, .agro => if (world.find(wp.ref_id) != null) .attacked else .placed,
            .pickup_grenades => .grabbed,
            .enter => .entered,
            .crane_repair, .unit_repair => .repaired,
            else => .placed,
        };
    }

    /// Where an order points (attacks follow their target).
    fn markerX(world: *const World, wp: Waypoint) [2]i32 {
        if (wp.mode == .attack or wp.mode == .agro) if (world.find(wp.ref_id)) |t| return .{ t.center_x, t.center_y };
        return .{ wp.x, wp.y };
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    /// Routes of the selected units (orders given and being given), under
    /// the objects.
    pub fn drawRoutes(c: *const Control, cv: Canvas, world: *const World, cursors: *const cursor.Cursors, time: f64) void {
        const phase: f64 = @floor(@mod(time / 0.1, 4));
        for (c.selected.items) |id| {
            const o = world.find(id) orelse continue;
            const pending = if (c.pending.get(id)) |l| l.items else &.{};
            if (time >= c.show_routes_until and pending.len == 0) continue;
            var from: [2]i32 = .{ o.center_x, o.center_y };
            var last: ?Waypoint = null;
            for ([_][]const Waypoint{ o.waypoints.items, pending }) |list| for (list) |wp| {
                const to = markerX(world, wp);
                dottedLine(cv, from, to, phase);
                from = to;
                last = wp;
            };
            if (last) |wp| {
                const at = markerX(world, wp);
                cursors.draw(cv, c.markerKind(world, wp), c.team, time, at[0], at[1]);
            }
        }
        if (c.marker) |m| if (time < m.until) cursors.draw(cv, m.kind, c.team, time, m.x, m.y);
    }

    fn dottedLine(cv: Canvas, from: [2]i32, to: [2]i32, phase: f64) void {
        const dx: f64 = @floatFromInt(to[0] - from[0]);
        const dy: f64 = @floatFromInt(to[1] - from[1]);
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < 1) return;
        const sx = 4 * dx / dist;
        const sy = 4 * dy / dist;
        var x = @as(f64, @floatFromInt(from[0])) + sx * phase / 4;
        var y = @as(f64, @floatFromInt(from[1])) + sy * phase / 4;
        var n: usize = @intFromFloat(dist / 4 + 1);
        if (phase > 0) n -= 1;
        for (0..n) |_| {
            cv.fill(.{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = 2, .h = 2 }, .{ .r = 170, .g = 170, .b = 170 });
            x += sx;
            y += sy;
        }
    }

    /// Corner brackets, health bars, group numbers and attack ranges of
    /// the selected units (RenderSelection, RenderAttackRadius).
    pub fn drawSelection(c: *const Control, cv: Canvas, world: *const World, palettes: *const gfx.TeamPalettes, fonts: *const font.Fonts, time: f64) void {
        for (c.selected.items) |id| {
            const o = world.find(id) orelse continue;
            const col = palettes.color(o.owner);
            brackets(cv, .{ .x = o.x, .y = o.y, .w = o.width_pix, .h = o.height_pix }, col);
            if (c.groupOf(id)) |g| {
                var buf: [2]u8 = undefined;
                fonts.get(.small_white).draw(cv, std.fmt.bufPrint(&buf, "{d}", .{g}) catch "", o.x - 2, o.y - 3);
            }
            healthBar(cv, o);
            c.attackRange(cv, world, o, col, time);
        }
    }

    fn brackets(cv: Canvas, r0: Rect, col: gfx.Color) void {
        const pad = 3;
        const len = 5;
        const r: Rect = .{ .x = r0.x - pad, .y = r0.y - pad, .w = r0.w + 2 * pad, .h = r0.h + 2 * pad };
        const x1 = r.x + r.w;
        const y1 = r.y + r.h;
        for ([_]Rect{
            .{ .x = r.x, .y = r.y, .w = len, .h = 1 },         .{ .x = r.x, .y = r.y, .w = 1, .h = len },
            .{ .x = x1 - len, .y = r.y, .w = len, .h = 1 },    .{ .x = x1 - 1, .y = r.y, .w = 1, .h = len },
            .{ .x = r.x, .y = y1 - 1, .w = len, .h = 1 },      .{ .x = r.x, .y = y1 - len, .w = 1, .h = len },
            .{ .x = x1 - len, .y = y1 - 1, .w = len, .h = 1 }, .{ .x = x1 - 1, .y = y1 - len, .w = 1, .h = len },
        }) |line| cv.fill(line, col);
    }

    /// Green health, yellow what can be repaired, on black.
    fn healthBar(cv: Canvas, o: *const Object) void {
        const max_dist = 36;
        const green: i32 = @max(@divTrunc(max_dist * o.health, k.max_unit_health), 1);
        const yellow: i32 = @max(@divTrunc(max_dist * o.max_health, k.max_unit_health), 1);
        const x = o.x - 3;
        const y = o.y - 8;
        cv.fill(.{ .x = x, .y = y, .w = yellow + 2, .h = 4 }, .{ .r = 0, .g = 0, .b = 0 });
        cv.fill(.{ .x = x + 1, .y = y + 1, .w = green, .h = 2 }, .{ .r = 82, .g = 190, .b = 33 });
        if (yellow > green) cv.fill(.{ .x = x + 1 + green, .y = y + 1, .w = yellow - green, .h = 2 }, .{ .r = 247, .g = 203, .b = 107 });
    }

    /// Slowly turning dots on the attack range, left out where another
    /// selected unit's range covers it.
    fn attackRange(c: *const Control, cv: Canvas, world: *const World, o: *const Object, col: gfx.Color, time: f64) void {
        if (o.attack_radius == 0) return;
        const dots = 10;
        const step = (std.math.pi / 2.0) / @as(f64, dots);
        const start = @mod(time * step, step);
        const r: f64 = @floatFromInt(o.attack_radius + 3);
        for (0..dots) |i| {
            const a = start + step * @as(f64, @floatFromInt(i));
            if (a > std.math.pi / 2.0) break;
            const mx: i32 = @intFromFloat(r * @sin(a));
            const my: i32 = @intFromFloat(r * @cos(a));
            for ([_][2]i32{ .{ mx, my }, .{ -mx, -my }, .{ -mx, my }, .{ mx, -my } }) |d| {
                const px = o.center_x + d[0];
                const py = o.center_y + d[1];
                if (c.coveredByOther(world, o, px, py)) continue;
                cv.fill(.{ .x = px, .y = py, .w = 2, .h = 2 }, col);
            }
        }
    }

    fn coveredByOther(c: *const Control, world: *const World, o: *const Object, x: i32, y: i32) bool {
        for (c.selected.items) |id| {
            if (id == o.ref_id) continue;
            const other = world.find(id) orelse continue;
            const dx: i64 = other.center_x - x;
            const dy: i64 = other.center_y - y;
            const r: i64 = other.attack_radius;
            if (dx * dx + dy * dy <= r * r) return true;
        }
        return false;
    }
};

/// The rubber band while dragging a selection: marching dots in the
/// team's color, darkened a little.
pub fn drawSelectionBox(cv: Canvas, palettes: *const gfx.TeamPalettes, team: k.Team, x0: i32, y0: i32, x1: i32, y1: i32, time: f64) void {
    const base = palettes.color(team);
    const col: gfx.Color = .{ .r = base.r - base.r / 5, .g = base.g - base.g / 5, .b = base.b - base.b / 5 };
    const shift: i32 = @intFromFloat(@mod(@floor(time / 0.1), 4));
    const left = @min(x0, x1);
    const right = @max(x0, x1);
    const top = @min(y0, y1);
    const bottom = @max(y0, y1);
    var x = left + (4 - shift);
    while (x < right) : (x += 4) cv.fill(.{ .x = x, .y = top, .w = 2, .h = 2 }, col);
    x = left + shift;
    while (x < right) : (x += 4) cv.fill(.{ .x = x, .y = bottom, .w = 2, .h = 2 }, col);
    var y = top + shift;
    while (y < bottom) : (y += 4) cv.fill(.{ .x = left, .y = y, .w = 2, .h = 2 }, col);
    y = top + (4 - shift);
    while (y < bottom) : (y += 4) cv.fill(.{ .x = right, .y = y, .w = 2, .h = 2 }, col);
}

test "select, group and order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var assets = try std.Io.Dir.cwd().openDir(io, "bin/assets", .{});
    defer assets.close(io);
    const terrain = try gpa.create(game.map.Terrain);
    defer gpa.destroy(terrain);
    terrain.* = try game.map.Terrain.load(io, assets);
    var world = World.init(gpa, terrain, 1);
    defer world.deinit();
    const grunt = @intFromEnum(k.Robot.grunt);
    const a = (try world.createObject(.robot, grunt, 100, 100, .red, .direct, .{})).?;
    const b = (try world.createObject(.robot, grunt, 140, 100, .red, .direct, .{})).?;
    const enemy = (try world.createObject(.robot, grunt, 400, 400, .blue, .direct, .{})).?;

    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    var c = Control.init(gpa);
    defer c.deinit();
    c.reset(.red);

    // A click on a unit selects it; a box both.
    c.selectBox(&world, 105, 105, 105, 105, rng);
    try std.testing.expectEqualSlices(i32, &.{a.ref_id}, c.selected.items);
    c.selectBox(&world, 90, 90, 200, 130, rng);
    try std.testing.expectEqual(2, c.selected.items.len);
    try std.testing.expect(c.abilities.can_move and c.abilities.can_attack);
    // Enemies are never selected.
    c.selectBox(&world, 0, 0, 500, 500, rng);
    try std.testing.expect(!c.isSelected(enemy.ref_id));

    c.setGroup(3);
    c.clear(&world, rng);
    try std.testing.expect(c.loadGroup(&world, 3, rng) == null);
    try std.testing.expectEqual(2, c.selected.items.len);
    // Pressing the number again: look at the group.
    const center = c.loadGroup(&world, 3, rng).?;
    try std.testing.expectEqual(a.center_x + 20, center[0]);

    // Pointing at the enemy: attack cursor and attack orders.
    c.updateHover(&world, enemy.x + 2, enemy.y + 2);
    try std.testing.expectEqual(cursor.Kind.attack, c.cursorKind(&world, false));
    c.addOrder(&world, enemy.x + 2, enemy.y + 2, .{});
    const wp = c.pending.get(b.ref_id).?.items[0];
    try std.testing.expectEqual(protocol.WaypointMode.attack, wp.mode);
    try std.testing.expectEqual(enemy.ref_id, wp.ref_id);
    // Empty ground: move.
    c.updateHover(&world, 300, 50);
    try std.testing.expectEqual(cursor.Kind.place, c.cursorKind(&world, false));

    c.forget(a.ref_id);
    try std.testing.expectEqualSlices(i32, &.{b.ref_id}, c.selected.items);
    try std.testing.expect(c.pending.get(a.ref_id) == null);
}
