//! All object images, loaded once (the static `Init()` functions of the
//! C++ object classes).
//!
//! The images live as long as the assets (see assets.zig); the tables below
//! may use one image in several places (e.g. the same picture for all
//! directions). Where there is no picture, `Assets.nothing` stands in.

const std = @import("std");
const k = @import("../game/constants.zig");
const gfx = @import("gfx.zig");

const Assets = @import("assets.zig").Assets;
const Error = @import("assets.zig").Assets.Error;
const Image = gfx.Image;
const Team = k.Team;
const Planet = k.Planet;
const teams = Team.count;
const planets = Planet.count;
const dirs = 8;

pub const map_objects = k.Item.count - 5;

/// Directions are drawn at these angles (file names use the angle).
fn angle(dir: usize) usize {
    return dir * 45;
}

/// Loading helpers for the tables below.
const Loader = struct {
    a: *Assets,

    /// One image, `fmt` relative to the assets folder.
    fn one(l: Loader, comptime fmt: []const u8, args: anytype) Error!Image {
        return l.a.image(fmt, args);
    }

    /// `n` images; the index is the last format argument.
    fn seq(l: Loader, comptime n: usize, comptime fmt: []const u8, args: anytype) Error![n]Image {
        var out: [n]Image = undefined;
        for (&out, 0..) |*img, i| img.* = try l.one(fmt, args ++ .{i});
        return out;
    }

    /// Per planet (the planet name is the last format argument).
    fn perPlanet(l: Loader, comptime fmt: []const u8) Error![planets]Image {
        var out: [planets]Image = undefined;
        for (&out, 0..) |*img, i| img.* = try l.one(fmt, .{@tagName(@as(Planet, @enumFromInt(i)))});
        return out;
    }

    /// One image per team (see Assets.teams).
    fn teamsOf(l: Loader, comptime fmt: []const u8, args: anytype, neutral: Assets.Neutral) Error![teams]Image {
        return l.a.teams(fmt, args, neutral);
    }

    /// [teams][n] frames (the frame index is the last format argument).
    fn teamFrames(l: Loader, comptime n: usize, comptime fmt: []const u8, args: anytype, neutral: Assets.Neutral) Error![teams][n]Image {
        var out: [teams][n]Image = undefined;
        for (0..n) |i| {
            const v = try l.teamsOf(fmt, args ++ .{i}, neutral);
            for (0..teams) |t| out[t][i] = v[t];
        }
        return out;
    }

    /// [teams][direction] (the angle is the last format argument).
    fn teamDirs(l: Loader, comptime fmt: []const u8) Error![teams][dirs]Image {
        var out: [teams][dirs]Image = undefined;
        for (0..dirs) |d| {
            const v = try l.teamsOf(fmt, .{angle(d)}, .nothing);
            for (0..teams) |t| out[t][d] = v[t];
        }
        return out;
    }

    /// [teams][direction][frame] (angle, then frame, last).
    fn teamDirFrames(l: Loader, comptime n: usize, comptime fmt: []const u8) Error![teams][dirs][n]Image {
        var out: [teams][dirs][n]Image = undefined;
        for (0..dirs) |d| for (0..n) |i| {
            const v = try l.teamsOf(fmt, .{ angle(d), i }, .nothing);
            for (0..teams) |t| out[t][d][i] = v[t];
        };
        return out;
    }

    /// Per direction, no team colors.
    fn dirImages(l: Loader, comptime fmt: []const u8) Error![dirs]Image {
        var out: [dirs]Image = undefined;
        for (&out, 0..) |*img, d| img.* = try l.one(fmt, .{angle(d)});
        return out;
    }

    /// Per planet, per team versions of a building: the planet's base with
    /// the team's color plate on it (none for neutral).
    fn teamBases(l: Loader, base: [planets]Image, plates: [teams]Image, x: i32, y: i32) Error![planets][teams]Image {
        var out: [planets][teams]Image = undefined;
        for (0..planets) |p| {
            out[p][0] = base[p];
            for (1..teams) |t| out[p][t] = try l.a.composite(base[p], plates[t], x, y);
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Buildings
// ---------------------------------------------------------------------------

pub const Fort = struct {
    front: [planets]Image,
    back: [planets]Image,
    front_destroyed: [planets]Image,
    back_destroyed: [planets]Image,
    /// Pulses over a destroyed fort.
    front_destroyed_overlay: [planets]Image,
    back_destroyed_overlay: [planets]Image,
    flag: [teams][4]Image,
};

pub const Radar = struct {
    base: [planets][teams]Image,
    destroyed: [planets]Image,
    box_spinner: [12]Image,
    dish: [8]Image,
    front_light: [2]Image,
    side_light: [2]Image,
};

pub const RobotFactory = struct {
    base: [planets][teams]Image,
    destroyed: [planets][teams]Image,
    spin: [8]Image,
    green_box: [6]Image,
    robot: [2]Image,
    light: [2]Image,
    double_light: [2]Image,
};

pub const VehicleFactory = struct {
    base: [planets][teams]Image,
    destroyed: [planets][teams]Image,
    spin: [8]Image,
    vent: [4]Image,
    lights: [2]Image,
    tank: [2]Image,
    bulb: [2]Image,
};

pub const Repair = struct {
    base: [planets][teams]Image,
    destroyed: [planets]Image,
    smoke_stack: [5]Image,
    text_box: [3]Image,
    bulb: [2]Image,
    side_light: [2]Image,
    front_light: [2]Image,
};

// ---------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------

pub const CannonSprites = struct {
    wasted: [teams]Image,
    /// Unfolding after being placed.
    place: [teams][4]Image,
    passive: [teams][dirs]Image,
    fire: [teams][dirs]Image,
};

pub const VehicleSprites = struct {
    /// [team][direction][frame]: the driving animation.
    base: [teams][dirs][3]Image,
    damaged: [teams][dirs][3]Image,
    top: [teams][dirs]Image,
    wasted: [teams]Image,
};

pub const Jeep = struct {
    /// Wheels, animated (none when driving up or down).
    under: [dirs][4]Image,
    gun: [dirs]Image,
    gun_fire: [dirs]Image,
};

pub const Crane = struct {
    arm: [dirs]Image,
    hook: [16]Image,
};

pub const RobotSprites = struct {
    null_img: Image,
    stand: [teams][dirs]Image,
    walk: [teams][dirs][4]Image,
    throw: [teams][dirs][4]Image,
    beer: [teams][10]Image,
    cigarette: [teams][11]Image,
    full_area_scan: [teams][12]Image,
    head_stretch: [teams][11]Image,
    pickup_up: [teams][4]Image,
    pickup_down: [teams][4]Image,
    /// Firing, per robot type (frames used: grunt/sniper 5, psycho 2,
    /// tough/pyro/laser 3).
    fire: [k.Robot.count][teams][dirs][5]Image,
    /// Robot in a tank's hatch.
    tank_robot: [teams][dirs][2]Image,
    tank_lid: [dirs][3]Image,
};

/// Images of the effects (explosions, shots, debris, ...).
pub const EffectSprites = struct {
    laser_bullet: [2]Image,
    flame_bullet: [4]Image,
    /// Fire where a pyro's flame lands: 5 kinds with 4, 4, 4, 6, 6 frames.
    pyro_fire: [5][6]Image,
    light_init_fire: [4]Image,
    light_bullet: Image,
    big_smoke: [4]Image,
    little_fire: [4]Image,
    small_fire_smoke: [4]Image,
    fire: [4]Image,
    side_explosion: [7]Image,
    unit_particle: [20]Image,
    spark: [6]Image,
    tough_bullet: [2]Image,
    mushroom: [12]Image,
    tough_smoke: [8]Image,
    mo_bullet: Image,
    mc_bullet: Image,
    grenade: [4]Image,
    light_turret: [8]Image,
    medium_turret: [8]Image,
    heavy_turret: [teams][8]Image,
    building_piece: [2][12]Image,
    fort_piece: [5][12]Image,
    /// Wrecks: gatling, gun, howitzer, missile cannon.
    cannon_wasted: [4]Image,
    jeep_wasted: Image,
    missile_launcher_wasted: Image,
    apc_wasted: Image,
    crane_wasted: Image,
    robot_die: [4][teams][10]Image,
    robot_melt: [teams][17]Image,
    robot_flip: [teams][33]Image,
    rock_mid: [2][planets][8]Image,
    rock_small: [planets][16]Image,
    rock_large: [2][planets][12]Image,
    map_object: [map_objects]Image,
    bridge_debris: [planets][12]Image,
    /// [tank, jeep][planet][direction][fade]
    track: [2][planets][dirs][3]Image,
    /// [planet][kind][frame]
    tank_dirt: [planets][2][6]Image,
    track_dust: [dirs][7]Image,
    track_spark: [dirs][4]Image,
    tank_oil: [3][3]Image,
    ground_spark: [6]Image,
};

pub const Sprites = struct {
    // Map items.
    flag: [teams][4]Image,
    grenades: Image,
    rockets: Image,
    map_object: [map_objects]Image,
    hut: [planets]Image,
    /// Rock tiles (6x6 sheet of 16x16 pieces).
    rocks: [planets]Image,

    // Buildings.
    level: [k.max_building_levels]Image,
    exhaust: [13]Image,
    little_exhaust: [4]Image,
    fort: Fort,
    radar: Radar,
    robot_factory: RobotFactory,
    vehicle_factory: VehicleFactory,
    repair: Repair,
    bridge: [planets]Image,

    // Units.
    init_place: [3]Image,
    cannon: [k.Cannon.count]CannonSprites,
    vehicle: [k.Vehicle.count]VehicleSprites,
    jeep: Jeep,
    crane: Crane,
    robot: RobotSprites,
    fx: EffectSprites,

    /// Load everything (kept in the assets' arena).
    pub fn load(a: *Assets) Error!*Sprites {
        const s = try a.allocator().create(Sprites);
        const none = a.nothing;
        s.* = .{
            .flag = undefined,
            .grenades = undefined,
            .rockets = undefined,
            .map_object = undefined,
            .hut = undefined,
            .rocks = undefined,
            .level = undefined,
            .exhaust = undefined,
            .little_exhaust = undefined,
            .fort = undefined,
            .radar = undefined,
            .robot_factory = undefined,
            .vehicle_factory = undefined,
            .repair = undefined,
            .bridge = undefined,
            .init_place = undefined,
            .cannon = undefined,
            .vehicle = @splat(.{
                .base = @splat(@splat(@splat(none))),
                .damaged = @splat(@splat(@splat(none))),
                .top = @splat(@splat(none)),
                .wasted = @splat(none),
            }),
            .jeep = undefined,
            .crane = undefined,
            .robot = undefined,
            .fx = undefined,
        };
        const l: Loader = .{ .a = a };
        try s.loadItems(l);
        try s.loadBuildings(l);
        try s.loadCannons(l);
        try s.loadVehicles(l);
        try s.loadRobots(l);
        try s.loadEffects(l);
        return s;
    }

    fn loadItems(s: *Sprites, l: Loader) Error!void {
        s.flag = try l.teamFrames(4, "other/flag_{s}_{d}.png", .{}, .file);
        s.grenades = try l.one("other/map_items/grenades.png", .{});
        s.rockets = try l.one("other/map_items/rockets.png", .{});
        s.map_object = try l.seq(map_objects, "other/map_items/map_object{d}.png", .{});
        s.hut = try l.perPlanet("other/map_items/hut_{s}.png");
        s.rocks = try l.perPlanet("planets/rocks_{s}.png");
    }

    fn loadBuildings(s: *Sprites, l: Loader) Error!void {
        // (level_N counts from 1)
        for (&s.level, 0..) |*lv, i| lv.* = try l.one("buildings/level_{d}.bmp", .{i + 1});
        s.exhaust = try l.seq(13, "buildings/exhaust_{d}.png", .{});
        s.little_exhaust = try l.seq(4, "buildings/little_exhaust_{d}.png", .{});

        const overlay = try l.one("buildings/fort/destroyed_overlay.png", .{});
        s.fort = .{
            .front = try l.perPlanet("buildings/fort/fort_{s}_front.png"),
            .back = try l.perPlanet("buildings/fort/fort_{s}_back.png"),
            .front_destroyed = try l.perPlanet("buildings/fort/fort_{s}_front_destroyed.png"),
            .back_destroyed = try l.perPlanet("buildings/fort/fort_{s}_back_destroyed.png"),
            .front_destroyed_overlay = undefined,
            .back_destroyed_overlay = undefined,
            .flag = try l.teamFrames(4, "buildings/fort/flag_{s}_n{d:0>2}.png", .{}, .file),
        };
        for (0..planets) |p| {
            s.fort.front_destroyed_overlay[p] = try l.a.composite(s.fort.front_destroyed[p], overlay, 0, 0);
            s.fort.back_destroyed_overlay[p] = try l.a.composite(s.fort.back_destroyed[p], overlay, 0, 0);
        }

        s.radar = .{
            .base = try l.teamBases(try l.perPlanet("buildings/radar/base_{s}.png"), try l.teamsOf("buildings/radar/{s}.png", .{}, .nothing), 0, 32),
            .destroyed = try l.perPlanet("buildings/radar/base_destroyed_{s}.png"),
            .box_spinner = try l.seq(12, "buildings/radar/box_spinner_{d}.png", .{}),
            .dish = try l.seq(8, "buildings/radar/dish_{d}.png", .{}),
            .front_light = try l.seq(2, "buildings/radar/front_light_{d}.png", .{}),
            .side_light = try l.seq(2, "buildings/radar/side_light_{d}.png", .{}),
        };
        s.robot_factory = .{
            .base = try l.teamBases(try l.perPlanet("buildings/robot/base_{s}.png"), try l.teamsOf("buildings/robot/{s}.png", .{}, .nothing), 16, 64),
            .destroyed = try l.teamBases(try l.perPlanet("buildings/robot/base_destroyed_{s}.png"), try l.teamsOf("buildings/robot/{s}_destroyed.png", .{}, .nothing), 16, 64),
            .spin = try l.seq(8, "buildings/robot/spin_{d}.png", .{}),
            .green_box = try l.seq(6, "buildings/robot/green_box_{d}.png", .{}),
            .robot = try l.seq(2, "buildings/robot/robot_{d}.png", .{}),
            .light = try l.seq(2, "buildings/robot/light_{d}.png", .{}),
            .double_light = try l.seq(2, "buildings/robot/double_light_{d}.png", .{}),
        };
        s.vehicle_factory = .{
            .base = try l.teamBases(try l.perPlanet("buildings/vehicle/base_{s}.png"), try l.teamsOf("buildings/vehicle/{s}.png", .{}, .nothing), 32, 48),
            .destroyed = try l.teamBases(try l.perPlanet("buildings/vehicle/base_destroyed_{s}.png"), try l.teamsOf("buildings/vehicle/{s}_destroyed.png", .{}, .nothing), 32, 48),
            .spin = try l.seq(8, "buildings/vehicle/spin_{d}.png", .{}),
            .vent = try l.seq(4, "buildings/vehicle/vent_{d}.png", .{}),
            .lights = try l.seq(2, "buildings/vehicle/lights_{d}.png", .{}),
            .tank = try l.seq(2, "buildings/vehicle/tank_{d}.png", .{}),
            .bulb = try l.seq(2, "buildings/vehicle/bulb_{d}.png", .{}),
        };
        s.repair = .{
            .base = try l.teamBases(try l.perPlanet("buildings/repair/base_{s}.png"), try l.teamsOf("buildings/repair/{s}.png", .{}, .nothing), 0, 48),
            .destroyed = try l.perPlanet("buildings/repair/base_destroyed_{s}.png"),
            .smoke_stack = try l.seq(5, "buildings/repair/smoke_stack_{d}.png", .{}),
            .text_box = try l.seq(3, "buildings/repair/text_box_{d}.png", .{}),
            .bulb = try l.seq(2, "buildings/repair/bulb_{d}.png", .{}),
            .side_light = try l.seq(2, "buildings/repair/side_light_{d}.png", .{}),
            .front_light = try l.seq(2, "buildings/repair/front_light_{d}.png", .{}),
        };
        s.bridge = try l.perPlanet("planets/bridge_{s}.png");
    }

    fn loadCannons(s: *Sprites, l: Loader) Error!void {
        s.init_place = try l.seq(3, "units/cannons/init-place_n{d:0>2}.png", .{});
        try s.loadCannon(l, .gatling, "gatling");
        try s.loadCannon(l, .howitzer, "howitzer");
        try s.loadCannon(l, .gun, "gun");
        try s.loadCannon(l, .missile_cannon, "missile_cannon");
    }

    fn loadCannon(s: *Sprites, l: Loader, comptime kind: k.Cannon, comptime name: []const u8) Error!void {
        const cs = &s.cannon[@intFromEnum(kind)];
        const base = "units/cannons/" ++ name ++ "/";
        // The unmanned cannon.
        switch (kind) {
            .gatling, .howitzer => cs.passive[0] = try l.dirImages(base ++ "empty_r{d:0>3}.png"),
            .gun => cs.passive[0] = @splat(try l.one(base ++ "empty.png", .{})),
            .missile_cannon => cs.passive[0] = @splat(try l.one(base ++ "empty_null.png", .{})),
        }
        cs.wasted = if (kind == .missile_cannon) try l.teamsOf(base ++ "wasted_{s}.png", .{}, .nothing) else @splat(try l.one(base ++ "wasted.png", .{}));
        cs.place = try l.teamFrames(4, base ++ "place_{s}_n{d:0>2}.png", .{}, .nothing);
        cs.place[0] = @splat(cs.passive[0][4]);
        switch (kind) {
            // Two frames: at rest and firing.
            .gatling, .howitzer => for (0..dirs) |d| {
                const f = try l.teamFrames(2, base ++ "fire_{s}_r{d:0>3}_n{d:0>2}.png", .{angle(d)}, .nothing);
                for (1..teams) |t| {
                    cs.passive[t][d] = f[t][0];
                    cs.fire[t][d] = f[t][1];
                }
            },
            .gun, .missile_cannon => {
                const f = try l.teamDirs(base ++ "equiped_{s}_r{d:0>3}.png");
                for (1..teams) |t| {
                    cs.passive[t] = f[t];
                    cs.fire[t] = f[t];
                }
            },
        }
        cs.fire[0] = cs.passive[0];
    }

    fn loadVehicles(s: *Sprites, l: Loader) Error!void {
        // Light, medium and heavy tanks: art for four directions, the
        // opposite ones use the same pictures with the tracks reversed.
        inline for (.{ .{ k.Vehicle.light, "light", "empty.png" }, .{ k.Vehicle.medium, "medium", "empty_null.png" }, .{ k.Vehicle.heavy, "heavy", "empty.png" } }) |v| {
            const vs = &s.vehicle[@intFromEnum(v[0])];
            const base = "units/vehicles/" ++ v[1] ++ "/";
            const empty = try l.one(base ++ v[2], .{});
            vs.base[0] = @splat(@splat(empty));
            vs.damaged[0] = @splat(@splat(empty));
            for ([_]usize{ 0, 1, 2, 7 }) |d| {
                const opposite = if (d == 7) 3 else d + 4;
                const frames = try l.teamFrames(3, base ++ "base_{s}_r{d:0>3}_n{d:0>2}.png", .{angle(d)}, .nothing);
                const damaged = try l.teamFrames(3, base ++ "base_damaged_{s}_r{d:0>3}_n{d:0>2}.png", .{angle(d)}, .nothing);
                for (1..teams) |t| for (0..3) |f| {
                    vs.base[t][d][f] = frames[t][f];
                    vs.base[t][opposite][2 - f] = frames[t][f];
                    vs.damaged[t][d][f] = damaged[t][f];
                    vs.damaged[t][opposite][2 - f] = damaged[t][f];
                };
            }
            switch (v[0]) {
                .light => vs.top = @splat(try l.dirImages(base ++ "top_r{d:0>3}.png")),
                .medium => vs.top = @splat(try l.dirImages(base ++ "topf_r{d:0>3}.png")),
                else => vs.top = try l.teamDirs(base ++ "top_{s}_r{d:0>3}.png"),
            }
        }
        {
            const vs = &s.vehicle[@intFromEnum(k.Vehicle.jeep)];
            vs.wasted = @splat(try l.one("units/vehicles/jeep/wasted.png", .{}));
            for (0..dirs) |d| vs.base[0][d] = @splat(try l.one("units/vehicles/jeep/empty_r{d:0>3}.png", .{angle(d)}));
            const frames = try l.teamDirFrames(2, "units/vehicles/jeep/base_{s}_r{d:0>3}_n{d:0>2}.png");
            for (1..teams) |t| for (0..dirs) |d| {
                vs.base[t][d][0] = frames[t][d][0];
                vs.base[t][d][1] = frames[t][d][1];
            };
            for (0..dirs) |d| {
                s.jeep.under[d] = if (d == 2 or d == 6) @splat(l.a.nothing) else try l.seq(4, "units/vehicles/jeep/under_r{d:0>3}_n{d:0>2}.png", .{angle(d)});
                s.jeep.gun[d] = try l.one("units/vehicles/jeep/fire_r{d:0>3}_n00.png", .{angle(d)});
                s.jeep.gun_fire[d] = try l.one("units/vehicles/jeep/fire_r{d:0>3}_n01.png", .{angle(d)});
            }
        }
        inline for (.{ .{ k.Vehicle.apc, "apc", "empty.png" }, .{ k.Vehicle.missile_launcher, "missile_launcher", "empty_null.png" }, .{ k.Vehicle.crane, "crane", "empty_null.png" } }) |v| {
            const vs = &s.vehicle[@intFromEnum(v[0])];
            const base = "units/vehicles/" ++ v[1] ++ "/";
            vs.base[0] = @splat(@splat(try l.one(base ++ v[2], .{})));
            const frames = try l.teamDirFrames(3, base ++ "base_{s}_r{d:0>3}_n{d:0>2}.png");
            for (1..teams) |t| vs.base[t] = frames[t];
            vs.wasted = try l.teamsOf(base ++ "wasted_{s}.png", .{}, if (v[0] == .crane) .file else .nothing);
            if (v[0] != .crane) vs.wasted[0] = vs.wasted[@intFromEnum(Team.red)];
        }
        s.vehicle[@intFromEnum(k.Vehicle.apc)].top = @splat(try l.dirImages("units/vehicles/apc/top_r{d:0>3}.png"));
        s.vehicle[@intFromEnum(k.Vehicle.missile_launcher)].top = try l.teamDirs("units/vehicles/missile_launcher/top_{s}_r{d:0>3}.png");
        // The crane's arm is drawn facing away.
        for (0..dirs) |d| s.crane.arm[d] = try l.one("units/vehicles/crane/crane_r{d:0>3}.png", .{angle((d + 4) % dirs)});
        for (0..8) |i| {
            s.crane.hook[i] = try l.one("units/vehicles/crane/hook_n{d:0>2}.png", .{i});
            s.crane.hook[15 - i] = s.crane.hook[i];
        }
    }

    fn loadEffects(s: *Sprites, l: Loader) Error!void {
        try loadEffectsImpl(s, l);
    }

    fn loadRobots(s: *Sprites, l: Loader) Error!void {
        const r = &s.robot;
        const dir = "units/robots/";
        r.null_img = try l.one(dir ++ "null.png", .{});
        r.stand = try l.teamDirs(dir ++ "stand_{s}_r{d:0>3}.png");
        r.stand[0] = @splat(r.null_img);
        r.walk = try l.teamDirFrames(4, dir ++ "walk_{s}_r{d:0>3}_n{d:0>2}.png");
        r.throw = try l.teamDirFrames(4, dir ++ "throw_{s}_r{d:0>3}_n{d:0>2}.png");
        r.beer = try l.teamFrames(10, dir ++ "beer_{s}_n{d:0>2}.png", .{}, .nothing);
        r.cigarette = try l.teamFrames(11, dir ++ "cigarette_{s}_n{d:0>2}.png", .{}, .nothing);
        r.full_area_scan = try l.teamFrames(12, dir ++ "full_area_scan_{s}_n{d:0>2}.png", .{}, .nothing);
        r.head_stretch = try l.teamFrames(11, dir ++ "head_stretch_{s}_n{d:0>2}.png", .{}, .nothing);
        r.pickup_up = try l.teamFrames(4, dir ++ "pickup-up_{s}_n{d:0>2}.png", .{}, .nothing);
        r.pickup_down = try l.teamFrames(4, dir ++ "pickup-down_{s}_n{d:0>2}.png", .{}, .nothing);
        r.fire = @splat(@splat(@splat(@splat(l.a.nothing))));
        inline for (.{
            .{ k.Robot.grunt, "grunt", 5 },
            .{ k.Robot.psycho, "psycho", 2 },
            .{ k.Robot.sniper, "grunt", 5 },
            .{ k.Robot.tough, "tough", 3 },
            .{ k.Robot.pyro, "pyro", 3 },
            .{ k.Robot.laser, "laser", 3 },
        }) |e| {
            const f = try l.teamDirFrames(e[2], dir ++ e[1] ++ "/fire_{s}_r{d:0>3}_n{d:0>2}.png");
            for (0..teams) |t| for (0..dirs) |d| for (0..e[2]) |i| {
                r.fire[@intFromEnum(e[0])][t][d][i] = f[t][d][i];
            };
        }
        r.tank_robot = try l.teamDirFrames(2, dir ++ "tank_fire_{s}_r{d:0>3}_n{d:0>2}.png");
        r.tank_robot[0] = r.tank_robot[@intFromEnum(Team.red)];
        for (0..dirs) |d| r.tank_lid[d] = try l.seq(3, "units/vehicles/tank_lid_r{d:0>3}_n{d:0>2}.png", .{angle(d)});
    }
};

fn planetName(p: usize) []const u8 {
    return @tagName(@as(Planet, @enumFromInt(p)));
}

fn loadEffectsImpl(s: *Sprites, l: Loader) Error!void {
    const f = &s.fx;
    f.laser_bullet = try l.seq(2, "units/robots/laser/bullet_n{d:0>2}.png", .{});
    f.flame_bullet = try l.seq(4, "units/robots/pyro/bullet_n{d:0>2}.png", .{});
    f.pyro_fire = @splat(@splat(l.a.nothing));
    for (0..5) |i| for (0..([5]usize{ 4, 4, 4, 6, 6 })[i]) |j| {
        f.pyro_fire[i][j] = try l.one("other/fire/fire{d}_n{d:0>2}.png", .{ i, j });
    };
    f.light_init_fire = try l.seq(4, "units/vehicles/light/initfire_n{d:0>2}.png", .{});
    f.light_bullet = try l.one("units/vehicles/light/bullet.png", .{});
    const de = "units/vehicles/death_effects/";
    f.big_smoke = try l.seq(4, de ++ "big_smoke_n{d:0>2}.png", .{});
    f.little_fire = try l.seq(4, de ++ "little_fire_n{d:0>2}.png", .{});
    f.small_fire_smoke = try l.seq(4, de ++ "small_fire_smoke_n{d:0>2}.png", .{});
    f.fire = try l.seq(4, de ++ "fire_n{d:0>2}.png", .{});
    f.spark = try l.seq(6, de ++ "spark_n{d:0>2}.png", .{});
    f.side_explosion = try l.seq(7, "other/explosions/side_explosion_n{d:0>2}.png", .{});
    f.unit_particle = try l.seq(20, "other/particles/unit_particle_n{d:0>2}.png", .{});
    f.tough_bullet = try l.seq(2, "units/robots/tough/bullet_n{d:0>2}.png", .{});
    f.mushroom = try l.seq(12, "units/robots/tough/mushroom_n{d:0>2}.png", .{});
    f.tough_smoke = try l.seq(8, "units/robots/tough/smoke_n{d:0>2}.png", .{});
    f.mo_bullet = try l.one("units/vehicles/missile_launcher/bullet.png", .{});
    f.mc_bullet = try l.one("units/cannons/missile_cannon/bullet.png", .{});
    f.grenade = try l.seq(4, "other/grenades/grenade_n{d:0>2}.png", .{});
    f.light_turret = try l.seq(8, "units/vehicles/light/top_pop_n{d:0>2}.png", .{});
    f.medium_turret = try l.seq(8, "units/vehicles/medium/top_pop_n{d:0>2}.png", .{});
    f.heavy_turret = try l.teamFrames(8, "units/vehicles/heavy/top_pop_{s}_n{d:0>2}.png", .{}, .nothing);
    for (0..2) |i| f.building_piece[i] = try l.seq(12, "buildings/death_effects/piece{d}_n{d:0>2}.png", .{i});
    for (0..5) |i| f.fort_piece[i] = try l.seq(12, "buildings/death_effects/fort_piece{d}_n{d:0>2}.png", .{i});
    f.cannon_wasted = .{
        s.cannon[@intFromEnum(k.Cannon.gatling)].wasted[0],
        s.cannon[@intFromEnum(k.Cannon.gun)].wasted[0],
        s.cannon[@intFromEnum(k.Cannon.howitzer)].wasted[0],
        try l.one("units/cannons/missile_cannon/wasted.png", .{}),
    };
    f.jeep_wasted = s.vehicle[@intFromEnum(k.Vehicle.jeep)].wasted[0];
    f.missile_launcher_wasted = try l.one("units/vehicles/missile_launcher/wasted.png", .{});
    f.apc_wasted = try l.one("units/vehicles/apc/wasted.png", .{});
    f.crane_wasted = try l.one("units/vehicles/crane/wasted_null.png", .{});
    f.robot_die = @splat(@splat(@splat(l.a.nothing)));
    inline for (0..4, .{ 10, 10, 10, 8 }) |d, n| {
        const frames = try l.teamFrames(n, std.fmt.comptimePrint("units/robots/die{d}", .{d + 1}) ++ "_{s}_n{d:0>2}.png", .{}, .nothing);
        for (0..teams) |t| for (0..n) |i| {
            f.robot_die[d][t][i] = frames[t][i];
        };
    }
    f.robot_melt = try l.teamFrames(17, "units/robots/melt_{s}_n{d:0>2}.png", .{}, .nothing);
    f.robot_flip = try l.teamFrames(33, "units/robots/die5_{s}_n{d:0>2}.png", .{}, .nothing);
    for (0..planets) |p| {
        const pn = planetName(p);
        const re = "planets/rock_effects/";
        f.rock_mid[0][p] = try l.seq(8, re ++ "debri_mid0_{s}_n{d:0>2}.png", .{pn});
        f.rock_mid[1][p] = try l.seq(8, re ++ "debri_mid1_{s}_n{d:0>2}.png", .{pn});
        f.rock_small[p] = try l.seq(16, re ++ "debri_small_{s}_n{d:0>2}.png", .{pn});
        f.rock_large[0][p] = try l.seq(12, re ++ "debri_large0_{s}_n{d:0>2}.png", .{pn});
        const p_enum: Planet = @enumFromInt(p);
        f.rock_large[1][p] = if (p_enum == .desert or p_enum == .city) @splat(l.a.nothing) else try l.seq(12, re ++ "debri_large1_{s}_n{d:0>2}.png", .{pn});
        f.bridge_debris[p] = try l.seq(12, "planets/bridge_effects/debri_large_{s}_n{d:0>2}.png", .{pn});
        // Tracks: none in the city, jeeps only in the desert.
        f.track[0][p] = @splat(@splat(l.a.nothing));
        f.track[1][p] = @splat(@splat(l.a.nothing));
        for (0..2) |t| {
            if (p_enum == .city or (t == 1 and p_enum != .desert)) continue;
            for (0..4) |d| {
                const kind = if (t == 0) "tank" else "jeep";
                f.track[t][p][d] = try l.seq(3, "units/vehicles/track_effects/{s}_track_{s}_r{d:0>3}_n{d:0>2}.png", .{ kind, pn, angle(d) });
                f.track[t][p][d + 4] = f.track[t][p][d];
            }
        }
        const dirts: usize, const frames: usize = switch (p_enum) {
            .jungle => .{ 1, 6 },
            .city => .{ 0, 0 },
            else => .{ 2, 5 },
        };
        f.tank_dirt[p] = @splat(@splat(l.a.nothing));
        for (0..dirts) |d| for (0..frames) |i| {
            f.tank_dirt[p][d][i] = try l.one("units/vehicles/tank_dirt/tank_dirt_{d}_{s}_n{d:0>2}.png", .{ d, pn, i });
        };
    }
    f.map_object = try l.seq(map_objects, "other/map_items/no_shadow{d}.png", .{});
    for (0..dirs) |d| {
        f.track_dust[d] = try l.seq(7, "units/vehicles/track_dust_r{d:0>3}_n{d:0>2}.png", .{angle(d)});
        f.track_spark[d] = try l.seq(4, "units/vehicles/track_spark_r{d:0>3}_n{d:0>2}.png", .{angle(d)});
    }
    for (0..3) |i| f.tank_oil[i] = try l.seq(3, "units/vehicles/tank_oil_{d}_n{d:0>2}.png", .{i});
    f.ground_spark = try l.seq(6, "units/vehicles/ground_spark_n{d:0>2}.png", .{});
}

test "load all sprites" {
    const a = try Assets.init(std.testing.allocator, "bin/assets");
    defer a.deinit();
    const s = try Sprites.load(a);
    try std.testing.expectEqual(0, a.missing);
    try std.testing.expect(s.radar.base[0][@intFromEnum(Team.blue)].w > 1);
    try std.testing.expect(s.robot.fire[@intFromEnum(k.Robot.laser)][1][7][2].w > 1);
}
