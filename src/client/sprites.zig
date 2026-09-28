//! All object images, loaded once (the static `Init()` functions of the
//! C++ object classes).

const std = @import("std");
const k = @import("../game/constants.zig");
const gfx = @import("gfx.zig");

const Image = gfx.Image;
const Team = k.Team;
const Planet = k.Planet;
const teams = Team.count;
const planets = Planet.count;

pub const map_objects = k.Item.count - 5;

/// Load `n` images named by `fmt` with the index appended to `args`.
fn loadSeq(comptime n: usize, comptime fmt: []const u8, args: anytype) [n]?Image {
    var out: [n]?Image = @splat(null);
    for (&out, 0..) |*img, i| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, fmt, args ++ .{i}) catch continue;
        img.* = Image.load(path);
    }
    return out;
}

fn loadOne(comptime fmt: []const u8, args: anytype) ?Image {
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, fmt, args) catch return null;
    return Image.load(path);
}

fn freeAll(value: anytype) void {
    const T = @TypeOf(value.*);
    switch (@typeInfo(T)) {
        .optional => if (value.*) |img| {
            img.deinit();
            value.* = null;
        },
        .array => for (value) |*v| freeAll(v),
        .@"struct" => |s| inline for (s.fields) |f| freeAll(&@field(value, f.name)),
        else => {},
    }
}

/// `base` with `overlay` drawn at (x, y): the team colored parts of
/// buildings.
fn composite(base: ?Image, overlay: ?Image, x: i32, y: i32) ?Image {
    const b = base orelse return null;
    const img = b.clone() orelse return null;
    if (overlay) |o| img.draw(o, null, x, y);
    return img;
}

/// Per planet, per team versions of a building: the planet's base with the
/// team's color plate on it (none for neutral).
fn teamBases(base: [planets]?Image, plates: gfx.TeamImages, x: i32, y: i32) [planets][teams]?Image {
    var out: [planets][teams]?Image = @splat(@splat(null));
    for (0..planets) |p| {
        out[p][0] = if (base[p]) |b| b.clone() else null;
        for (1..teams) |t| out[p][t] = composite(base[p], plates[t], x, y);
    }
    return out;
}

fn perPlanet(comptime fmt: []const u8, assets: []const u8) [planets]?Image {
    var out: [planets]?Image = @splat(null);
    for (&out, 0..) |*img, i| img.* = loadOne(fmt, .{ assets, @tagName(@as(Planet, @enumFromInt(i))) });
    return out;
}

pub const Fort = struct {
    front: [planets]?Image,
    back: [planets]?Image,
    front_destroyed: [planets]?Image,
    back_destroyed: [planets]?Image,
    /// Pulses over a destroyed fort.
    front_destroyed_overlay: [planets]?Image,
    back_destroyed_overlay: [planets]?Image,
    flag: [teams][4]?Image,
};

pub const Radar = struct {
    base: [planets][teams]?Image,
    destroyed: [planets]?Image,
    box_spinner: [12]?Image,
    dish: [8]?Image,
    front_light: [2]?Image,
    side_light: [2]?Image,
};

pub const RobotFactory = struct {
    base: [planets][teams]?Image,
    destroyed: [planets][teams]?Image,
    spin: [8]?Image,
    green_box: [6]?Image,
    robot: [2]?Image,
    light: [2]?Image,
    double_light: [2]?Image,
};

pub const VehicleFactory = struct {
    base: [planets][teams]?Image,
    destroyed: [planets][teams]?Image,
    spin: [8]?Image,
    vent: [4]?Image,
    lights: [2]?Image,
    tank: [2]?Image,
    bulb: [2]?Image,
};

pub const Repair = struct {
    base: [planets][teams]?Image,
    destroyed: [planets]?Image,
    smoke_stack: [5]?Image,
    text_box: [3]?Image,
    bulb: [2]?Image,
    side_light: [2]?Image,
    front_light: [2]?Image,
};

pub const Sprites = struct {
    // Map items.
    flag: [teams][4]?Image,
    grenades: ?Image,
    rockets: ?Image,
    map_object: [map_objects]?Image,
    hut: [planets]?Image,
    /// Rock tiles (6x6 sheet of 16x16 pieces).
    rocks: [planets]?Image,

    // Buildings.
    level: [k.max_building_levels]?Image,
    exhaust: [13]?Image,
    little_exhaust: [4]?Image,
    fort: Fort,
    radar: Radar,
    robot_factory: RobotFactory,
    vehicle_factory: VehicleFactory,
    repair: Repair,
    bridge: [planets]?Image,

    pub fn load(assets: []const u8, palettes: *const gfx.TeamPalettes) Sprites {
        var s: Sprites = undefined;
        for (&s.flag, 0..) |*f, t| f.* = teamSeq(palettes, 4, t, "{s}/other/flag_{s}_{d}.png", assets);
        s.grenades = loadOne("{s}/other/map_items/grenades.png", .{assets});
        s.rockets = loadOne("{s}/other/map_items/rockets.png", .{assets});
        s.map_object = loadSeq(map_objects, "{s}/other/map_items/map_object{d}.png", .{assets});
        s.hut = perPlanet("{s}/other/map_items/hut_{s}.png", assets);
        s.rocks = perPlanet("{s}/planets/rocks_{s}.png", assets);

        // (level_N counts from 1)
        for (&s.level, 0..) |*l, i| l.* = loadOne("{s}/buildings/level_{d}.bmp", .{ assets, i + 1 });
        s.exhaust = loadSeq(13, "{s}/buildings/exhaust_{d}.png", .{assets});
        s.little_exhaust = loadSeq(4, "{s}/buildings/little_exhaust_{d}.png", .{assets});

        const overlay = loadOne("{s}/buildings/fort/destroyed_overlay.png", .{assets});
        defer if (overlay) |o| o.deinit();
        s.fort = .{
            .front = perPlanet("{s}/buildings/fort/fort_{s}_front.png", assets),
            .back = perPlanet("{s}/buildings/fort/fort_{s}_back.png", assets),
            .front_destroyed = perPlanet("{s}/buildings/fort/fort_{s}_front_destroyed.png", assets),
            .back_destroyed = perPlanet("{s}/buildings/fort/fort_{s}_back_destroyed.png", assets),
            .front_destroyed_overlay = undefined,
            .back_destroyed_overlay = undefined,
            .flag = undefined,
        };
        for (0..planets) |p| {
            s.fort.front_destroyed_overlay[p] = composite(s.fort.front_destroyed[p], overlay, 0, 0);
            s.fort.back_destroyed_overlay[p] = composite(s.fort.back_destroyed[p], overlay, 0, 0);
        }
        for (&s.fort.flag, 0..) |*f, t| f.* = teamSeq(palettes, 4, t, "{s}/buildings/fort/flag_{s}_n{d:0>2}.png", assets);

        {
            var plates = gfx.loadTeamImages(palettes, "{s}/buildings/radar/{s}.png", .{assets});
            defer gfx.freeTeamImages(&plates);
            var base = perPlanet("{s}/buildings/radar/base_{s}.png", assets);
            defer freeAll(&base);
            s.radar = .{
                .base = teamBases(base, plates, 0, 32),
                .destroyed = perPlanet("{s}/buildings/radar/base_destroyed_{s}.png", assets),
                .box_spinner = loadSeq(12, "{s}/buildings/radar/box_spinner_{d}.png", .{assets}),
                .dish = loadSeq(8, "{s}/buildings/radar/dish_{d}.png", .{assets}),
                .front_light = loadSeq(2, "{s}/buildings/radar/front_light_{d}.png", .{assets}),
                .side_light = loadSeq(2, "{s}/buildings/radar/side_light_{d}.png", .{assets}),
            };
        }
        {
            var plates = gfx.loadTeamImages(palettes, "{s}/buildings/robot/{s}.png", .{assets});
            defer gfx.freeTeamImages(&plates);
            var plates_destroyed = gfx.loadTeamImages(palettes, "{s}/buildings/robot/{s}_destroyed.png", .{assets});
            defer gfx.freeTeamImages(&plates_destroyed);
            var base = perPlanet("{s}/buildings/robot/base_{s}.png", assets);
            defer freeAll(&base);
            var base_destroyed = perPlanet("{s}/buildings/robot/base_destroyed_{s}.png", assets);
            defer freeAll(&base_destroyed);
            s.robot_factory = .{
                .base = teamBases(base, plates, 16, 64),
                .destroyed = teamBases(base_destroyed, plates_destroyed, 16, 64),
                .spin = loadSeq(8, "{s}/buildings/robot/spin_{d}.png", .{assets}),
                .green_box = loadSeq(6, "{s}/buildings/robot/green_box_{d}.png", .{assets}),
                .robot = loadSeq(2, "{s}/buildings/robot/robot_{d}.png", .{assets}),
                .light = loadSeq(2, "{s}/buildings/robot/light_{d}.png", .{assets}),
                .double_light = loadSeq(2, "{s}/buildings/robot/double_light_{d}.png", .{assets}),
            };
        }
        {
            var plates = gfx.loadTeamImages(palettes, "{s}/buildings/vehicle/{s}.png", .{assets});
            defer gfx.freeTeamImages(&plates);
            var plates_destroyed = gfx.loadTeamImages(palettes, "{s}/buildings/vehicle/{s}_destroyed.png", .{assets});
            defer gfx.freeTeamImages(&plates_destroyed);
            var base = perPlanet("{s}/buildings/vehicle/base_{s}.png", assets);
            defer freeAll(&base);
            var base_destroyed = perPlanet("{s}/buildings/vehicle/base_destroyed_{s}.png", assets);
            defer freeAll(&base_destroyed);
            s.vehicle_factory = .{
                .base = teamBases(base, plates, 32, 48),
                .destroyed = teamBases(base_destroyed, plates_destroyed, 32, 48),
                .spin = loadSeq(8, "{s}/buildings/vehicle/spin_{d}.png", .{assets}),
                .vent = loadSeq(4, "{s}/buildings/vehicle/vent_{d}.png", .{assets}),
                .lights = loadSeq(2, "{s}/buildings/vehicle/lights_{d}.png", .{assets}),
                .tank = loadSeq(2, "{s}/buildings/vehicle/tank_{d}.png", .{assets}),
                .bulb = loadSeq(2, "{s}/buildings/vehicle/bulb_{d}.png", .{assets}),
            };
        }
        {
            var plates = gfx.loadTeamImages(palettes, "{s}/buildings/repair/{s}.png", .{assets});
            defer gfx.freeTeamImages(&plates);
            var base = perPlanet("{s}/buildings/repair/base_{s}.png", assets);
            defer freeAll(&base);
            s.repair = .{
                .base = teamBases(base, plates, 0, 48),
                .destroyed = perPlanet("{s}/buildings/repair/base_destroyed_{s}.png", assets),
                .smoke_stack = loadSeq(5, "{s}/buildings/repair/smoke_stack_{d}.png", .{assets}),
                .text_box = loadSeq(3, "{s}/buildings/repair/text_box_{d}.png", .{assets}),
                .bulb = loadSeq(2, "{s}/buildings/repair/bulb_{d}.png", .{assets}),
                .side_light = loadSeq(2, "{s}/buildings/repair/side_light_{d}.png", .{assets}),
                .front_light = loadSeq(2, "{s}/buildings/repair/front_light_{d}.png", .{assets}),
            };
        }
        s.bridge = perPlanet("{s}/planets/bridge_{s}.png", assets);
        return s;
    }

    pub fn deinit(s: *Sprites) void {
        freeAll(s);
    }
};

/// `n` frames for team `t`: files for neutral and red, recolored from red
/// for the others. `fmt` takes the assets folder, team name and index.
fn teamSeq(palettes: *const gfx.TeamPalettes, comptime n: usize, t: usize, comptime fmt: []const u8, assets: []const u8) [n]?Image {
    const team: Team = @enumFromInt(t);
    if (team == .none or team == .red) return loadSeq(n, fmt, .{ assets, team.name() });
    var red = loadSeq(n, fmt, .{ assets, Team.red.name() });
    defer freeAll(&red);
    var out: [n]?Image = @splat(null);
    for (&out, red) |*o, r| o.* = if (r) |img| palettes.make(team, img) else null;
    return out;
}

test "load all sprites" {
    const palettes = gfx.TeamPalettes.load("bin/assets");
    var s = Sprites.load("bin/assets", &palettes);
    defer s.deinit();
    try std.testing.expect(s.fort.front[0] != null);
    try std.testing.expect(s.radar.base[0][@intFromEnum(Team.blue)] != null);
    try std.testing.expect(s.flag[@intFromEnum(Team.yellow)][3] != null);
    try std.testing.expect(s.level[5] != null);
}
