//! Drawing objects and their animations (the client side `Process`,
//! `DoPreRender`, `DoRender` and `DoAfterEffects` of the C++ object
//! classes). Each object has a `Visual` with its animation state.
//!
//! Buildings are painted onto the ground and painted again when their look
//! changes; the parts units can walk behind are drawn over them afterwards.

const std = @import("std");
const game = @import("../game.zig");
const gfx = @import("gfx.zig");
const font = @import("font.zig");
const sprites_mod = @import("sprites.zig");
const terrain_mod = @import("terrain.zig");
const units = @import("units.zig");
const protocol = @import("../net/protocol.zig");
const effects = @import("effects.zig");

const k = game.constants;
const Object = game.object.Object;
const World = game.world.World;
const Image = gfx.Image;
const Canvas = gfx.Canvas;
const Sprites = sprites_mod.Sprites;

/// What a building looks like on the ground (to know when to paint again).
const Look = struct {
    destroyed: bool,
    owner: k.Team,
    /// Bridges: 0 intact, 1 damaged, 2 destroyed.
    damage: u8 = 0,
};

pub const Visual = struct {
    /// Animation counter and when it last advanced.
    frame: u32 = 0,
    last_frame_time: f64 = 0,
    /// Buildings: what is painted on the ground.
    stamped: ?Look = null,
    /// Robot factory lights.
    lights: [3]bool = @splat(false),
    /// Production (or repair) time left, as shown on the building.
    timer_seconds: i64 = -1,
    timer: ?Image = null,
    /// Destroyed forts pulse.
    fade: f64 = 0,
    fade_dir: f64 = 100,
    /// Repair stations: repairing until this time.
    repairing_until: ?f64 = null,
    repair_frame: u32 = 0,
    /// Bridges: intact, damaged and destroyed versions.
    bridge: ?[3]Image = null,
    /// Buildings burn when damaged.
    fires: effects.BuildingFires = .{ .max = 0 },
    unit: units.UnitVisual = .{},

    fn deinit(v: *Visual, gpa: std.mem.Allocator) void {
        if (v.timer) |t| t.deinit();
        if (v.bridge) |b| for (b) |img| img.deinit();
        v.fires.deinit(gpa);
        v.* = undefined;
    }

    /// Advance `frame` every `interval` seconds.
    fn tick(v: *Visual, time: f64, interval: f64) bool {
        if (time - v.last_frame_time < interval) return false;
        v.last_frame_time = time;
        v.frame +%= 1;
        return true;
    }

    fn setTimer(v: *Visual, fonts: *const font.Fonts, seconds: i64) void {
        if (seconds == v.timer_seconds) return;
        v.timer_seconds = seconds;
        if (v.timer) |t| t.deinit();
        v.timer = null;
        if (seconds < 0) return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ @divTrunc(seconds, 60), @mod(seconds, 60) }) catch return;
        v.timer = fonts.get(.green_building).render(text);
    }
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    sprites: *const Sprites,
    fonts: *const font.Fonts,
    fx: *effects.Effects,
    visuals: std.AutoHashMapUnmanaged(i32, Visual) = .empty,
    rng: std.Random.DefaultPrng,
    /// Set when a map is loaded.
    planet: ?k.Planet = null,
    our_team: k.Team = .none,
    /// How deep robots sink into water, per map tile.
    submerge: []u8 = &.{},
    map_width: u32 = 0,
    map_height: u32 = 0,
    /// Draw order scratch list.
    order: std.ArrayList(*Object) = .empty,
    time: f64 = 0,

    pub fn init(gpa: std.mem.Allocator, sprites: *const Sprites, fonts: *const font.Fonts, fx: *effects.Effects) Renderer {
        return .{ .gpa = gpa, .sprites = sprites, .fonts = fonts, .fx = fx, .rng = .init(7) };
    }

    pub fn deinit(r: *Renderer) void {
        r.reset();
        r.visuals.deinit(r.gpa);
        r.gpa.free(r.submerge);
        r.order.deinit(r.gpa);
    }

    /// A new map: robots sink 8 pixels into water, 6 near its shore.
    pub fn setMap(r: *Renderer, m: *const game.map.Map, info: *const game.map.Terrain) !void {
        r.reset();
        r.planet = m.planet();
        const palette = info.palette(m.planet());
        const w: usize = m.header.width;
        const h: usize = m.header.height;
        r.gpa.free(r.submerge);
        r.submerge = try r.gpa.alloc(u8, w * h);
        r.map_width = @intCast(w);
        r.map_height = @intCast(h);
        for (r.submerge, m.tiles) |*sm, t| sm.* = if (palette[t].is_water) 8 else 0;
        for (0..h) |j| for (0..w) |i| {
            if (r.submerge[j * w + i] != 8) continue;
            shore: for (i -| 1..@min(i + 3, w)) |ni| for (j -| 1..@min(j + 3, h)) |nj| {
                if (r.submerge[nj * w + ni] == 0) {
                    r.submerge[j * w + i] = 6;
                    break :shore;
                }
            };
        };
    }

    fn submergeAt(r: *const Renderer, x: i32, y: i32) i32 {
        if (x < 0 or y < 0) return 0;
        const tx: u32 = @intCast(@divTrunc(x, 16));
        const ty: u32 = @intCast(@divTrunc(y, 16));
        if (tx >= r.map_width or ty >= r.map_height) return 0;
        return r.submerge[ty * r.map_width + tx];
    }

    /// Forget all objects (new map).
    pub fn reset(r: *Renderer) void {
        var it = r.visuals.valueIterator();
        while (it.next()) |v| v.deinit(r.gpa);
        r.visuals.clearRetainingCapacity();
    }

    pub fn remove(r: *Renderer, ref_id: i32) void {
        if (r.visuals.fetchRemove(ref_id)) |kv| {
            var v = kv.value;
            v.deinit(r.gpa);
        }
    }

    fn visual(r: *Renderer, o: *const Object) *Visual {
        const gop = r.visuals.getOrPut(r.gpa, o.ref_id) catch @panic("out of memory");
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .frame = r.rng.random().int(u8) };
            units.init(o, &gop.value_ptr.unit, r.rng.random(), r.our_team, r.time);
            if (o.kind == .building) {
                gop.value_ptr.fires = .init(o, r.rng.random());
                if (o.kind.building.isBridge()) gop.value_ptr.bridge = r.bridgeImages(o);
            }
        }
        return gop.value_ptr;
    }

    pub fn repairAnim(r: *Renderer, o: *const Object, on: bool, remaining: f64, time: f64) void {
        const v = r.visual(o);
        v.repairing_until = if (on) time + remaining else null;
        if (on) v.repair_frame = 0;
    }

    // -----------------------------------------------------------------------
    // Update: animations, painting buildings onto the ground
    // -----------------------------------------------------------------------

    pub fn update(r: *Renderer, world: *const World, terrain: *terrain_mod.Terrain, time: f64) void {
        r.time = time;
        for (world.objects.items) |o| {
            const v = r.visual(o);
            switch (o.kind) {
                .flag => _ = v.tick(time, 0.2),
                .building => |*b| r.updateBuilding(o, b, v, terrain, time),
                .robot, .vehicle, .cannon => units.update(o, &v.unit, r.unitUpdate(world)),
                else => {},
            }
        }
    }

    fn unitUpdate(r: *Renderer, world: *const World) units.Update {
        return .{ .world = world, .time = r.time, .rng = r.rng.random(), .fx = r.fx };
    }

    // Reactions to what the server says.

    pub fn hit(r: *Renderer, o: *const Object) void {
        r.visual(o).unit.hit = true;
    }

    pub fn driverHit(r: *Renderer, o: *const Object) void {
        r.visual(o).unit.driver_hit = true;
    }

    pub fn fireMissile(r: *Renderer, world: *const World, o: *const Object, x: i32, y: i32) void {
        units.fireMissile(o, &r.visual(o).unit, x, y, r.unitUpdate(world));
    }

    /// `o` was destroyed: wrecks, explosions, flying debris.
    pub fn killed(r: *Renderer, o: *const Object, fire_death: bool, missile_death: bool, missiles: []const protocol.FireMissileInfo) void {
        const u = &r.visual(o).unit;
        r.fx.destroyed(o, .{ .direction = u.direction, .move_i = u.move_i }, fire_death, missile_death, missiles, r.sprites);
    }

    /// A destroyed object came back (a building was rebuilt).
    pub fn revived(r: *Renderer, o: *const Object) void {
        if (o.kind != .building) return;
        r.visual(o).fires.clear();
        if (o.kind.building.isBridge()) r.fx.bridgeDebris(o, true);
    }

    /// A driver was sniped out of `o`.
    pub fn sniped(r: *Renderer, o: *const Object) void {
        r.fx.robotFlip(o.owner, o.center_x, o.center_y - 4);
    }

    pub fn pickupGrenades(r: *Renderer, o: *const Object) void {
        units.pickupGrenades(&r.visual(o).unit);
    }

    pub fn craneAnim(r: *Renderer, o: *const Object, on: bool) void {
        r.visual(o).unit.crane_anim = on;
    }

    fn updateBuilding(r: *Renderer, o: *const Object, b: *const game.object.Building, v: *Visual, terrain: *terrain_mod.Terrain, time: f64) void {
        const s = r.sprites;
        const planet = @intFromEnum(terrain.planet);
        const owner = @intFromEnum(o.owner);
        const destroyed = o.isDestroyed();
        v.fires.update(r.gpa, o, r.rng.random(), time);

        const production_left: i64 = if (b.state != .select) @intFromFloat(@max(b.final_time - time, 0)) else -1;
        switch (b.type) {
            .fort_front, .fort_back => {
                _ = v.tick(time, 0.2);
                v.setTimer(r.fonts, production_left);
                v.fade += (time - v.last_frame_time) * v.fade_dir;
                if (v.fade > 254) {
                    v.fade = 254;
                    v.fade_dir = -v.fade_dir;
                } else if (v.fade < 1) {
                    v.fade = 1;
                    v.fade_dir = -v.fade_dir;
                }
            },
            .radar => _ = v.tick(time, 0.25),
            .robot_factory => {
                if (v.tick(time, 0.25) and r.rng.random().uintLessThan(u32, 3) == 0) {
                    for (&v.lights) |*l| l.* = r.rng.random().boolean();
                }
                v.setTimer(r.fonts, production_left);
            },
            .vehicle_factory => {
                _ = v.tick(time, 0.25);
                v.setTimer(r.fonts, production_left);
            },
            .repair => {
                if (v.tick(time, 0.35)) v.repair_frame +%= 1;
                if (v.repairing_until) |until| {
                    v.setTimer(r.fonts, @intFromFloat(@max(until - time, 0)));
                    if (time > until + 1) v.repairing_until = null;
                } else v.setTimer(r.fonts, -1);
            },
            .bridge_vert, .bridge_horz => {},
        }

        // Paint the building onto the ground when its look changed.
        const look: Look = .{
            .destroyed = destroyed,
            .owner = o.owner,
            .damage = if (!b.isBridge()) 0 else if (destroyed) 2 else if (o.health < o.max_health >> 1) 1 else 0,
        };
        if (v.stamped) |st| if (std.meta.eql(st, look)) return;
        const img: ?Image = switch (b.type) {
            .fort_front => if (destroyed) s.fort.front_destroyed[planet] else s.fort.front[planet],
            .fort_back => if (destroyed) s.fort.back_destroyed[planet] else s.fort.back[planet],
            .radar => if (destroyed) s.radar.destroyed[planet] else s.radar.base[planet][owner],
            .robot_factory => if (destroyed) s.robot_factory.destroyed[planet][owner] else s.robot_factory.base[planet][owner],
            .vehicle_factory => if (destroyed) s.vehicle_factory.destroyed[planet][owner] else s.vehicle_factory.base[planet][owner],
            .repair => if (destroyed) s.repair.destroyed[planet] else s.repair.base[planet][owner],
            .bridge_vert, .bridge_horz => if (v.bridge) |imgs| imgs[look.damage] else null,
        };
        if (img) |i| terrain.stamp(i, o.x, o.y);
        v.stamped = look;
    }

    /// Paint all buildings again (the ground was redrawn).
    pub fn restampAll(r: *Renderer) void {
        var it = r.visuals.valueIterator();
        while (it.next()) |v| v.stamped = null;
    }

    fn bridgeImages(r: *Renderer, o: *const Object) ?[3]Image {
        // The planet's bridge sheet: ends and middle pieces (intact,
        // damaged, destroyed) for both directions.
        const planet = if (r.planet) |p| @intFromEnum(p) else return null;
        const sheet = r.sprites.bridge[planet] orelse return null;
        var imgs: [3]Image = undefined;
        for (&imgs, 0..) |*img, i| {
            img.* = Image.create(o.width_pix, o.height_pix) orelse {
                for (imgs[0..i]) |done| done.deinit();
                return null;
            };
            img.fill(null, .{ .r = 0, .g = 0, .b = 0 });
        }
        const vertical = o.kind.building.type == .bridge_vert;
        const w = @divTrunc(o.width_pix, 16);
        const h = @divTrunc(o.height_pix, 16);
        for (imgs, 0..) |img, state| {
            if (vertical) {
                img.draw(sheet, .{ .x = 0, .y = 0, .w = 64, .h = 32 }, 0, 0);
                img.draw(sheet, .{ .x = 0, .y = 32, .w = 64, .h = 32 }, 0, (h - 2) * 16);
                var i: i32 = 2;
                while (i < h - 2) : (i += 1) {
                    const row: i32 = switch (state) {
                        0 => 4,
                        1 => 5 + @as(i32, r.rng.random().uintLessThan(u8, 2)),
                        else => 7,
                    };
                    img.draw(sheet, .{ .x = 0, .y = row * 16, .w = 64, .h = 16 }, 0, i * 16);
                }
            } else {
                img.draw(sheet, .{ .x = 0, .y = 128, .w = 32, .h = 64 }, 0, 0);
                img.draw(sheet, .{ .x = 32, .y = 128, .w = 32, .h = 64 }, (w - 2) * 16, 0);
                var i: i32 = 2;
                while (i < w - 2) : (i += 1) {
                    const col: i32 = switch (state) {
                        0 => 0,
                        1 => 1 + @as(i32, r.rng.random().uintLessThan(u8, 2)),
                        else => 3,
                    };
                    img.draw(sheet, .{ .x = col * 16, .y = 192, .w = 16, .h = 64 }, i * 16, 0);
                }
            }
        }
        return imgs;
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    /// Under everything else: shadows and overlays on the ground.
    pub fn drawPre(r: *Renderer, cv: Canvas, world: *const World, view: gfx.Rect) void {
        const s = r.sprites;
        const planet = if (r.planet) |p| @intFromEnum(p) else return;
        for (world.objects.items) |o| {
            if (!visible(o, view, 32)) continue;
            switch (o.kind) {
                .item => |item| if (item == .rock) r.drawRock(cv, world, o, true),
                .building => |b| if (o.isDestroyed() and b.isFort()) {
                    const v = r.visual(o);
                    const overlay = if (b.type == .fort_front) s.fort.front_destroyed_overlay[planet] else s.fort.back_destroyed_overlay[planet];
                    if (overlay) |img| cv.drawAlpha(img, o.x, o.y, @intFromFloat(v.fade));
                },
                else => {},
            }
        }
    }

    /// Items and units, farther ones (by their bottom edge) first.
    pub fn draw(r: *Renderer, cv: Canvas, world: *const World, view: gfx.Rect) void {
        const s = r.sprites;
        const planet = if (r.planet) |p| @intFromEnum(p) else return;
        r.order.clearRetainingCapacity();
        for (world.objects.items) |o| {
            if (o.kind == .building or !visible(o, view, 32)) continue;
            r.order.append(r.gpa, o) catch return;
        }
        std.mem.sort(*Object, r.order.items, {}, struct {
            fn lessThan(_: void, a: *Object, b: *Object) bool {
                return a.y + a.height_pix < b.y + b.height_pix;
            }
        }.lessThan);
        for (r.order.items) |o| {
            switch (o.kind) {
                .flag => if (s.flag[@intFromEnum(o.owner)][r.visual(o).frame % 4]) |img| cv.draw(img, o.x, o.y),
                .item => |item| switch (item) {
                    .grenades => if (s.grenades) |img| cv.draw(img, o.x, o.y),
                    .rockets => if (s.rockets) |img| cv.draw(img, o.x, o.y),
                    .hut => if (s.hut[planet]) |img| cv.draw(img, o.x, o.y),
                    .rock => r.drawRock(cv, world, o, false),
                    else => if (item.mapObjectIndex()) |i| {
                        // Drawn standing on its tile.
                        if (s.map_object[i]) |img| cv.draw(img, o.x, o.y + 16 - img.height());
                    },
                },
                .robot, .vehicle, .cannon => {
                    const sub = if (o.kind == .robot) r.submergeAt(o.x + 8, o.y + 8) else 0;
                    units.draw(cv, s, o, &r.visual(o).unit, world, sub);
                },
                .building => {},
            }
        }
    }

    /// Over units: the building parts they pass behind, lights, timers.
    pub fn drawAfter(r: *Renderer, cv: Canvas, world: *const World, view: gfx.Rect) void {
        for (world.objects.items) |o| {
            if (!visible(o, view, 32)) continue;
            switch (o.kind) {
                .building => |*b| {
                    r.drawBuildingTop(cv, o, b);
                    r.visual(o).fires.draw(cv, r.sprites);
                },
                else => {},
            }
        }
    }

    fn drawBuildingTop(r: *Renderer, cv: Canvas, o: *const Object, b: *const game.object.Building) void {
        const s = r.sprites;
        const planet = @intFromEnum(r.planet.?);
        const owner = @intFromEnum(o.owner);
        const v = r.visual(o);
        const f = v.frame;
        const x = o.x;
        const y = o.y;
        const destroyed = o.isDestroyed();
        const working = o.owner != .none and b.state != .select;

        switch (b.type) {
            .fort_front, .fort_back => {
                // The gate units go through.
                const front = b.type == .fort_front;
                const part: gfx.Rect = if (front) .{ .x = 56, .y = 104, .w = 48, .h = 41 } else .{ .x = 56, .y = 16, .w = 48, .h = 41 };
                const base = if (front)
                    (if (destroyed) s.fort.front_destroyed[planet] else s.fort.front[planet])
                else
                    (if (destroyed) s.fort.back_destroyed[planet] else s.fort.back[planet]);
                if (base) |img| cv.drawPart(img, part, x + part.x, y + part.y);
                if (destroyed) {
                    const overlay = if (front) s.fort.front_destroyed_overlay[planet] else s.fort.back_destroyed_overlay[planet];
                    if (overlay) |img| cv.drawPart(img, part, x + part.x, y + part.y);
                } else {
                    if (v.timer) |t| cv.draw(t, x + 74, y + 90);
                    if (s.fort.flag[owner][f % 4]) |img| cv.draw(img, x + 85, y + 29);
                }
            },
            .radar => {
                if (destroyed) {
                    if (s.radar.destroyed[planet]) |img| cv.drawPart(img, .{ .x = 12, .y = 0, .w = 32, .h = 32 }, x + 12, y);
                } else {
                    const dish_y = [8]i32{ -5, -6, -10, -13, -15, -13, -10, -6 };
                    if (s.radar.front_light[f % 2]) |img| cv.draw(img, x + 16, y + 22);
                    if (o.owner != .none) {
                        if (s.radar.side_light[f % 2]) |img| cv.draw(img, x + 41, y);
                        if (s.radar.box_spinner[f % 12]) |img| cv.draw(img, x + 18, y + 13);
                        if (s.radar.dish[f % 8]) |img| cv.draw(img, x + 15, y + dish_y[f % 8]);
                    }
                }
            },
            .robot_factory => {
                const rf = &s.robot_factory;
                if (destroyed) {
                    if (rf.destroyed[planet][owner]) |img| cv.drawPart(img, .{ .x = 19, .y = 8, .w = 32, .h = 59 }, x + 19, y + 8);
                } else if (working) {
                    if (rf.base[planet][owner]) |img| cv.drawPart(img, .{ .x = 31, .y = 47, .w = 24, .h = 20 }, x + 31, y + 47);
                    r.drawExhaust(cv, f, x + 28, y - 24);
                    if (rf.green_box[f % 6]) |img| cv.draw(img, x + 38, y + 39);
                    const light_x = [3]i32{ 13, 16, 19 };
                    for (v.lights, light_x) |on, lx| if (on) {
                        if (rf.light[1]) |img| cv.draw(img, x + lx, y + 68);
                    };
                    if (rf.double_light[1]) |img| cv.draw(img, x + 16, y + 32);
                    if (rf.robot[f % 2]) |img| cv.draw(img, x + 16, y + 48);
                    if (rf.spin[f % 8]) |img| cv.draw(img, x + 9, y - 2);
                    if (v.timer) |t| cv.draw(t, x + 35, y + 58);
                } else if (rf.robot[f % 2]) |img| cv.draw(img, x + 16, y + 48);
                if (s.level[b.level]) |img| cv.draw(img, x + 8, y + 56);
            },
            .vehicle_factory => {
                const vf = &s.vehicle_factory;
                if (destroyed) {
                    if (vf.destroyed[planet][owner]) |img| cv.drawPart(img, .{ .x = 15, .y = 8, .w = 32, .h = 58 }, x + 15, y + 8);
                } else if (working) {
                    if (vf.base[planet][owner]) |img| cv.drawPart(img, .{ .x = 8, .y = 24, .w = 48, .h = 41 }, x + 8, y + 24);
                    r.drawExhaust(cv, f, x + 28, y - 22);
                    if (vf.tank[f % 2]) |img| cv.draw(img, x + 16, y + 48);
                    if (vf.vent[f % 4]) |img| cv.draw(img, x + 16, y + 32);
                    if (vf.bulb[f % 2]) |img| cv.draw(img, x + 24, y + 39);
                    for ([2]i32{ 13, 42 }) |lx| if (vf.lights[1]) |img| cv.draw(img, x + lx, y + 47);
                    if (vf.spin[f % 8]) |img| cv.draw(img, x + 9, y - 2);
                    if (v.timer) |t| cv.draw(t, x + 31, y + 57);
                } else if (vf.tank[f % 2]) |img| cv.draw(img, x + 16, y + 48);
                if (s.level[b.level]) |img| cv.draw(img, x + 8, y + 56);
            },
            .repair => {
                const rp = &s.repair;
                const part: gfx.Rect = .{ .x = 10, .y = 6, .w = 44, .h = 44 };
                if (destroyed) {
                    if (rp.destroyed[planet]) |img| cv.drawPart(img, part, x + part.x, y + part.y);
                } else if (o.owner != .none) {
                    const rf = if (v.repairing_until != null) v.repair_frame else 0;
                    if (rp.base[planet][owner]) |img| cv.drawPart(img, part, x + part.x, y + part.y);
                    if (rp.text_box[f % 3]) |img| cv.draw(img, x + 16, y + 32);
                    if (rp.bulb[rf % 2]) |img| cv.draw(img, x + 32, y);
                    if (v.repairing_until != null) if (rp.smoke_stack[rf % 5]) |img| cv.draw(img, x + 61, y);
                    if (rp.front_light[1]) |img| cv.draw(img, x + 6, y + 16);
                    if (rp.side_light[1]) |img| cv.draw(img, x + 18, y + 6);
                    if (v.timer) |t| cv.draw(t, x + 25, y + 41);
                } else if (rp.smoke_stack[f % 5]) |img| cv.draw(img, x + 61, y);
            },
            .bridge_vert, .bridge_horz => {},
        }
    }

    fn drawExhaust(r: *Renderer, cv: Canvas, f: u32, x: i32, y: i32) void {
        const i = f % 13;
        if (r.sprites.exhaust[i]) |img| cv.draw(img, x, y - @as(i32, @intCast(i)) * 2);
    }

    /// Rocks join up with their neighbors: which pieces of the sheet to
    /// draw depends on the rocks around (ORock::SetupRockRender).
    fn drawRock(r: *Renderer, cv: Canvas, world: *const World, o: *const Object, shadow_pass: bool) void {
        const sheet = r.sprites.rocks[@intFromEnum(r.planet.?)] orelse return;
        const m = world.map orelse return;
        const w: i32 = m.header.width;
        const h: i32 = m.header.height;
        const tx = @divTrunc(o.x, 16);
        const ty = @divTrunc(o.y, 16);
        const Rocks = struct {
            world: *const World,
            fn at(self: @This(), x: i32, y: i32) bool {
                for (self.world.objects.items) |other| {
                    if (other.kind == .item and other.kind.item == .rock and @divTrunc(other.x, 16) == x and @divTrunc(other.y, 16) == y) return true;
                }
                return false;
            }
        };
        const rocks: Rocks = .{ .world = world };
        const parts = rockParts(tx, ty, w, h, rocks);
        const layer = if (shadow_pass) parts[1] else parts[0];
        const dx: i32 = if (shadow_pass) 16 else 0;
        for (layer, 0..) |piece, j| if (piece) |p| {
            cv.drawPart(sheet, .{ .x = p[0] * 16, .y = p[1] * 16, .w = 16, .h = 16 }, o.x + dx, o.y + @as(i32, @intCast(j)) * 16);
        };
    }

    fn visible(o: *const Object, view: gfx.Rect, margin: i32) bool {
        const r: gfx.Rect = .{ .x = o.x - margin, .y = o.y - margin, .w = o.width_pix + 2 * margin, .h = o.height_pix + 2 * margin };
        return r.intersect(view) != null;
    }
};

const Piece = ?[2]i32;

/// Sheet pieces of a rock at tile (tx, ty): [0] the rock (3 tiles down),
/// [1] its shadow (to the right). `rocks.at(x, y)` tells if a rock is there.
fn rockParts(tx: i32, ty: i32, map_w: i32, map_h: i32, rocks: anytype) [2][3]Piece {
    var out: [2][3]Piece = @splat(@splat(null));
    const l = tx == 0 or rocks.at(tx - 1, ty);
    const up = ty == 0 or rocks.at(tx, ty - 1);
    const r = tx == map_w - 1 or rocks.at(tx + 1, ty);
    const dn = ty == map_h - 1 or rocks.at(tx, ty + 1);
    const dl = tx > 0 and ty < map_h - 1 and rocks.at(tx - 1, ty + 1);
    const ddn = ty >= map_h - 2 or rocks.at(tx, ty + 2);
    const uup = ty < 2 or rocks.at(tx, ty - 2);
    const uur = ty >= 2 and tx < map_w - 1 and rocks.at(tx + 1, ty - 2);
    const ur = ty >= 1 and tx < map_w - 1 and rocks.at(tx + 1, ty - 1);
    const dr = ty < map_h - 1 and tx < map_w - 1 and rocks.at(tx + 1, ty + 1);
    const ddr = ty < map_h - 2 and tx < map_w - 1 and rocks.at(tx + 1, ty + 2);

    // Top: by the four neighbors (r, l, up, dn).
    const Key = struct { bool, bool, bool, bool };
    const top_table = [_]struct { Key, [2]i32 }{
        .{ .{ true, true, true, true }, .{ 1, 1 } },
        .{ .{ true, false, false, true }, .{ 0, 0 } },
        .{ .{ false, true, false, true }, .{ 2, 0 } },
        .{ .{ false, true, true, false }, .{ 2, 2 } },
        .{ .{ true, false, true, false }, .{ 0, 2 } },
        .{ .{ true, true, false, true }, .{ 1, 0 } },
        .{ .{ true, true, true, false }, .{ 1, 2 } },
        .{ .{ false, true, true, true }, .{ 2, 1 } },
        .{ .{ true, false, true, true }, .{ 0, 1 } },
        .{ .{ false, false, false, true }, .{ 3, 0 } },
        .{ .{ false, false, true, true }, .{ 3, 1 } },
        .{ .{ false, false, true, false }, .{ 3, 2 } },
        .{ .{ true, false, false, false }, .{ 0, 5 } },
        .{ .{ true, true, false, false }, .{ 1, 5 } },
        .{ .{ false, true, false, false }, .{ 2, 5 } },
        .{ .{ false, false, false, false }, .{ 3, 2 } },
    };
    for (top_table) |e| {
        if (e[0][0] == r and e[0][1] == l and e[0][2] == up and e[0][3] == dn) out[0][0] = e[1];
    }

    // Default when near the map's bottom edge.
    out[0][1] = .{ 3, 3 };
    out[0][2] = .{ 3, 4 };
    if (ty + 1 < map_h) {
        out[0][1] = if (dn)
            null
        else if (dl)
            (if (r) .{ 5, 0 } else .{ 4, 0 })
        else if (r and l) .{ 1, 3 } else if (r) .{ 0, 3 } else if (l) .{ 2, 3 } else .{ 3, 3 };
    }
    if (ty + 2 < map_h) {
        out[0][2] = if (ddn or dn)
            null
        else if (dl)
            (if (r) .{ 5, 1 } else .{ 4, 1 })
        else if (r and l) .{ 1, 4 } else if (r) .{ 0, 4 } else if (l) .{ 2, 4 } else .{ 3, 4 };
    }
    if (tx < map_w - 1) {
        if (!(uur or ur or r)) {
            if (up and !uup) out[1][0] = .{ 4, 2 } else if (up or uup) out[1][0] = .{ 4, 3 };
        }
        if (!dn and !(ur or r or dr)) out[1][1] = if (!up) .{ 4, 2 } else .{ 4, 3 };
        if (!dn and !ddn and !(r or dr or ddr)) out[1][2] = .{ 4, 4 };
    }
    return out;
}

test "rock pieces" {
    const Set = struct {
        tiles: []const [2]i32,
        fn at(self: @This(), x: i32, y: i32) bool {
            for (self.tiles) |t| if (t[0] == x and t[1] == y) return true;
            return false;
        }
    };
    // A lone rock: vertical cap, single column body, shadows.
    const lone = rockParts(5, 5, 20, 20, Set{ .tiles = &.{.{ 5, 5 }} });
    try std.testing.expectEqual(@as(Piece, .{ 3, 2 }), lone[0][0]);
    try std.testing.expectEqual(@as(Piece, .{ 3, 3 }), lone[0][1]);
    try std.testing.expectEqual(@as(Piece, .{ 4, 2 }), lone[1][1]);
    // With a rock below, the body is hidden by it.
    const top = rockParts(5, 5, 20, 20, Set{ .tiles = &.{ .{ 5, 5 }, .{ 5, 6 } } });
    try std.testing.expectEqual(@as(Piece, .{ 3, 0 }), top[0][0]);
    try std.testing.expectEqual(@as(Piece, null), top[0][1]);
}
