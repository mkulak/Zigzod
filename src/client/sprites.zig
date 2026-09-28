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

/// Per planet, per team versions of a building: the planet's base with
/// the team's color plate on it (none for neutral).
fn teamBases(a: *Assets, base: [planets]Image, plates: [teams]Image, x: i32, y: i32) Error![planets][teams]Image {
    var out: [planets][teams]Image = undefined;
    for (0..planets) |p| {
        out[p][0] = base[p];
        for (1..teams) |t| out[p][t] = try a.composite(base[p], plates[t], x, y);
    }
    return out;
}

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
        try a.fill(s, item_art);
        try s.loadBuildings(a);
        try s.loadCannons(a);
        try s.loadVehicles(a);
        try s.loadRobots(a);
        try s.loadEffects(a);
        return s;
    }

    fn loadBuildings(s: *Sprites, a: *Assets) Error!void {
        try a.fill(s, building_art);
        // (level_N counts from 1)
        for (&s.level, 0..) |*lv, i| lv.* = try a.image("buildings/level_{d}.bmp", .{i + 1});

        try a.fill(&s.fort, fort_art);
        const overlay = try a.image("buildings/fort/destroyed_overlay.png", .{});
        for (0..planets) |p| {
            s.fort.front_destroyed_overlay[p] = try a.composite(s.fort.front_destroyed[p], overlay, 0, 0);
            s.fort.back_destroyed_overlay[p] = try a.composite(s.fort.back_destroyed[p], overlay, 0, 0);
        }

        // Team colored buildings: the team's plate put on the planet's base.
        try a.fill(&s.radar, radar_art);
        s.radar.base = try teamBases(
            a,
            try a.load([planets]Image, "buildings/radar/base_{planet}.png", .nothing),
            try a.load([teams]Image, "buildings/radar/{team}.png", .nothing),
            0,
            32,
        );
        try a.fill(&s.robot_factory, robot_factory_art);
        inline for (.{ .{ "base", "" }, .{ "destroyed", "_destroyed" } }) |part| {
            @field(s.robot_factory, part[0]) = try teamBases(
                a,
                try a.load([planets]Image, "buildings/robot/base" ++ part[1] ++ "_{planet}.png", .nothing),
                try a.load([teams]Image, "buildings/robot/{team}" ++ part[1] ++ ".png", .nothing),
                16,
                64,
            );
        }
        try a.fill(&s.vehicle_factory, vehicle_factory_art);
        inline for (.{ .{ "base", "" }, .{ "destroyed", "_destroyed" } }) |part| {
            @field(s.vehicle_factory, part[0]) = try teamBases(
                a,
                try a.load([planets]Image, "buildings/vehicle/base" ++ part[1] ++ "_{planet}.png", .nothing),
                try a.load([teams]Image, "buildings/vehicle/{team}" ++ part[1] ++ ".png", .nothing),
                32,
                48,
            );
        }
        try a.fill(&s.repair, repair_art);
        s.repair.base = try teamBases(
            a,
            try a.load([planets]Image, "buildings/repair/base_{planet}.png", .nothing),
            try a.load([teams]Image, "buildings/repair/{team}.png", .nothing),
            0,
            48,
        );
    }

    fn loadCannons(s: *Sprites, a: *Assets) Error!void {
        s.init_place = try a.load([3]Image, "units/cannons/init-place_n{frame}.png", .nothing);
        try s.loadCannon(a, .gatling, "gatling");
        try s.loadCannon(a, .howitzer, "howitzer");
        try s.loadCannon(a, .gun, "gun");
        try s.loadCannon(a, .missile_cannon, "missile_cannon");
    }

    fn loadCannon(s: *Sprites, a: *Assets, comptime kind: k.Cannon, comptime name: []const u8) Error!void {
        const cs = &s.cannon[@intFromEnum(kind)];
        const base = "units/cannons/" ++ name ++ "/";
        // The unmanned cannon.
        switch (kind) {
            .gatling, .howitzer => cs.passive[0] = try a.load([dirs]Image, base ++ "empty_r{angle}.png", .nothing),
            .gun => cs.passive[0] = @splat(try a.image(base ++ "empty.png", .{})),
            .missile_cannon => cs.passive[0] = @splat(try a.image(base ++ "empty_null.png", .{})),
        }
        cs.wasted = if (kind == .missile_cannon)
            try a.load([teams]Image, base ++ "wasted_{team}.png", .nothing)
        else
            @splat(try a.image(base ++ "wasted.png", .{}));
        cs.place = try a.load([teams][4]Image, base ++ "place_{team}_n{frame}.png", .nothing);
        cs.place[0] = @splat(cs.passive[0][4]);
        switch (kind) {
            // Two frames: at rest and firing.
            .gatling, .howitzer => {
                const f = try a.load([teams][dirs][2]Image, base ++ "fire_{team}_r{angle}_n{frame}.png", .nothing);
                for (1..teams) |t| for (0..dirs) |d| {
                    cs.passive[t][d] = f[t][d][0];
                    cs.fire[t][d] = f[t][d][1];
                };
            },
            .gun, .missile_cannon => {
                const f = try a.load([teams][dirs]Image, base ++ "equiped_{team}_r{angle}.png", .nothing);
                for (1..teams) |t| {
                    cs.passive[t] = f[t];
                    cs.fire[t] = f[t];
                }
            },
        }
        cs.fire[0] = cs.passive[0];
    }

    fn loadVehicles(s: *Sprites, a: *Assets) Error!void {
        const none = a.nothing;
        s.vehicle = @splat(.{
            .base = @splat(@splat(@splat(none))),
            .damaged = @splat(@splat(@splat(none))),
            .top = @splat(@splat(none)),
            .wasted = @splat(none),
        });
        // Light, medium and heavy tanks: art for four directions, the
        // opposite ones use the same pictures with the tracks reversed.
        inline for (.{ .{ k.Vehicle.light, "light", "empty.png" }, .{ k.Vehicle.medium, "medium", "empty_null.png" }, .{ k.Vehicle.heavy, "heavy", "empty.png" } }) |v| {
            const vs = &s.vehicle[@intFromEnum(v[0])];
            const base = "units/vehicles/" ++ v[1] ++ "/";
            const empty = try a.image(base ++ v[2], .{});
            vs.base[0] = @splat(@splat(empty));
            vs.damaged[0] = @splat(@splat(empty));
            for ([_]usize{ 0, 1, 2, 7 }) |d| {
                const opposite = if (d == 7) 3 else d + 4;
                const frames = try a.loadAt([teams][3]Image, base ++ "base_{team}_r{angle}_n{frame}.png", .nothing, .{ .angle = d });
                const damaged = try a.loadAt([teams][3]Image, base ++ "base_damaged_{team}_r{angle}_n{frame}.png", .nothing, .{ .angle = d });
                for (1..teams) |t| for (0..3) |f| {
                    vs.base[t][d][f] = frames[t][f];
                    vs.base[t][opposite][2 - f] = frames[t][f];
                    vs.damaged[t][d][f] = damaged[t][f];
                    vs.damaged[t][opposite][2 - f] = damaged[t][f];
                };
            }
            switch (v[0]) {
                .light => vs.top = @splat(try a.load([dirs]Image, base ++ "top_r{angle}.png", .nothing)),
                .medium => vs.top = @splat(try a.load([dirs]Image, base ++ "topf_r{angle}.png", .nothing)),
                else => vs.top = try a.load([teams][dirs]Image, base ++ "top_{team}_r{angle}.png", .nothing),
            }
        }
        {
            const vs = &s.vehicle[@intFromEnum(k.Vehicle.jeep)];
            vs.wasted = @splat(try a.image("units/vehicles/jeep/wasted.png", .{}));
            const empty = try a.load([dirs]Image, "units/vehicles/jeep/empty_r{angle}.png", .nothing);
            for (&vs.base[0], empty) |*b, e| b.* = @splat(e);
            const frames = try a.load([teams][dirs][2]Image, "units/vehicles/jeep/base_{team}_r{angle}_n{frame}.png", .nothing);
            for (1..teams) |t| for (0..dirs) |d| {
                vs.base[t][d][0] = frames[t][d][0];
                vs.base[t][d][1] = frames[t][d][1];
            };
            try a.fill(&s.jeep, jeep_art);
            // No wheels show driving up or down.
            for (&s.jeep.under, 0..) |*u, d| u.* = if (d == 2 or d == 6)
                @splat(none)
            else
                try a.loadAt([4]Image, "units/vehicles/jeep/under_r{angle}_n{frame}.png", .nothing, .{ .angle = d });
        }
        inline for (.{ .{ k.Vehicle.apc, "apc", "empty.png" }, .{ k.Vehicle.missile_launcher, "missile_launcher", "empty_null.png" }, .{ k.Vehicle.crane, "crane", "empty_null.png" } }) |v| {
            const vs = &s.vehicle[@intFromEnum(v[0])];
            const base = "units/vehicles/" ++ v[1] ++ "/";
            vs.base[0] = @splat(@splat(try a.image(base ++ v[2], .{})));
            const frames = try a.load([teams][dirs][3]Image, base ++ "base_{team}_r{angle}_n{frame}.png", .nothing);
            for (1..teams) |t| vs.base[t] = frames[t];
            vs.wasted = try a.load([teams]Image, base ++ "wasted_{team}.png", if (v[0] == .crane) .file else .red);
        }
        s.vehicle[@intFromEnum(k.Vehicle.apc)].top = @splat(try a.load([dirs]Image, "units/vehicles/apc/top_r{angle}.png", .nothing));
        s.vehicle[@intFromEnum(k.Vehicle.missile_launcher)].top = try a.load([teams][dirs]Image, "units/vehicles/missile_launcher/top_{team}_r{angle}.png", .nothing);
        // The crane's arm is drawn facing away.
        const arm = try a.load([dirs]Image, "units/vehicles/crane/crane_r{angle}.png", .nothing);
        for (&s.crane.arm, 0..) |*arm_d, d| arm_d.* = arm[(d + 4) % dirs];
        // The hook goes down and back up.
        const hook = try a.load([8]Image, "units/vehicles/crane/hook_n{frame}.png", .nothing);
        for (hook, 0..) |h, i| {
            s.crane.hook[i] = h;
            s.crane.hook[15 - i] = h;
        }
    }

    fn loadRobots(s: *Sprites, a: *Assets) Error!void {
        const r = &s.robot;
        try a.fill(r, robot_art);
        r.stand[0] = @splat(r.null_img);
        r.fire = @splat(@splat(@splat(@splat(a.nothing))));
        inline for (.{
            .{ k.Robot.grunt, "grunt", 5 },
            .{ k.Robot.psycho, "psycho", 2 },
            .{ k.Robot.sniper, "grunt", 5 },
            .{ k.Robot.tough, "tough", 3 },
            .{ k.Robot.pyro, "pyro", 3 },
            .{ k.Robot.laser, "laser", 3 },
        }) |e| {
            const f = try a.load([teams][dirs][e[2]]Image, "units/robots/" ++ e[1] ++ "/fire_{team}_r{angle}_n{frame}.png", .nothing);
            for (0..teams) |t| for (0..dirs) |d| {
                r.fire[@intFromEnum(e[0])][t][d][0..e[2]].* = f[t][d];
            };
        }
    }

    fn loadEffects(s: *Sprites, a: *Assets) Error!void {
        const f = &s.fx;
        const none = a.nothing;
        try a.fill(f, effect_art);
        // Pyro fires: 5 kinds with 4, 4, 4, 6, 6 frames.
        f.pyro_fire = @splat(@splat(none));
        inline for (0..5, .{ 4, 4, 4, 6, 6 }) |i, n| {
            f.pyro_fire[i][0..n].* = try a.load([n]Image, std.fmt.comptimePrint("other/fire/fire{d}", .{i}) ++ "_n{frame}.png", .nothing);
        }
        // The dying robots: 10, 10, 10 and 8 frames.
        f.robot_die = @splat(@splat(@splat(none)));
        inline for (0..4, .{ 10, 10, 10, 8 }) |d, n| {
            const frames = try a.load([teams][n]Image, std.fmt.comptimePrint("units/robots/die{d}", .{d + 1}) ++ "_{team}_n{frame}.png", .nothing);
            for (0..teams) |t| f.robot_die[d][t][0..n].* = frames[t];
        }
        f.cannon_wasted = .{
            s.cannon[@intFromEnum(k.Cannon.gatling)].wasted[0],
            s.cannon[@intFromEnum(k.Cannon.gun)].wasted[0],
            s.cannon[@intFromEnum(k.Cannon.howitzer)].wasted[0],
            try a.image("units/cannons/missile_cannon/wasted.png", .{}),
        };
        f.jeep_wasted = s.vehicle[@intFromEnum(k.Vehicle.jeep)].wasted[0];
        f.rock_large[0] = try a.load([planets][12]Image, "planets/rock_effects/debri_large0_{planet}_n{frame}.png", .nothing);

        // Planets differ in what debris, tracks and dirt they have.
        for (0..planets) |p| {
            const planet: Planet = @enumFromInt(p);
            f.rock_large[1][p] = switch (planet) {
                .desert, .city => @splat(none),
                else => try a.loadAt([12]Image, "planets/rock_effects/debri_large1_{planet}_n{frame}.png", .nothing, .{ .planet = planet }),
            };
            // Tracks: none in the city, jeeps only in the desert; art for
            // four directions, the opposite ones look the same.
            f.track[0][p] = @splat(@splat(none));
            f.track[1][p] = @splat(@splat(none));
            if (planet != .city) {
                const tank = try a.loadAt([4][3]Image, "units/vehicles/track_effects/tank_track_{planet}_r{angle}_n{frame}.png", .nothing, .{ .planet = planet });
                f.track[0][p] = tank ++ tank;
            }
            if (planet == .desert) {
                const jeep = try a.loadAt([4][3]Image, "units/vehicles/track_effects/jeep_track_{planet}_r{angle}_n{frame}.png", .nothing, .{ .planet = planet });
                f.track[1][p] = jeep ++ jeep;
            }
            f.tank_dirt[p] = @splat(@splat(none));
            switch (planet) {
                .city => {},
                .jungle => f.tank_dirt[p][0] = try a.loadAt([6]Image, "units/vehicles/tank_dirt/tank_dirt_0_{planet}_n{frame}.png", .nothing, .{ .planet = planet }),
                else => {
                    const dirt = try a.loadAt([2][5]Image, "units/vehicles/tank_dirt/tank_dirt_{n}_{planet}_n{frame}.png", .nothing, .{ .planet = planet });
                    for (dirt, 0..) |d, i| f.tank_dirt[p][i][0..5].* = d;
                },
            }
        }
    }
};

// ---------------------------------------------------------------------------
// The tables (see "Where the art is" above)
// ---------------------------------------------------------------------------

const item_art = .{
    .flag = .{ "other/flag_{team}_{n}.png", .file },
    .grenades = "other/map_items/grenades.png",
    .rockets = "other/map_items/rockets.png",
    .map_object = "other/map_items/map_object{n}.png",
    .hut = "other/map_items/hut_{planet}.png",
    .rocks = "planets/rocks_{planet}.png",
};

const building_art = .{
    .exhaust = "buildings/exhaust_{n}.png",
    .little_exhaust = "buildings/little_exhaust_{n}.png",
    .bridge = "planets/bridge_{planet}.png",
};

const fort_art = .{
    .front = "buildings/fort/fort_{planet}_front.png",
    .back = "buildings/fort/fort_{planet}_back.png",
    .front_destroyed = "buildings/fort/fort_{planet}_front_destroyed.png",
    .back_destroyed = "buildings/fort/fort_{planet}_back_destroyed.png",
    .flag = .{ "buildings/fort/flag_{team}_n{frame}.png", .file },
};

const radar_art = .{
    .destroyed = "buildings/radar/base_destroyed_{planet}.png",
    .box_spinner = "buildings/radar/box_spinner_{n}.png",
    .dish = "buildings/radar/dish_{n}.png",
    .front_light = "buildings/radar/front_light_{n}.png",
    .side_light = "buildings/radar/side_light_{n}.png",
};

const robot_factory_art = .{
    .spin = "buildings/robot/spin_{n}.png",
    .green_box = "buildings/robot/green_box_{n}.png",
    .robot = "buildings/robot/robot_{n}.png",
    .light = "buildings/robot/light_{n}.png",
    .double_light = "buildings/robot/double_light_{n}.png",
};

const vehicle_factory_art = .{
    .spin = "buildings/vehicle/spin_{n}.png",
    .vent = "buildings/vehicle/vent_{n}.png",
    .lights = "buildings/vehicle/lights_{n}.png",
    .tank = "buildings/vehicle/tank_{n}.png",
    .bulb = "buildings/vehicle/bulb_{n}.png",
};

const repair_art = .{
    .destroyed = "buildings/repair/base_destroyed_{planet}.png",
    .smoke_stack = "buildings/repair/smoke_stack_{n}.png",
    .text_box = "buildings/repair/text_box_{n}.png",
    .bulb = "buildings/repair/bulb_{n}.png",
    .side_light = "buildings/repair/side_light_{n}.png",
    .front_light = "buildings/repair/front_light_{n}.png",
};

const jeep_art = .{
    .gun = "units/vehicles/jeep/fire_r{angle}_n00.png",
    .gun_fire = "units/vehicles/jeep/fire_r{angle}_n01.png",
};

const robot_art = .{
    .null_img = "units/robots/null.png",
    .stand = "units/robots/stand_{team}_r{angle}.png",
    .walk = "units/robots/walk_{team}_r{angle}_n{frame}.png",
    .throw = "units/robots/throw_{team}_r{angle}_n{frame}.png",
    .beer = "units/robots/beer_{team}_n{frame}.png",
    .cigarette = "units/robots/cigarette_{team}_n{frame}.png",
    .full_area_scan = "units/robots/full_area_scan_{team}_n{frame}.png",
    .head_stretch = "units/robots/head_stretch_{team}_n{frame}.png",
    .pickup_up = "units/robots/pickup-up_{team}_n{frame}.png",
    .pickup_down = "units/robots/pickup-down_{team}_n{frame}.png",
    .tank_robot = .{ "units/robots/tank_fire_{team}_r{angle}_n{frame}.png", .red },
    .tank_lid = "units/vehicles/tank_lid_r{angle}_n{frame}.png",
};

const effect_art = .{
    .laser_bullet = "units/robots/laser/bullet_n{frame}.png",
    .flame_bullet = "units/robots/pyro/bullet_n{frame}.png",
    .light_init_fire = "units/vehicles/light/initfire_n{frame}.png",
    .light_bullet = "units/vehicles/light/bullet.png",
    .big_smoke = "units/vehicles/death_effects/big_smoke_n{frame}.png",
    .little_fire = "units/vehicles/death_effects/little_fire_n{frame}.png",
    .small_fire_smoke = "units/vehicles/death_effects/small_fire_smoke_n{frame}.png",
    .fire = "units/vehicles/death_effects/fire_n{frame}.png",
    .spark = "units/vehicles/death_effects/spark_n{frame}.png",
    .side_explosion = "other/explosions/side_explosion_n{frame}.png",
    .unit_particle = "other/particles/unit_particle_n{frame}.png",
    .tough_bullet = "units/robots/tough/bullet_n{frame}.png",
    .mushroom = "units/robots/tough/mushroom_n{frame}.png",
    .tough_smoke = "units/robots/tough/smoke_n{frame}.png",
    .mo_bullet = "units/vehicles/missile_launcher/bullet.png",
    .mc_bullet = "units/cannons/missile_cannon/bullet.png",
    .grenade = "other/grenades/grenade_n{frame}.png",
    .light_turret = "units/vehicles/light/top_pop_n{frame}.png",
    .medium_turret = "units/vehicles/medium/top_pop_n{frame}.png",
    .heavy_turret = "units/vehicles/heavy/top_pop_{team}_n{frame}.png",
    .building_piece = "buildings/death_effects/piece{n}_n{frame}.png",
    .fort_piece = "buildings/death_effects/fort_piece{n}_n{frame}.png",
    .missile_launcher_wasted = "units/vehicles/missile_launcher/wasted.png",
    .apc_wasted = "units/vehicles/apc/wasted.png",
    .crane_wasted = "units/vehicles/crane/wasted_null.png",
    .robot_melt = "units/robots/melt_{team}_n{frame}.png",
    .robot_flip = "units/robots/die5_{team}_n{frame}.png",
    .rock_mid = "planets/rock_effects/debri_mid{n}_{planet}_n{frame}.png",
    .rock_small = "planets/rock_effects/debri_small_{planet}_n{frame}.png",
    .bridge_debris = "planets/bridge_effects/debri_large_{planet}_n{frame}.png",
    .map_object = "other/map_items/no_shadow{n}.png",
    .track_dust = "units/vehicles/track_dust_r{angle}_n{frame}.png",
    .track_spark = "units/vehicles/track_spark_r{angle}_n{frame}.png",
    .tank_oil = "units/vehicles/tank_oil_{n}_n{frame}.png",
    .ground_spark = "units/vehicles/ground_spark_n{frame}.png",
};

test "load all sprites" {
    const a = try Assets.init(std.testing.allocator, "bin/assets");
    defer a.deinit();
    const s = try Sprites.load(a);
    try std.testing.expectEqual(0, a.missing);
    try std.testing.expect(s.radar.base[0][@intFromEnum(Team.blue)].w > 1);
    try std.testing.expect(s.robot.fire[@intFromEnum(k.Robot.laser)][1][7][2].w > 1);
}
