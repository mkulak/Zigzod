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
    @memcpy(try w.outbox.add(w.gpa, to, id, payload.len), payload);
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

/// `i32 ref_id, i32 count, waypoints...`
fn sendWaypoints(w: *World, to: Audience, id: protocol.Message, ref_id: i32, list: []const Waypoint) Error!void {
    const data = try w.outbox.add(w.gpa, to, id, 8 + list.len * @sizeOf(Waypoint));
    std.mem.writeInt(i32, data[0..4], ref_id, .little);
    std.mem.writeInt(i32, data[4..8], @intCast(list.len), .little);
    @memcpy(data[8..], std.mem.sliceAsBytes(list));
}

/// Waypoints are only shown to the unit's own team.
pub fn relayWaypoints(w: *World, o: *Object) Error!void {
    try sendWaypoints(w, .{ .team = o.owner }, .send_waypoints, o.ref_id, o.waypoints.items);
}

pub fn relayRallypoints(w: *World, o: *Object, to: Audience) Error!void {
    if (!o.canSetRallypoints()) return;
    try sendWaypoints(w, to, .send_rallypoints, o.ref_id, o.rallypoints.items);
}

pub fn relayTeam(w: *World, o: *Object) Error!void {
    const header: protocol.ObjectTeam = .{
        .ref_id = o.ref_id,
        .owner = @intCast(@intFromEnum(o.owner)),
        .driver_type = @intCast(@intFromEnum(o.driver_type)),
        .driver_amount = @intCast(o.drivers.items.len),
    };
    const drivers = std.mem.sliceAsBytes(o.drivers.items);
    const data = try w.outbox.add(w.gpa, .all, .set_object_team, @sizeOf(protocol.ObjectTeam) + drivers.len);
    @memcpy(data[0..@sizeOf(protocol.ObjectTeam)], std.mem.asBytes(&header));
    @memcpy(data[@sizeOf(protocol.ObjectTeam)..], drivers);
}

/// OBJECT_GROUP_INFO: `i32 ref_id, i32 leader, i32 count, ids...`.
/// (The original wrote the ids over the count, so C++ clients never got
/// squads' minions.)
pub fn relayGroupInfo(w: *World, o: *Object, to: Audience) Error!void {
    if (o.kind != .robot) return;
    const n = o.minions.items.len;
    const data = try w.outbox.add(w.gpa, to, .object_group_info, 12 + 4 * n);
    std.mem.writeInt(i32, data[0..4], o.ref_id, .little);
    std.mem.writeInt(i32, data[4..8], o.leader orelse -1, .little);
    std.mem.writeInt(i32, data[8..12], @intCast(n), .little);
    for (o.minions.items, 0..) |id, i| std.mem.writeInt(i32, data[12 + 4 * i ..][0..4], id, .little);
}

pub fn relayGrenadeAmount(w: *World, o: *Object, to: Audience) Error!void {
    if (!o.canHaveGrenades()) return;
    try sendPacket(w, to, .set_grenade_amount, protocol.GrenadeAmount{ .ref_id = o.ref_id, .grenade_amount = o.grenades });
}

pub fn relayBuiltCannons(w: *World, o: *Object) Error!void {
    const b = o.building() orelse return;
    const data = try w.outbox.add(w.gpa, .all, .set_built_cannon_amount, 8 + b.cannons.items.len);
    std.mem.writeInt(i32, data[0..4], o.ref_id, .little);
    std.mem.writeInt(i32, data[4..8], @intCast(b.cannons.items.len), .little);
    for (b.cannons.items, 0..) |c, i| data[8 + i] = @intFromEnum(c);
}

pub fn relayQueue(w: *World, o: *Object, to: Audience) Error!void {
    const b = o.building() orelse return;
    if (!b.producesUnits()) return;
    const data = try w.outbox.add(w.gpa, to, .set_building_queue_list, 8 + 2 * b.queue.items.len);
    std.mem.writeInt(i32, data[0..4], o.ref_id, .little);
    std.mem.writeInt(i32, data[4..8], @intCast(b.queue.items.len), .little);
    for (b.queue.items, 0..) |u, i| {
        data[8 + 2 * i] = @intFromEnum(u.kind);
        data[9 + 2 * i] = u.id;
    }
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
