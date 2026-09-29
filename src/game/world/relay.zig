//! Messages to the clients: every change they must hear about is encoded
//! and queued in the world's outbox (part of World, see world.zig).

const std = @import("std");
const k = @import("../constants.zig");
const protocol = @import("../../net/protocol.zig");
const world = @import("../world.zig");
const World = world.World;
const Error = world.Error;
const Object = world.Object;
const Waypoint = world.Waypoint;
const Audience = world.Audience;
const CompSound = world.CompSound;
const PortraitAnim = world.PortraitAnim;

pub fn send(w: *World, to: Audience, id: protocol.Message, payload: []const u8) Error!void {
    const copy = try w.gpa.dupe(u8, payload);
    errdefer w.gpa.free(copy);
    try w.outbox.append(w.gpa, .{ .to = to, .id = id, .payload = copy });
}

pub fn sendPacket(w: *World, to: Audience, id: protocol.Message, packet: anytype) Error!void {
    try send(w, to, id, protocol.bytesOf(&packet));
}

pub const Color = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 };

/// A line in the players' news ticker.
pub fn news(w: *World, to: Audience, text: []const u8, color: Color) Error!void {
    if (text.len == 0) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(w.gpa);
    try buf.appendSlice(w.gpa, &.{ color.r, color.g, color.b });
    try buf.appendSlice(w.gpa, text);
    try buf.append(w.gpa, 0);
    try send(w, to, .news, buf.items);
}

pub fn compMessage(w: *World, team: k.Team, ref_id: i32, sound: CompSound) Error!void {
    try sendPacket(w, .{ .team = team }, .comp_msg, protocol.ComputerMsg{ .ref_id = ref_id, .sound = @intFromEnum(sound) });
}

pub fn relayPortraitAnim(w: *World, ref_id: i32, anim: PortraitAnim) Error!void {
    try sendPacket(w, .all, .do_portrait_anim, protocol.DoPortraitAnim{ .ref_id = ref_id, .anim_id = @intFromEnum(anim) });
}

pub fn relayNewObject(w: *World, o: *Object, to: Audience) Error!void {
    try sendPacket(w, to, .add_new_object, protocol.ObjectInit{
        .x = o.x,
        .y = o.y,
        .ref_id = o.ref_id,
        .owner = @intCast(@intFromEnum(o.owner)),
        .object_type = @intFromEnum(o.objectType()),
        .object_id = o.objectId(),
        .blevel = switch (o.kind) {
            .building => |b| @intCast(b.level),
            else => 0,
        },
        .extra_links = switch (o.kind) {
            .building => |b| b.extra_links,
            else => 0,
        },
        .health = o.health,
    });
    try relayGroupInfo(w, o, to);
}

pub fn relayHealth(w: *World, o: *Object, to: Audience) Error!void {
    try sendPacket(w, to, .update_health, protocol.ObjectHealth{ .ref_id = o.ref_id, .health = o.health });
}

pub fn relayLocation(w: *World, o: *Object) Error!void {
    var buf: [4 + @sizeOf(protocol.Location)]u8 = undefined;
    std.mem.writeInt(i32, buf[0..4], o.ref_id, .little);
    @memcpy(buf[4..], std.mem.asBytes(&o.location()));
    try send(w, .all, .send_loc, &buf);
}

pub fn relayAttackTarget(w: *World, o: *Object) Error!void {
    try sendPacket(w, .all, .set_attack_object, protocol.AttackObject{ .ref_id = o.ref_id, .attack_object_ref_id = o.attack_target orelse -1 });
}

fn waypointData(w: *World, ref_id: i32, list: []const Waypoint) Error![]u8 {
    const data = try w.gpa.alloc(u8, 8 + list.len * @sizeOf(Waypoint));
    std.mem.writeInt(i32, data[0..4], ref_id, .little);
    std.mem.writeInt(i32, data[4..8], @intCast(list.len), .little);
    @memcpy(data[8..], std.mem.sliceAsBytes(list));
    return data;
}

/// Waypoints are only shown to the unit's own team.
pub fn relayWaypoints(w: *World, o: *Object) Error!void {
    const data = try waypointData(w, o.ref_id, o.waypoints.items);
    defer w.gpa.free(data);
    try send(w, .{ .team = o.owner }, .send_waypoints, data);
}

pub fn relayRallypoints(w: *World, o: *Object, to: Audience) Error!void {
    if (!o.canSetRallypoints()) return;
    const data = try waypointData(w, o.ref_id, o.rallypoints.items);
    defer w.gpa.free(data);
    try send(w, to, .send_rallypoints, data);
}

pub fn relayTeam(w: *World, o: *Object) Error!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(w.gpa);
    const header: protocol.ObjectTeam = .{
        .ref_id = o.ref_id,
        .owner = @intCast(@intFromEnum(o.owner)),
        .driver_type = @intCast(@intFromEnum(o.driver_type)),
        .driver_amount = @intCast(o.drivers.items.len),
    };
    try buf.appendSlice(w.gpa, std.mem.asBytes(&header));
    try buf.appendSlice(w.gpa, std.mem.sliceAsBytes(o.drivers.items));
    try send(w, .all, .set_object_team, buf.items);
}

/// OBJECT_GROUP_INFO: `i32 ref_id, i32 leader, i32 count, ids...`.
/// NOTE: the original wrote the minion ids starting at the count's slot
/// (and read them back the same way), so squads with minions never got
/// through to C++ clients. These bytes reproduce that exactly while C++
/// clients may connect.
pub fn relayGroupInfo(w: *World, o: *Object, to: Audience) Error!void {
    if (o.kind != .robot) return;
    const n = o.minions.items.len;
    const data = try w.gpa.alloc(u8, 12 + 4 * n);
    defer w.gpa.free(data);
    @memset(data, 0);
    const ints: []align(1) i32 = std.mem.bytesAsSlice(i32, data);
    ints[0] = o.ref_id;
    ints[1] = o.leader orelse -1;
    ints[2] = @intCast(n);
    for (o.minions.items, 0..) |id, i| ints[2 + i] = id;
    try send(w, to, .object_group_info, data);
}

pub fn relayGrenadeAmount(w: *World, o: *Object, to: Audience) Error!void {
    if (!o.canHaveGrenades()) return;
    try sendPacket(w, to, .set_grenade_amount, protocol.GrenadeAmount{ .ref_id = o.ref_id, .grenade_amount = o.grenades });
}

pub fn relayBuiltCannons(w: *World, o: *Object) Error!void {
    const b = o.building() orelse return;
    const data = try w.gpa.alloc(u8, 8 + b.cannons.items.len);
    defer w.gpa.free(data);
    std.mem.writeInt(i32, data[0..4], o.ref_id, .little);
    std.mem.writeInt(i32, data[4..8], @intCast(b.cannons.items.len), .little);
    for (b.cannons.items, 0..) |c, i| data[8 + i] = @intFromEnum(c);
    try send(w, .all, .set_built_cannon_amount, data);
}

pub fn relayQueue(w: *World, o: *Object, to: Audience) Error!void {
    const b = o.building() orelse return;
    if (!b.producesUnits()) return;
    const data = try w.gpa.alloc(u8, 8 + 2 * b.queue.items.len);
    defer w.gpa.free(data);
    std.mem.writeInt(i32, data[0..4], o.ref_id, .little);
    std.mem.writeInt(i32, data[4..8], @intCast(b.queue.items.len), .little);
    for (b.queue.items, 0..) |u, i| {
        data[8 + 2 * i] = @intFromEnum(u.kind);
        data[9 + 2 * i] = u.id;
    }
    try send(w, to, .set_building_queue_list, data);
}

pub fn relayRepairAnim(w: *World, o: *Object, to: Audience, play_sound: bool) Error!void {
    const b = o.building() orelse return;
    if (b.type != .repair) return;
    try sendPacket(w, to, .set_repair_anim, protocol.RepairBuildingAnim{
        .ref_id = o.ref_id,
        .on = b.repair != null,
        .remaining_time = if (b.repair) |r| r.done_time - w.now() else 0,
        .play_sound = play_sound,
    });
}

/// Production state, repair animation and queue of a building.
pub fn relayBuildingState(w: *World, o: *Object, to: Audience) Error!void {
    if (w.buildingState(o)) |state| try sendPacket(w, to, .set_building_state, state);
    try relayRepairAnim(w, o, to, true);
    try relayQueue(w, o, to);
}
