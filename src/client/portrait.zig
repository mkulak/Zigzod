//! The talking face in the HUD (ZPortrait): the robot driving the selected
//! unit, built from a head, eyes, mouth, shoulders and a hand, animated
//! with the frames in portrait_frames.zig. It says something when units
//! are selected or ordered, when they are attacked, and now and then just
//! blinks or looks around.

const std = @import("std");
const k = @import("../game/constants.zig");
const gfx = @import("gfx.zig");
const frames = @import("portrait_frames.zig");
const Object = @import("../game/object.zig").Object;

const Image = gfx.Image;
const Assets = @import("assets.zig").Assets;
const Canvas = gfx.Canvas;

pub const width = 86;
pub const height = 74;

const eye_count = 11;
const hand_count = 9;
const mouth_count = 16;

/// Animations, in the order of the C++ enum (the wire ids of
/// DO_PORTRAIT_ANIM are these).
pub const Anim = enum(u8) {
    yes_sir,
    yes_sir3,
    unit_reporting1,
    unit_reporting2,
    grunts_reporting,
    psychos_reporting,
    snipers_reporting,
    toughs_reporting,
    lasers_reporting,
    pyros_reporting,
    were_on_our_way,
    here_we_go,
    youve_got_it,
    moving_in,
    okay,
    alright,
    no_problem,
    over_n_out,
    affirmative,
    going_in,
    lets_do_it,
    lets_get_em,
    were_under_attack,
    i_said_were_under_attack,
    help_help,
    theyre_all_over_us,
    were_losing_it,
    aaahhh,
    for_christ_sake,
    youre_joking,
    target_destroyed,
    blink,
    wink,
    surprise,
    anger,
    grin,
    scared,
    eyes_left,
    eyes_right,
    eyes_up,
    eyes_down,
    whistle,
    look_left,
    look_right,
    salute,
    thumbs_up,
    yes_sir_salute,
    going_in_thumbs_up,
    forget_it,
    get_outta_here,
    no_way,
    good_hit,
    nice_one,
    oh_yeah,
    gotcha,
    smokin,
    cool,
    wipe_out,
    territory_taken,
    fire_extinguished,
    gun_captured,
    vehicle_captured,
    grenades_collected,
    end_won1,
    end_won2,
    end_won3,
    end_lost1,
    end_lost2,
    end_lost3,

    comptime {
        std.debug.assert(@typeInfo(Anim).@"enum".fields.len == frames.anims.len);
    }

    fn duration(a: Anim) f64 {
        var ticks: u32 = 0;
        for (frames.anims[@intFromEnum(a)]) |f| ticks += f.ticks;
        return @as(f64, @floatFromInt(ticks)) * frames.tick;
    }
};

/// One robot's face in one team's colors.
const Face = struct {
    shoulders: Image,
    head: [3]Image,
    mouth: [mouth_count]Image,
    eyes: [eye_count]Image,
    hand: [hand_count]Image,

    /// The pictures, in the order of the art's numbering.
    fn images(f: *Face) []Image {
        const all: [*]Image = @ptrCast(f);
        return all[0 .. @sizeOf(Face) / @sizeOf(Image)];
    }
};

pub const Faces = struct {
    faces: [k.Robot.count][k.Team.count]Face,
    backdrop: [k.Planet.count]Image,
    backdrop_vehicle: Image,

    /// The old game's numbering of the face art.
    fn artId(r: k.Robot) u8 {
        return switch (r) {
            .grunt => 2,
            .psycho => 3,
            .sniper => 4,
            .tough => 0,
            .pyro, .laser => 1,
        };
    }

    pub fn load(a: *Assets) Assets.Error!Faces {
        var m: Faces = undefined;
        m.backdrop_vehicle = try a.image("other/hud/backdrop_vehicle.bmp", .{});
        for (&m.backdrop, 0..) |*b, p| b.* = try a.image("other/hud/backdrop_{s}.bmp", .{@tagName(@as(k.Planet, @enumFromInt(p)))});
        for (&m.faces, 0..) |*per_team, r| {
            const robot: k.Robot = @enumFromInt(r);
            // Drawn for red, recolored for the teams without their own art.
            const red = &per_team[@intFromEnum(k.Team.red)];
            for (red.images(), 0..) |*img, i| {
                img.* = try a.image("other/hud/portraits/{s}_red/SHEADBI{d}_{d:0>4}.png", .{ @tagName(robot), artId(robot), i });
            }
            for (per_team, 0..) |*face, t| {
                const team: k.Team = @enumFromInt(t);
                if (team == .red) continue;
                for (face.images(), red.images(), 0..) |*img, base, i| {
                    img.* = if (team == .none)
                        a.nothing
                    else
                        try a.find("other/hud/portraits/{s}_{s}/SHEADBI{d}_{d:0>4}.png", .{ @tagName(robot), team.name(), artId(robot), i }) orelse
                            try a.recolor(team, base);
                }
            }
        }
        return m;
    }
};

pub const Portrait = struct {
    /// Whose face (null: nothing shown).
    robot: ?k.Robot = null,
    team: k.Team = .none,
    in_vehicle: bool = false,
    /// The object it speaks for.
    ref_id: ?i32 = null,
    anim: ?Anim = null,
    start: f64 = 0,
    /// Blinks and glances while idle.
    idle_anims: bool = true,
    next_idle: f64 = 0,
    /// Started talking (the app plays the line and clears this).
    said: ?Anim = null,

    /// Show the robot of `o` (a robot, or the driver of a vehicle or gun).
    pub fn show(p: *Portrait, o: ?*const Object) void {
        p.* = .{ .idle_anims = p.idle_anims, .next_idle = p.next_idle };
        const obj = o orelse return;
        p.team = obj.owner;
        p.ref_id = obj.ref_id;
        switch (obj.kind) {
            .robot => |r| p.robot = r,
            .vehicle, .cannon => {
                p.robot = obj.driver_type;
                p.in_vehicle = true;
            },
            else => {},
        }
    }

    /// Show a robot that isn't on the map (the end of game parade).
    pub fn showRobot(p: *Portrait, r: k.Robot, team: k.Team, in_vehicle: bool) void {
        p.* = .{ .idle_anims = p.idle_anims, .next_idle = p.next_idle, .robot = r, .team = team, .in_vehicle = in_vehicle };
    }

    /// `time` is real time.
    pub fn play(p: *Portrait, anim: Anim, time: f64) void {
        if (frames.anims[@intFromEnum(anim)].len == 0) return;
        p.anim = anim;
        p.start = time;
        p.said = anim;
    }

    pub fn busy(p: *const Portrait) bool {
        return p.anim != null;
    }

    pub fn update(p: *Portrait, time: f64, rng: std.Random) void {
        if (p.anim) |a| {
            if (time - p.start > a.duration()) {
                p.anim = null;
                p.next_idle = time + 0.5 + 0.1 * @as(f64, @floatFromInt(rng.uintLessThan(u32, 50)));
            }
            return;
        }
        if (!p.idle_anims or time < p.next_idle) return;
        const idle = [_]Anim{ .blink, .wink, .surprise, .anger, .grin, .scared, .eyes_left, .eyes_right, .eyes_up, .eyes_down, .whistle, .look_left, .look_right };
        p.play(idle[rng.uintLessThan(usize, idle.len)], time);
    }

    /// The frame to show now.
    fn frame(p: *const Portrait, time: f64) frames.Frame {
        const still: frames.Frame = .{ .ticks = 0, .look = .straight, .head_y = 2, .mouth = 0, .eyes = 0, .hand = null, .hand_x = 0, .hand_y = 0 };
        const a = p.anim orelse return still;
        const list = frames.anims[@intFromEnum(a)];
        const t = time - p.start;
        var at: f64 = 0;
        var shown = still;
        for (list) |f| {
            if (at > t) break;
            shown = f;
            at += @as(f64, @floatFromInt(f.ticks)) * frames.tick;
        }
        return shown;
    }

    /// Draw into the 86x74 box at (x, y) (black when empty).
    pub fn draw(p: *const Portrait, cv: Canvas, faces: *const Faces, planet: k.Planet, x: i32, y: i32, time: f64) void {
        const box: gfx.Rect = .{ .x = x, .y = y, .w = width, .h = height };
        const robot = p.robot orelse return cv.fill(box, .{ .r = 0, .g = 0, .b = 0 });
        const in_box: Canvas = .{ .target = cv.target, .clip = box.intersect(cv.clip) orelse return, .dx = cv.dx, .dy = cv.dy };
        in_box.draw(if (p.in_vehicle) faces.backdrop_vehicle else faces.backdrop[@intFromEnum(planet)], x, y);
        const face = &faces.faces[@intFromEnum(robot)][@intFromEnum(p.team)];
        const f = p.frame(time);
        const head_x = 4;
        in_box.draw(face.head[@intFromEnum(f.look)], x + head_x, y + f.head_y);
        if (f.look == .straight) {
            const face_y: i32 = switch (robot) {
                .grunt => 0,
                .sniper => 4,
                else => 2,
            };
            in_box.draw(face.eyes[@min(f.eyes, eye_count - 1)], x + 14 + head_x, y + 8 + f.head_y + face_y);
            in_box.draw(face.mouth[@min(f.mouth, mouth_count - 1)], x + 22 + head_x, y + 24 + f.head_y + face_y);
        }
        in_box.draw(face.shoulders, x, y + height - face.shoulders.height());
        if (f.hand) |h| in_box.draw(face.hand[@min(h, hand_count - 1)], x + f.hand_x, y + f.hand_y);
    }
};

/// What a unit says when selected (PlaySelectedAnim).
pub fn selectedAnim(o: *const Object, rng: std.Random) Anim {
    const generic = [_]Anim{ .yes_sir, .yes_sir3, .unit_reporting1, .unit_reporting2 };
    switch (o.kind) {
        .robot => |r| if (rng.boolean()) return switch (r) {
            .grunt => .grunts_reporting,
            .psycho => .psychos_reporting,
            .sniper => .snipers_reporting,
            .tough => .toughs_reporting,
            .pyro => .pyros_reporting,
            .laser => .lasers_reporting,
        },
        else => {},
    }
    return generic[rng.uintLessThan(usize, generic.len)];
}

/// What a unit says when ordered (PlayAcknowledgeAnim); `no_way` when the
/// target will beat it.
pub fn acknowledgeAnim(no_way: bool, rng: std.Random) Anim {
    if (no_way) {
        const refuse = [_]Anim{ .forget_it, .get_outta_here, .no_way };
        return refuse[rng.uintLessThan(usize, refuse.len)];
    }
    const ok = [_]Anim{ .were_on_our_way, .here_we_go, .youve_got_it, .moving_in, .okay, .alright, .no_problem, .over_n_out, .affirmative, .going_in, .lets_do_it, .lets_get_em };
    return ok[rng.uintLessThan(usize, ok.len)];
}

test "portrait animations run and end" {
    var prng = std.Random.DefaultPrng.init(2);
    var p: Portrait = .{ .robot = .grunt, .team = .red };
    p.play(.yes_sir, 10);
    try std.testing.expect(p.busy());
    const mid = p.frame(10.05);
    try std.testing.expectEqual(@as(?u8, 2), mid.hand);
    p.update(10 + Anim.yes_sir.duration() + 0.01, prng.random());
    try std.testing.expect(!p.busy());

    const a = try Assets.init(std.testing.allocator, "bin/assets");
    defer a.deinit();
    const faces = try Faces.load(a);
    try std.testing.expectEqual(0, a.missing);
    try std.testing.expect(faces.faces[@intFromEnum(k.Robot.laser)][@intFromEnum(k.Team.green)].hand[8].w > 1);
}
