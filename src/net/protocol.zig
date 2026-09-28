//! The Zod network protocol (from QZod_DnSeparate/event_handler.h and
//! socket_handler.cpp). Kept wire-compatible with the original engine, so
//! Zig and C++ servers/clients/bots can talk to each other.
//!
//! Every message is framed as
//!     i32 payload_size, i32 message_id, payload_size bytes
//! in little-endian (the original sent raw x86 ints). Fixed-size payloads
//! are the packed structs below; some messages carry strings or lists.

const std = @import("std");

pub const header_size = 8;
/// Largest payload a peer accepts (MAX_BUF_SIZE - header in the original).
pub const max_payload = 20000 - header_size;

/// Message ids; the order is the wire value and must not change.
pub const Message = enum(i32) {
    debug,
    request_map,
    give_player_name,
    store_map,
    request_objects,
    request_zones,
    add_new_object,
    set_zone_info,
    set_name,
    set_team,
    news,
    send_waypoints,
    send_rallypoints,
    send_loc,
    set_object_team,
    set_attack_object,
    delete_object,
    update_health,
    end_game,
    reset_game,
    fire_missile,
    destroy_object,
    start_building,
    stop_building,
    set_building_state,
    set_built_cannon_amount,
    place_cannon,
    send_chat,
    comp_msg,
    object_group_info,
    eject_vehicle,
    do_crane_anim,
    set_repair_anim,
    request_settings,
    set_settings,
    set_lid_open,
    snipe_object,
    driver_hit_effect,
    set_player_mode,
    request_player_list,
    clear_player_list,
    add_lplayer,
    delete_lplayer,
    set_lplayer_name,
    set_lplayer_team,
    set_lplayer_mode,
    set_lplayer_ignored,
    set_lplayer_loginfo,
    set_lplayer_voteinfo,
    send_bot_bypass_data,
    update_game_paused,
    get_game_paused,
    set_game_paused,
    start_vote,
    vote_yes,
    vote_no,
    vote_pass,
    vote_info,
    give_player_id,
    request_player_id,
    request_selectable_map_list,
    give_selectable_map_list,
    send_login,
    request_loginoff,
    give_loginoff,
    create_user,
    set_grenade_amount,
    pickup_grenade_anim,
    do_portrait_anim,
    team_ended,
    poll_buy_regkey,
    buy_regkey,
    return_regkey,
    get_game_speed,
    set_game_speed,
    update_game_speed,
    add_building_queue,
    set_building_queue_list,
    cancel_building_queue,
    reshuffle_teams,
    start_bot,
    stop_bot,
    select_map,
    reset_map,
    request_version,
    give_version,
    _,
};

// ---------------------------------------------------------------------------
// Fixed-size payloads (#pragma pack(1) in the original)
// ---------------------------------------------------------------------------

pub const ObjectInit = extern struct {
    x: i32 align(1),
    y: i32 align(1),
    ref_id: i32 align(1),
    owner: i8,
    object_type: u8,
    object_id: u8,
    blevel: i8,
    extra_links: u16 align(1),
    health: i32 align(1),
};

pub const ZoneInfo = extern struct {
    zone_number: i32 align(1),
    owner: i8,
};

pub const ObjectTeam = extern struct {
    ref_id: i32 align(1),
    owner: i8,
    driver_type: i8,
    driver_amount: i8,
};

pub const AttackObject = extern struct {
    ref_id: i32 align(1),
    attack_object_ref_id: i32 align(1),
};

pub const ObjectHealth = extern struct {
    ref_id: i32 align(1),
    health: i32 align(1),
};

pub const FireMissile = extern struct {
    ref_id: i32 align(1),
    x: i32 align(1),
    y: i32 align(1),
};

pub const DestroyObject = extern struct {
    ref_id: i32 align(1),
    fire_missile_amount: i32 align(1),
    killer_ref_id: i32 align(1),
    destroy_object: bool,
    do_fire_death: bool,
    do_missile_death: bool,
};

pub const StartBuilding = extern struct {
    ref_id: i32 align(1),
    ot: u8,
    oid: u8,
};

pub const SetBuildingState = extern struct {
    ref_id: i32 align(1),
    state: i32 align(1),
    init_offset: f64 align(1),
    prod_time: f64 align(1),
    ot: u8,
    oid: u8,
};

pub const PlaceCannon = extern struct {
    ref_id: i32 align(1),
    tx: i32 align(1),
    ty: i32 align(1),
    oid: u8,
};

pub const ComputerMsg = extern struct {
    ref_id: i32 align(1),
    sound: i32 align(1),
};

pub const EjectVehicle = extern struct {
    ref_id: i32 align(1),
};

pub const CraneAnim = extern struct {
    ref_id: i32 align(1),
    rep_ref_id: i32 align(1),
    on: bool,
};

pub const RepairBuildingAnim = extern struct {
    ref_id: i32 align(1),
    on: bool,
    remaining_time: f64 align(1),
    play_sound: bool,
};

pub const SetLidState = extern struct {
    ref_id: i32 align(1),
    lid_open: bool,
};

pub const SnipeObject = extern struct {
    ref_id: i32 align(1),
};

pub const DriverHit = extern struct {
    ref_id: i32 align(1),
};

pub const PlayerModePacket = extern struct {
    mode: i8,
};

pub const AddRemovePlayer = extern struct {
    p_id: i32 align(1),
};

pub const SetPlayerInt = extern struct {
    p_id: i32 align(1),
    value: i32 align(1),
};

pub const SetPlayerLogInfo = extern struct {
    p_id: i32 align(1),
    db_id: i32 align(1),
    voting_power: i32 align(1),
    total_games: i32 align(1),
    activated: bool,
    logged_in: bool,
    bot_logged_in: bool,
};

pub const GamePaused = extern struct {
    game_paused: bool,
};

pub const VoteInfo = extern struct {
    in_progress: bool,
    vote_type: i32 align(1),
    value: i32 align(1),
};

pub const PlayerId = extern struct {
    p_id: i32 align(1),
};

pub const LoginOff = extern struct {
    show_login: bool,
};

pub const GrenadeAmount = extern struct {
    ref_id: i32 align(1),
    grenade_amount: i32 align(1),
};

/// `int_packet`: a single i32 (value / ref_id / team / map number).
pub const Int = extern struct {
    value: i32 align(1),
};

/// `float_packet`: a single f32 (game speed).
pub const Float = extern struct {
    value: f32 align(1),
};

pub const PortraitAnim = extern struct {
    ref_id: i32 align(1),
    anim_id: i32 align(1),
};

pub const TeamEnded = extern struct {
    team: i32 align(1),
    won: bool,
};

pub const BuyRegistration = extern struct {
    buf: [16]u8,
};

pub const AddBuildingQueue = extern struct {
    ref_id: i32 align(1),
    ot: u8,
    oid: u8,
};

pub const CancelBuildingQueue = extern struct {
    ref_id: i32 align(1),
    list_i: i32 align(1),
    ot: u8,
    oid: u8,
};

pub const max_version_chars = 50;

pub const Version = extern struct {
    version: [max_version_chars]u8,
};

comptime {
    // Sizes of the packed C++ structs.
    std.debug.assert(@sizeOf(ObjectInit) == 22);
    std.debug.assert(@sizeOf(SetBuildingState) == 26);
    std.debug.assert(@sizeOf(DestroyObject) == 15);
    std.debug.assert(@sizeOf(SetPlayerLogInfo) == 19);
    std.debug.assert(@sizeOf(Version) == 50);
    std.debug.assert(@sizeOf(RepairBuildingAnim) == 14);
    std.debug.assert(@sizeOf(ObjectTeam) == 7);
    std.debug.assert(@sizeOf(VoteInfo) == 9);
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

/// Payload bytes of a fixed-size packet.
pub fn bytesOf(packet: anytype) []const u8 {
    return std.mem.asBytes(packet);
}

/// Decode a fixed-size packet; null if the payload has the wrong size.
pub fn decode(comptime T: type, payload: []const u8) ?T {
    if (payload.len != @sizeOf(T)) return null;
    return std.mem.bytesToValue(T, payload);
}

/// A string payload: the original sends C strings including the 0.
pub fn decodeString(payload: []const u8) []const u8 {
    return std.mem.sliceTo(payload, 0);
}

test "packet round trip" {
    const p: ObjectInit = .{ .x = 10, .y = -20, .ref_id = 7, .owner = 1, .object_type = 5, .object_id = 2, .blevel = 0, .extra_links = 3, .health = 1000 };
    const bytes = bytesOf(&p);
    try std.testing.expectEqual(@as(usize, 22), bytes.len);
    // x at offset 0, little-endian.
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 0 }, bytes[0..4]);
    const q = decode(ObjectInit, bytes).?;
    try std.testing.expectEqual(p, q);
    try std.testing.expect(decode(ObjectInit, bytes[0..21]) == null);
    try std.testing.expectEqualStrings("hi", decodeString("hi\x00junk"));
    try std.testing.expectEqual(@as(i32, 86), @intFromEnum(Message.give_version) + 1);
}
