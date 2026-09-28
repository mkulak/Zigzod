//! The client program: window, main loop, camera and input (from ZPlayer).

const std = @import("std");
const c = @import("c");
const game = @import("../game.zig");
const net = @import("../net.zig");
const gfx = @import("gfx.zig");
const terrain_mod = @import("terrain.zig");
const font = @import("font.zig");
const Sprites = @import("sprites.zig").Sprites;
const Renderer = @import("objects.zig").Renderer;
const Effects = @import("effects.zig").Effects;
const hud_mod = @import("hud.zig");
const cursor = @import("cursor.zig");
const Control = @import("control.zig").Control;
const drawSelectionBox = @import("control.zig").drawSelectionBox;
const windows = @import("windows.zig");
const messages = @import("messages.zig");
const portrait = @import("portrait.zig");
const sound = @import("sound.zig");
const menus = @import("menus.zig");
const Session = @import("session.zig").Session;

const k = game.constants;
const Object = game.object.Object;

const hud_width = hud_mod.width;
const hud_height = hud_mod.height;

pub const Options = struct {
    host: [:0]const u8 = "localhost",
    port: u16 = net.conn.default_port,
    name: []const u8 = "Player",
    team: k.Team = .red,
    width: i32 = 800,
    height: i32 = 600,
    fullscreen: bool = false,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    assets: [:0]const u8,
    options: Options,
    screen: gfx.Image,
    width: i32,
    height: i32,

    terrain_info: *game.map.Terrain,
    palettes: gfx.TeamPalettes,
    sheets: terrain_mod.Sheets,
    terrain: ?terrain_mod.Terrain = null,
    fonts: font.Fonts,
    sprites: *Sprites,
    objects: Renderer,
    fx: Effects,
    hud: hud_mod.Hud,
    cursors: cursor.Cursors,
    control: Control,
    window_images: windows.Images,
    list_images: windows.ListImages,
    msg_images: messages.Images,
    news: messages.News,
    notices: messages.Notices = .{},
    sounds: sound.Sounds = .{},
    /// 0 (off) to 4 (full).
    volume: u8 = 4,
    menu_art: menus.Art,
    menus: menus.Menus = .{},
    left_on_menu: bool = false,
    /// Spoken warnings: fort under attack, losing.
    next_fort_warning: f64 = 0,
    next_losing_warning: f64 = 0,
    factory_list: windows.FactoryList = .{},
    left_on_list: bool = false,
    /// The production window of one of our buildings.
    window: ?windows.Production = null,
    /// Placing a finished gun from this building.
    placing: ?struct { building: i32, gun: k.Cannon } = null,
    session: Session,
    prng: std.Random.DefaultPrng,
    clock_origin: std.Io.Timestamp,

    /// Top-left map pixel shown.
    view_x: i32 = 0,
    view_y: i32 = 0,
    keys: struct {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        /// Held while ordering: only the nearest unit goes.
        z: bool = false,
    } = .{},
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    /// Left button: where a selection box started (map coordinates), or
    /// pressed on the HUD.
    drag: ?[2]i32 = null,
    left_on_hud: bool = false,
    left_on_window: bool = false,
    /// Middle button drags the map.
    middle: ?[2]i32 = null,
    /// The camera glides to this view position.
    glide_to: ?[2]i32 = null,
    /// Text typed into the chat line (null when not typing).
    chat: ?std.ArrayList(u8) = null,
    last_frame: f64 = 0,
    quit: bool = false,
    /// The camera starts on our fort once it arrives.
    focused: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_path: []const u8, options: Options) !*App {
        const assets = try std.fmt.allocPrintSentinel(gpa, "{s}/assets", .{data_path}, 0);
        errdefer gpa.free(assets);

        const terrain_info = try gpa.create(game.map.Terrain);
        errdefer gpa.destroy(terrain_info);
        {
            var dir = try std.Io.Dir.cwd().openDir(io, assets, .{});
            defer dir.close(io);
            terrain_info.* = try game.map.Terrain.load(io, dir);
        }

        const conn = net.conn.Conn.connect(options.host, options.port) catch |err| {
            std.log.err("could not connect to {s}:{d}: {t}", .{ options.host, options.port, err });
            return err;
        };

        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) return error.SdlInitFailed;
        errdefer c.SDL_Quit();
        c.SDL_WM_SetCaption("Zod Engine", "Zod Engine");
        _ = c.SDL_EnableUNICODE(1);
        _ = c.SDL_EnableKeyRepeat(c.SDL_DEFAULT_REPEAT_DELAY, c.SDL_DEFAULT_REPEAT_INTERVAL);
        var flags: u32 = c.SDL_SWSURFACE | c.SDL_RESIZABLE;
        if (options.fullscreen) flags |= c.SDL_FULLSCREEN;
        const surface: *c.SDL_Surface = c.SDL_SetVideoMode(options.width, options.height, 32, flags) orelse return error.SdlVideoFailed;

        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        const palettes = gfx.TeamPalettes.load(assets);
        app.* = .{
            .gpa = gpa,
            .io = io,
            .assets = assets,
            .options = options,
            .screen = .{ .surface = surface },
            .width = options.width,
            .height = options.height,
            .terrain_info = terrain_info,
            .palettes = palettes,
            .sheets = undefined,
            .fonts = undefined,
            .sprites = undefined,
            .objects = undefined,
            .fx = undefined,
            .hud = undefined,
            .cursors = undefined,
            .control = .init(gpa),
            .window_images = undefined,
            .list_images = undefined,
            .msg_images = undefined,
            .menu_art = undefined,
            .news = .{ .gpa = gpa },
            .session = Session.init(gpa, conn, terrain_info, .{ .name = options.name, .team = options.team }),
            .prng = .init(@truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)))),
            .clock_origin = std.Io.Clock.awake.now(io),
        };
        app.sheets = terrain_mod.Sheets.load(assets, &app.palettes);
        app.fonts = font.Fonts.load(assets);
        app.hud = .init(assets, &app.palettes, &app.fonts);
        app.cursors = .load(assets, &app.palettes);
        app.window_images = .load(assets);
        app.list_images = .load(assets);
        app.msg_images = .load(assets);
        app.menu_art = .load(assets, &app.palettes);
        app.sounds.init(assets);
        _ = c.SDL_ShowCursor(c.SDL_DISABLE);
        app.sprites = try Sprites.load(gpa, assets, &app.palettes);
        app.fx = Effects.init(gpa, app.sprites, &app.palettes, app.prng.random());
        app.objects = Renderer.init(gpa, app.sprites, &app.fonts, &app.fx);
        try app.session.start();
        return app;
    }

    pub fn deinit(app: *App) void {
        const gpa = app.gpa;
        if (app.terrain) |*t| t.deinit();
        app.objects.deinit();
        app.fx.deinit();
        app.hud.deinit();
        app.cursors.deinit();
        app.closeWindow();
        app.window_images.deinit();
        app.list_images.deinit();
        app.msg_images.deinit();
        app.menu_art.deinit();
        app.sounds.deinit();
        app.news.deinit();
        app.control.deinit();
        if (app.chat) |*t| t.deinit(gpa);
        app.sprites.deinit();
        app.fonts.deinit();
        app.sheets.deinit();
        app.session.deinit();
        gpa.destroy(app.terrain_info);
        gpa.free(app.assets);
        c.SDL_Quit();
        gpa.destroy(app);
    }

    fn realTime(app: *const App) f64 {
        const d = app.clock_origin.durationTo(std.Io.Clock.awake.now(app.io));
        return @as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_s;
    }

    pub fn run(app: *App) !void {
        while (!app.quit) {
            const now = app.realTime();
            try app.session.update(now);
            try app.handleEvents();
            app.handleSessionEvents() catch |err| return err;
            app.updateCamera(now - app.last_frame);
            app.last_frame = now;
            app.render(now);
            if (!app.session.connected()) {
                std.log.err("disconnected from the server", .{});
                return;
            }
            app.io.sleep(.fromMilliseconds(15), .awake) catch return;
        }
    }

    fn handleSessionEvents(app: *App) !void {
        defer app.session.clearEvents();
        for (app.session.events.items) |e| switch (e) {
            .map_loaded => {
                if (app.terrain) |*t| t.deinit();
                app.terrain = null;
                const m = &app.session.world.map.?;
                app.terrain = terrain_mod.Terrain.init(app.gpa, &app.sheets, app.terrain_info, m, app.prng.random()) catch |err| blk: {
                    std.log.err("could not draw the map: {t}", .{err});
                    break :blk null;
                };
                app.focused = false;
                app.fx.reset();
                app.hud.reset();
                app.hud.setMap(m);
                app.sounds.music.start(m.planet());
                app.closeWindow();
                app.placing = null;
                app.control.reset(app.session.team);
                app.objects.our_team = app.session.team;
                app.objects.setMap(m, app.terrain_info) catch {};
            },
            .deleted_object => |id| {
                app.objects.remove(id);
                app.control.forget(id);
            },
            .team_changed => |id| if (app.session.find(id)) |o| {
                if (o.owner != app.control.team) app.control.forget(id);
            },
            .comp_msg => |m| {
                const snd = @as(net.protocol.CompSound, @enumFromInt(m.sound));
                const idx = @intFromEnum(snd) - @intFromEnum(net.protocol.CompSound.vehicle);
                // (Repair messages are voiced with the repair animation.)
                const voiced = snd != .starting_repair and snd != .vehicle_repaired;
                if (voiced and idx >= 0 and idx < @typeInfo(sound.Computer).@"enum".fields.len) app.sounds.announce(@enumFromInt(idx), app.realTime(), app.prng.random());
                app.compMsg(m, snd);
            },
            .portrait_anim => |pa| if (app.session.find(pa.ref_id)) |o| {
                if (o.owner == app.control.team) {
                    app.control.notice(.{ .id = pa.ref_id, .select = true, .time = app.realTime() });
                    if (pa.anim_id >= 0 and pa.anim_id < @typeInfo(portrait.Anim).@"enum".fields.len) app.hud.speak(o, @enumFromInt(pa.anim_id), app.realTime());
                }
            },
            .health_changed => |hc| if (app.session.find(hc.ref_id)) |o| {
                if (o.health < hc.old) app.objects.hit(o);
                if (hc.old <= 0 and !o.isDestroyed()) app.objects.revived(o);
            },
            .destroyed => |d| app.objects.killed(d.object, d.fire_death, d.missile_death, d.missiles),
            .snipe => |id| if (app.session.find(id)) |o| app.objects.sniped(o),
            .attacked => |a| if (app.session.find(a.target)) |t| {
                if (t.owner == app.session.team and t.owner != .none and app.hud.alert == null) {
                    app.hud.attacked(t, app.session.world.now(), app.realTime(), app.prng.random());
                    if (app.hud.alert != null) app.control.notice(.{ .id = a.target, .select = true, .time = app.realTime() });
                }
            },
            .driver_hit => |id| if (app.session.find(id)) |o| app.objects.driverHit(o),
            .fired_missile => |fm| if (app.session.find(fm.ref_id)) |o| app.objects.fireMissile(&app.session.world, o, fm.x, fm.y),
            .pickup_grenades => |id| if (app.session.find(id)) |o| {
                app.objects.pickupGrenades(o);
                if (o.owner == app.control.team) {
                    app.control.notice(.{ .id = id, .select = true, .time = app.realTime() });
                    app.hud.speak(o, .grenades_collected, app.realTime());
                }
            },
            .crane_anim => |ca| if (app.session.find(ca.ref_id)) |o| app.objects.craneAnim(o, ca.on),
            .repair_anim => |ra| if (app.session.find(ra.ref_id)) |o| {
                if (o.owner == app.control.team and o.owner != .none) app.sounds.announce(if (ra.on) .starting_repair else .vehicle_repaired, app.realTime(), app.prng.random());
                app.objects.repairAnim(o, ra.on, ra.remaining_time, app.session.world.now());
            },
            .new_object => |id| if (!app.focused) {
                const o = app.session.find(id) orelse continue;
                if (o.isFort() and o.owner == app.session.team) {
                    app.centerOn(o.center_x, o.center_y);
                    app.focused = true;
                }
            },
            .reset_game => {
                if (app.terrain) |*t| t.deinit();
                app.terrain = null;
                app.objects.reset();
                app.fx.reset();
                app.hud.reset();
                app.closeWindow();
                app.placing = null;
                app.control.reset(app.session.team);
            },
            .team_ended => |te| if (te.team == @intFromEnum(app.session.team) and app.session.team != .none) {
                app.hud.startParade(&app.session.world, app.session.team, te.won);
            },
            .news => |n| {
                std.log.info("news: {s}", .{n.text});
                app.news.add(n.text, .{ .r = n.color[0], .g = n.color[1], .b = n.color[2] }, app.realTime());
            },
            else => {},
        };
    }

    // -----------------------------------------------------------------------
    // Camera
    // -----------------------------------------------------------------------

    fn mapArea(app: *const App) gfx.Rect {
        return .{ .x = 0, .y = 0, .w = @max(app.width - hud_width, 0), .h = @max(app.height - hud_height, 0) };
    }

    fn view(app: *const App) gfx.Rect {
        const area = app.mapArea();
        return .{ .x = app.view_x, .y = app.view_y, .w = area.w, .h = area.h };
    }

    fn clampView(app: *App) void {
        const m = app.session.world.map orelse return;
        const area = app.mapArea();
        app.view_x = std.math.clamp(app.view_x, 0, @max(m.widthPixels() - area.w, 0));
        app.view_y = std.math.clamp(app.view_y, 0, @max(m.heightPixels() - area.h, 0));
    }

    fn centerOn(app: *App, x: i32, y: i32) void {
        const area = app.mapArea();
        app.view_x = x - (area.w >> 1);
        app.view_y = y - (area.h >> 1);
        app.clampView();
    }

    /// Glide the camera to center on (x, y) (FocusCameraTo).
    fn lookAt(app: *App, x: i32, y: i32) void {
        const area = app.mapArea();
        app.glide_to = .{ x - (area.w >> 1), y - (area.h >> 1) };
    }

    fn updateCamera(app: *App, dt_in: f64) void {
        const dt = @min(dt_in, 0.1);
        if (app.glide_to) |to| {
            // A tenth of the way each 60th of a second.
            const f = 1 - std.math.pow(f64, 0.9, dt * 60);
            const old_x = app.view_x;
            const old_y = app.view_y;
            app.view_x += step(to[0] - app.view_x, f);
            app.view_y += step(to[1] - app.view_y, f);
            app.clampView();
            if (app.view_x == old_x and app.view_y == old_y) app.glide_to = null;
            return;
        }
        const amount: i32 = @intFromFloat(dt * scroll_speed);
        const edge = 3;
        const k_ = app.keys;
        if ((k_.left and !k_.right) or app.mouse_x < edge) app.view_x -= amount;
        if ((k_.right and !k_.left) or app.mouse_x >= app.width - edge) app.view_x += amount;
        if ((k_.up and !k_.down) or app.mouse_y < edge) app.view_y -= amount;
        if ((k_.down and !k_.up) or app.mouse_y >= app.height - edge) app.view_y += amount;
        app.clampView();
    }

    const scroll_speed = 400.0;

    fn step(d: i32, f: f64) i32 {
        if (d == 0) return 0;
        const s_: i32 = @intFromFloat(@as(f64, @floatFromInt(d)) * f);
        return if (s_ != 0) s_ else std.math.sign(d);
    }

    // -----------------------------------------------------------------------
    // Input
    // -----------------------------------------------------------------------

    fn overMap(app: *const App, x: i32, y: i32) bool {
        return !hud_mod.Hud.contains(app.width, app.height, x, y);
    }

    fn mouseMap(app: *const App) [2]i32 {
        return .{ app.mouse_x + app.view_x, app.mouse_y + app.view_y };
    }

    fn handleEvents(app: *App) !void {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => app.quit = true,
                c.SDL_VIDEORESIZE => {
                    const surface: *c.SDL_Surface = c.SDL_SetVideoMode(ev.resize.w, ev.resize.h, 32, c.SDL_SWSURFACE | c.SDL_RESIZABLE) orelse continue;
                    app.screen = .{ .surface = surface };
                    app.width = ev.resize.w;
                    app.height = ev.resize.h;
                    app.clampView();
                },
                c.SDL_MOUSEMOTION => app.mouseMoved(ev.motion.x, ev.motion.y),
                c.SDL_MOUSEBUTTONDOWN => try app.mouseDown(ev.button.button),
                c.SDL_MOUSEBUTTONUP => try app.mouseUp(ev.button.button),
                c.SDL_KEYDOWN => try app.keyDown(ev.key.keysym.sym, ev.key.keysym.unicode),
                c.SDL_KEYUP => try app.keyUp(ev.key.keysym.sym),
                else => {},
            }
        }
    }

    fn mouseMoved(app: *App, x: i32, y: i32) void {
        if (app.middle) |m| {
            app.view_x -= x - m[0];
            app.view_y -= y - m[1];
            app.clampView();
            app.middle = .{ x, y };
        }
        app.mouse_x = x;
        app.mouse_y = y;
        app.control.hover = null;
        if (app.menus.motion(x, y) or app.menus.contains(app.menuContext(), x, y)) return;
        const world = &app.session.world;
        if (app.left_on_hud) {
            // Dragging over the minimap moves the view.
            if (app.hud.minimapSpot(app.width, app.height, x, y)) |p| app.centerOn(p[0], p[1]);
        }
        if (app.overMap(x, y)) {
            const p = app.mouseMap();
            app.control.updateHover(world, p[0], p[1]);
        }
    }

    fn mouseDown(app: *App, button: u8) !void {
        const world = &app.session.world;
        const rng = app.prng.random();
        switch (button) {
            c.SDL_BUTTON_LEFT => {
                switch (app.menus.press(&app.menu_art, app.menuContext(), app.mouse_x, app.mouse_y, app.realTime())) {
                    .missed => {},
                    .absorbed => {
                        app.left_on_menu = true;
                        return;
                    },
                    .command => |cmd| {
                        app.left_on_menu = true;
                        return app.menuCommand(cmd);
                    },
                }
                if (app.hud.press(app.width, app.height, app.mouse_x, app.mouse_y)) |click| {
                    app.left_on_hud = true;
                    switch (click) {
                        .map => |p| app.centerOn(p[0], p[1]),
                        .jump => |id| if (world.find(id)) |o| {
                            app.lookAt(o.center_x, o.center_y);
                            if (!app.control.isSelected(id)) app.control.select(world, id, rng);
                        },
                        else => {},
                    }
                    return;
                }
                if (!app.overMap(app.mouse_x, app.mouse_y)) return;
                // Placing a gun happens on release.
                if (app.placing != null) return;
                var jump: ?i32 = null;
                if (app.factory_list.press(world, app.control.team, &app.list_images, app.mapArea(), app.mouse_x, app.mouse_y, &jump)) {
                    app.left_on_list = true;
                    if (jump) |id| if (world.find(id)) |o| {
                        app.lookAt(o.center_x, o.center_y);
                        _ = app.openWindow(o);
                    };
                    return;
                }
                const p = app.mouseMap();
                if (app.notices.click(world, app.control.team, world.clock.paused, &app.msg_images, app.mapArea(), app.mouse_x, app.mouse_y, app.realTime())) |cl| {
                    switch (cl) {
                        .resume_game => try app.session.sendPacket(.set_game_paused, net.protocol.GamePaused{ .game_paused = false }),
                        .select, .open, .look => |id| if (world.find(id)) |o| {
                            app.lookAt(o.center_x, o.center_y);
                            if (cl == .select) app.control.select(world, id, rng);
                            if (cl == .open) _ = app.openWindow(o);
                        },
                    }
                    return;
                }
                if (app.window) |*w| {
                    if (w.contains(p[0], p[1])) {
                        w.press(world, &app.window_images, p[0], p[1]);
                        app.left_on_window = true;
                        return;
                    }
                    app.closeWindow();
                }
                // Clicking one of our production buildings (with no unit of
                // ours there to select) opens its window.
                if (app.control.hover) |h| if (!app.unitOfOursAt(p)) {
                    if (world.find(h.id)) |o| if (app.openWindow(o)) return;
                };
                app.control.clear(world, rng);
                app.drag = p;
            },
            c.SDL_BUTTON_MIDDLE => app.middle = .{ app.mouse_x, app.mouse_y },
            c.SDL_BUTTON_WHEELUP, c.SDL_BUTTON_WHEELDOWN => {
                const up = button == c.SDL_BUTTON_WHEELUP;
                if (app.menus.wheel(app.menuContext(), up, app.mouse_x, app.mouse_y)) return;
                if (app.window) |*w| w.wheel(world, up) else if (app.factory_list.shown) app.factory_list.scroll(!up);
            },
            else => {},
        }
    }

    fn mouseUp(app: *App, button: u8) !void {
        const world = &app.session.world;
        const rng = app.prng.random();
        switch (button) {
            c.SDL_BUTTON_LEFT => {
                if (app.left_on_menu) {
                    app.left_on_menu = false;
                    switch (app.menus.release(app.menuContext(), app.mouse_x, app.mouse_y)) {
                        .command => |cmd| try app.menuCommand(cmd),
                        else => {},
                    }
                    return;
                }
                if (app.left_on_hud) {
                    app.left_on_hud = false;
                    switch (app.hud.release(app.width, app.height, app.mouse_x, app.mouse_y)) {
                        .button => |b| app.hudButton(b),
                        else => {},
                    }
                    return;
                }
                if (app.placing) |pl| {
                    app.placing = null;
                    const p = app.mouseMap();
                    try app.session.sendPacket(.place_cannon, net.protocol.PlaceCannon{
                        .ref_id = pl.building,
                        .tx = @divFloor(p[0], k.tile_size),
                        .ty = @divFloor(p[1], k.tile_size),
                        .oid = @intFromEnum(pl.gun),
                    });
                    return;
                }
                if (app.left_on_list) {
                    app.left_on_list = false;
                    app.factory_list.release();
                    return;
                }
                if (app.left_on_window) {
                    app.left_on_window = false;
                    if (app.window) |*w| {
                        const p = app.mouseMap();
                        try app.windowAction(w.building, w.release(world, &app.window_images, p[0], p[1]));
                    }
                    return;
                }
                const start = app.drag orelse return;
                app.drag = null;
                const p = app.mouseMap();
                app.control.selectBox(world, start[0], start[1], p[0], p[1], rng);
            },
            c.SDL_BUTTON_RIGHT => try app.order(),
            c.SDL_BUTTON_MIDDLE => app.middle = null,
            else => {},
        }
    }

    /// Right click: order the selected units there (sent now unless shift
    /// is held, to queue several).
    fn order(app: *App) !void {
        const world = &app.session.world;
        const minimap = app.hud.minimapSpot(app.width, app.height, app.mouse_x, app.mouse_y);
        if (minimap == null and !app.overMap(app.mouse_x, app.mouse_y)) return;
        const at = minimap orelse app.mouseMap();
        app.control.addOrder(world, at[0], at[1], .{ .from_minimap = minimap != null, .attack_to = app.keys.ctrl, .no_attack_to = app.keys.alt });
        if (app.keys.shift) return;
        // Clicking a lone APC or cannon lets its drivers out.
        if (app.control.selected.items.len == 1 and minimap == null) {
            const id = app.control.selected.items[0];
            if (world.find(id)) |o| if (o.canEjectDrivers() and o.underPoint(at[0], at[1])) {
                try app.session.sendPacket(.eject_vehicle, net.protocol.EjectVehicle{ .ref_id = id });
                app.control.forgetOrders();
            };
        }
        try app.sendOrders();
    }

    /// A selectable unit of ours under map point `p` (clicking there selects
    /// rather than opening a window).
    fn unitOfOursAt(app: *App, p: [2]i32) bool {
        for (app.session.world.objects.items) |o| {
            const u = app.session.world.findOpt(o.leader) orelse o;
            if (u.owner == app.control.team and u.selectable and o.withinSelection(p[0], p[0] + 1, p[1], p[1] + 1)) return true;
        }
        return false;
    }

    fn openWindow(app: *App, o: *const Object) bool {
        if (o.owner != app.control.team or o.owner == .none) return false;
        const m = &(app.session.world.map orelse return false);
        app.closeWindow();
        app.window = windows.Production.open(app.gpa, o, m) orelse return false;
        app.control.rally_for = o.ref_id;
        return true;
    }

    fn closeWindow(app: *App) void {
        if (app.window) |*w| w.deinit();
        app.window = null;
        app.control.rally_for = null;
    }

    fn windowAction(app: *App, building: i32, action: windows.Action) !void {
        const P = net.protocol;
        switch (action) {
            .none => {},
            .close => app.closeWindow(),
            .start => |u| try app.session.sendPacket(.start_building, P.StartBuilding{ .ref_id = building, .ot = @intFromEnum(u.kind), .oid = u.id }),
            .stop => try app.session.sendPacket(.stop_building, P.Int{ .value = building }),
            .enqueue => |u| try app.session.sendPacket(.add_building_queue, P.AddBuildingQueue{ .ref_id = building, .ot = @intFromEnum(u.kind), .oid = u.id }),
            .dequeue => |d| try app.session.sendPacket(.cancel_building_queue, P.CancelBuildingQueue{ .ref_id = building, .list_i = @intCast(d.index), .ot = @intFromEnum(d.unit.kind), .oid = d.unit.id }),
            .place => |gun| {
                app.closeWindow();
                app.placing = .{ .building = building, .gun = gun };
            },
        }
    }

    fn menuContext(app: *const App) menus.Context {
        const clock = &app.session.world.clock;
        return .{
            .team = app.session.team,
            .players = app.session.players.items,
            .maps = app.session.selectable_maps.items,
            .volume = app.volume,
            .speed = clock.game_speed,
            .paused = clock.paused,
        };
    }

    fn menuCommand(app: *App, cmd: menus.Command) !void {
        const P = net.protocol;
        const s = &app.session;
        switch (cmd) {
            .reshuffle_teams => try s.send(.reshuffle_teams, &.{}),
            .join => |t| try s.sendPacket(.set_team, P.Int{ .value = @intFromEnum(t) }),
            .start_bot => |t| try s.sendPacket(.start_bot, P.Int{ .value = @intFromEnum(t) }),
            .stop_bot => |t| try s.sendPacket(.stop_bot, P.Int{ .value = @intFromEnum(t) }),
            .select_map => |i| try s.sendPacket(.select_map, P.Int{ .value = i }),
            .toggle_pause => try s.sendPacket(.set_game_paused, P.GamePaused{ .game_paused = !s.world.clock.paused }),
            .speed => |v| try s.sendPacket(.set_game_speed, P.Float{ .value = v }),
            .reset_map => try s.send(.reset_map, &.{}),
            .quit => app.quit = true,
            .volume => |v| {
                app.volume = v;
                app.sounds.setVolume(v);
                const names = [_][]const u8{ "volume off", "volume 25%", "volume 50%", "volume 75%", "volume full" };
                app.news.add(names[@min(v, 4)], .{ .r = 0, .g = 0, .b = 0 }, app.realTime());
            },
        }
    }

    fn compMsg(app: *App, m: net.protocol.ComputerMsg, snd: net.protocol.CompSound) void {
        switch (snd) {
            .vehicle, .robot => |which| {
                app.control.notice(.{ .id = m.ref_id, .select = true, .time = app.realTime() });
                app.notices.show(if (which == .robot) .robot_manufactured else .vehicle_manufactured, m.ref_id, app.realTime());
            },
            .gun => {
                app.control.notice(.{ .id = m.ref_id, .open_gui = true, .time = app.realTime() });
                app.notices.show(.gun_manufactured, m.ref_id, app.realTime());
            },
            .vehicle_repaired => app.control.notice(.{ .id = m.ref_id, .time = app.realTime() }),
            else => {},
        }
    }

    /// Send queued orders; the HUD's unit acknowledges them.
    fn sendOrders(app: *App) !void {
        const sent = try app.control.sendOrders(&app.session, app.keys.z, app.prng.random()) orelse return;
        app.hud.portrait.play(portrait.acknowledgeAnim(sent.no_way, app.prng.random()), app.realTime());
    }

    fn hudButton(app: *App, b: hud_mod.Button) void {
        const kind: @import("control.zig").UnitKind = switch (b) {
            .r => .robot,
            .v => .vehicle,
            .g => .cannon,
            .b => {
                app.factory_list.shown = !app.factory_list.shown;
                return;
            },
            .menu => return app.menus.show(.main, false),
            else => return,
        };
        app.selectNext(kind);
    }

    fn selectNext(app: *App, kind: @import("control.zig").UnitKind) void {
        const p = app.mouseMap();
        if (app.control.selectNext(&app.session.world, kind, p[0], p[1], app.realTime(), app.prng.random())) |o| {
            app.lookAt(o.center_x, o.center_y);
        }
    }

    fn keyDown(app: *App, sym: c_uint, unicode: u16) !void {
        switch (sym) {
            c.SDLK_LEFT => app.keys.left = true,
            c.SDLK_RIGHT => app.keys.right = true,
            c.SDLK_UP => app.keys.up = true,
            c.SDLK_DOWN => app.keys.down = true,
            c.SDLK_LSHIFT, c.SDLK_RSHIFT => app.keys.shift = true,
            c.SDLK_LCTRL, c.SDLK_RCTRL => app.keys.ctrl = true,
            c.SDLK_LALT, c.SDLK_RALT => app.keys.alt = true,
            c.SDLK_ESCAPE => {
                if (app.chat) |*t| {
                    t.deinit(app.gpa);
                    app.chat = null;
                } else if (!app.menus.closeTop()) app.menus.show(.main, false);
                return;
            },
            c.SDLK_F1 => return app.session.send(.vote_yes, &.{}),
            c.SDLK_F2 => return app.session.send(.vote_no, &.{}),
            c.SDLK_F3 => return app.session.send(.vote_pass, &.{}),
            else => {},
        }
        if (sym == 'z' and app.chat == null) app.keys.z = true;
        if (app.chat != null) return app.typeChat(unicode);
        if (sym >= '0' and sym <= '9') {
            const n: usize = sym - '0';
            if (app.keys.ctrl) {
                app.control.setGroup(n);
            } else if (app.control.loadGroup(&app.session.world, n, app.prng.random())) |p| app.lookAt(p[0], p[1]);
            return;
        }
        try app.hotkey(unicode);
    }

    fn keyUp(app: *App, sym: c_uint) !void {
        switch (sym) {
            c.SDLK_LEFT => app.keys.left = false,
            c.SDLK_RIGHT => app.keys.right = false,
            c.SDLK_UP => app.keys.up = false,
            c.SDLK_DOWN => app.keys.down = false,
            c.SDLK_LCTRL, c.SDLK_RCTRL => app.keys.ctrl = false,
            c.SDLK_LALT, c.SDLK_RALT => app.keys.alt = false,
            c.SDLK_LSHIFT, c.SDLK_RSHIFT => {
                app.keys.shift = false;
                // Queued orders go out.
                try app.sendOrders();
            },
            'z' => app.keys.z = false,
            else => {},
        }
    }

    /// Letters (ZPlayer::ProcessUnicode). Ctrl+letter comes as a control
    /// character.
    fn hotkey(app: *App, key: u16) !void {
        const world = &app.session.world;
        const rng = app.prng.random();
        switch (key) {
            '\r' => app.chat = .empty,
            '/' => {
                app.chat = .empty;
                try app.chat.?.append(app.gpa, '/');
            },
            'r', 'R' => app.selectNext(.robot),
            'v', 'V' => if (!app.keys.alt) app.selectNext(.vehicle),
            'g', 'G' => app.selectNext(.cannon),
            'b', 'B' => app.factory_list.shown = !app.factory_list.shown,
            'h', 'H' => app.news.history = !app.news.history,
            'p', 'P' => app.menus.show(.player_list, true),
            22 => app.control.selectAll(world, .vehicle, rng), // ctrl+v
            18 => app.control.selectAll(world, .robot, rng), // ctrl+r
            3 => app.control.selectAll(world, .cannon, rng), // ctrl+c
            1 => app.control.selectAll(world, null, rng), // ctrl+a
            ' ' => if (app.control.nextNotice(world, app.realTime(), rng)) |n| {
                app.lookAt(n.obj.center_x, n.obj.center_y);
                if (n.open_gui) _ = app.openWindow(n.obj);
            },
            else => {},
        }
    }

    fn typeChat(app: *App, key: u16) !void {
        const text = &app.chat.?;
        switch (key) {
            '\r' => {
                if (text.items.len > 0) try app.session.chat(text.items);
                text.deinit(app.gpa);
                app.chat = null;
            },
            8 => _ = text.pop(),
            else => if (key >= 32 and key < 127) try text.append(app.gpa, @intCast(key)),
        }
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    /// Sounds of this frame: effects on screen, faces talking, building
    /// loops, music and spoken warnings.
    fn playSounds(app: *App, world: *const game.world.World, v: gfx.Rect, now: f64) void {
        const rng = app.prng.random();
        for (app.fx.sounds.items) |h| {
            const r = h.where;
            if (r.x > v.x + v.w or r.y > v.y + v.h or r.x + r.w < v.x or r.y + r.h < v.y) continue;
            app.sounds.effect(h.sound, now, rng);
        }
        app.fx.sounds.clearRetainingCapacity();
        for ([_]*portrait.Portrait{ &app.hud.portrait, &app.hud.alert_portrait }) |p| if (p.said) |a| {
            p.said = null;
            app.sounds.speak(a, now, rng);
        };

        // Radars and working factories hum while in view.
        var radar = false;
        var factory = false;
        var fort: ?*const Object = null;
        for (world.objects.items) |o| {
            const b = switch (o.kind) {
                .building => |*b| b,
                else => continue,
            };
            if (o.isFort() and o.owner == app.control.team and o.owner != .none) fort = o;
            if (o.isDestroyed() or o.owner == .none) continue;
            if (o.x > v.x + v.w or o.y > v.y + v.h or o.x + o.width_pix < v.x or o.y + o.height_pix < v.y) continue;
            if (b.type == .radar) radar = true;
            if ((b.type == .robot_factory or b.type == .vehicle_factory) and b.state != .select) factory = true;
        }
        app.sounds.loop(.radar, radar);
        app.sounds.loop(.factory, factory);

        // How dangerous it is: enemies near our fort, or fighting.
        var danger: sound.Danger = .calm;
        if (fort) |f| if (!f.isDestroyed()) {
            for (world.objects.items) |o| {
                if (o.owner == .none or o.owner == app.control.team) continue;
                if (o.kind == .building or o.kind == .item) continue;
                const dx: i64 = o.center_x - f.center_x;
                const dy: i64 = o.center_y - f.center_y;
                if (dx * dx + dy * dy <= 250 * 250) {
                    danger = .fort;
                    break;
                }
            }
            if (danger == .calm) for (world.objects.items) |o| {
                const t = world.findOpt(o.attack_target) orelse continue;
                if (t.owner == app.control.team or (o.owner == app.control.team and t.owner != .none)) {
                    danger = .attacking;
                    break;
                }
            };
        };
        app.sounds.music.update(danger, if (fort) |f| f.isDestroyed() else false, now, rng);
        app.speakWarnings(world, fort, now);
    }

    /// "Fort under attack" while the music says so, and "you're losing"
    /// when well behind in units and land (ProcessVerbalWarnings).
    fn speakWarnings(app: *App, world: *const game.world.World, fort: ?*const Object, now: f64) void {
        const team = app.control.team;
        if (team == .none) return;
        var units: [k.Team.count]u32 = @splat(0);
        for (world.objects.items) |o| {
            if (o.isUnit()) units[@intFromEnum(o.owner)] += 1;
        }
        if (units[@intFromEnum(team)] == 0) return;
        const rng = app.prng.random();
        if (app.sounds.music.danger == .fort and now >= app.next_fort_warning) if (fort) |f| {
            app.next_fort_warning = now + 10;
            app.sounds.announce(.fort_under_attack, now, rng);
            app.notices.show(.fort_under_attack, f.ref_id, now);
            app.control.notice(.{ .id = f.ref_id, .time = now });
        };
        if (now < app.next_losing_warning) return;
        var zones: [k.Team.count]u32 = @splat(0);
        for (world.zones.items) |z| zones[@intFromEnum(z.owner)] += 1;
        // The weakest other team with units.
        var worst_units: ?u32 = null;
        var worst_zones: u32 = 0;
        for (1..k.Team.count) |i| {
            if (i == @intFromEnum(team) or units[i] == 0) continue;
            if (worst_units == null) {
                worst_units = units[i];
                worst_zones = zones[i];
                continue;
            }
            worst_units = @min(worst_units.?, units[i]);
            worst_zones = @min(worst_zones, zones[i]);
        }
        const ours = @as(f64, @floatFromInt(units[@intFromEnum(team)])) * 1.7;
        const our_zones = @as(f64, @floatFromInt(zones[@intFromEnum(team)])) * 1.7;
        if (worst_units) |wu| if (@as(f64, @floatFromInt(wu)) > ours and @as(f64, @floatFromInt(worst_zones)) > our_zones) {
            app.next_losing_warning = now + 8;
            app.sounds.losing(now, rng);
        };
    }

    /// The vote in progress, as shown in its box (the server gives every
    /// player one vote).
    fn voteBox(app: *App) ?messages.Notices.Vote {
        const v = app.session.vote;
        if (!v.in_progress) return null;
        const names = [_][]const u8{ "Pause Game", "Resume Game", "Change Map", "Start Bot", "Stop Bot", "Reset Game", "Reshuffle Teams", "Set Game Speed" };
        if (v.kind < 0 or v.kind >= names.len) return null;
        const S = struct {
            var buf: [160]u8 = undefined;
        };
        const kind: usize = @intCast(v.kind);
        const extra: []const u8 = switch (kind) {
            2 => if (v.value >= 0 and v.value < app.session.selectable_maps.items.len) app.session.selectable_maps.items[@intCast(v.value)] else "",
            3, 4 => if (v.value >= 0 and v.value < k.Team.count) @as(k.Team, @enumFromInt(v.value)).name() else "",
            else => "",
        };
        const desc = if (extra.len == 0) names[kind] else if (kind == 2)
            std.fmt.bufPrint(&S.buf, "{s}: {d}. {s}", .{ names[kind], v.value, extra }) catch names[kind]
        else
            std.fmt.bufPrint(&S.buf, "{s}: {s}", .{ names[kind], extra }) catch names[kind];
        var not_passing: usize = 0;
        var yes: usize = 0;
        var no: usize = 0;
        for (app.session.players.items) |p| {
            if (p.vote != .pass) not_passing += 1;
            if (p.vote == .yes) yes += 1;
            if (p.vote == .no) no += 1;
        }
        return .{ .description = desc, .needed = (not_passing + 1) / 2, .yes = yes, .no = no };
    }

    /// The gun being placed, on the tile under the mouse (dimmed where it
    /// can't go).
    fn drawPlacing(app: *App, cv: gfx.Canvas, world: *const game.world.World, building: i32, gun: k.Cannon) void {
        const img = app.sprites.cannon[@intFromEnum(gun)].passive[@intFromEnum(app.control.team)][4] orelse return;
        const p = app.mouseMap();
        const tx = @divFloor(p[0], k.tile_size);
        const ty = @divFloor(p[1], k.tile_size);
        const ok = if (world.find(building)) |b| world.cannonPlacable(b, tx, ty) else false;
        cv.drawAlpha(img, tx * k.tile_size, ty * k.tile_size, if (ok) 255 else 110);
    }

    fn render(app: *App, now: f64) void {
        const black: gfx.Color = .{ .r = 0, .g = 0, .b = 0 };
        app.screen.fill(null, black);
        const area = app.mapArea();
        const cv: gfx.Canvas = .{ .target = app.screen, .clip = area, .dx = -app.view_x, .dy = -app.view_y };
        const v = app.view();
        const world = &app.session.world;
        if (app.control.team != app.session.team) {
            app.closeWindow();
            app.control.reset(app.session.team);
        }
        app.session.world.checkUnitLimitReached();

        if (app.terrain) |*t| {
            const time = world.now();
            app.objects.update(world, t, time);
            app.fx.update(.{ .time = time, .world = world, .terrain = t });
            t.draw(cv, v, time, world.zones.items, app.prng.random());
            app.fx.drawGround(cv, v);
            app.objects.drawPre(cv, world, v);
            app.control.drawRoutes(cv, world, &app.cursors, time);
            app.objects.draw(cv, world, v);
            app.objects.drawAfter(cv, world, v);
            app.fx.draw(cv, v);
            app.control.drawSelection(cv, world, &app.palettes, &app.fonts, time);
            if (app.window) |*w| {
                // Gone, or no longer ours.
                const b = world.find(w.building);
                if (b == null or b.?.owner != app.control.team) app.closeWindow();
            }
            if (app.window) |*w| w.draw(cv, world, &app.window_images, app.sprites, &app.fonts, &app.fx, app.prng.random());
            if (app.placing) |pl| app.drawPlacing(cv, world, pl.building, pl.gun);
            if (app.drag) |d| {
                const p = app.mouseMap();
                drawSelectionBox(cv, &app.palettes, app.control.team, d[0], d[1], p[0], p[1], time);
                // The box selects as it grows.
                app.control.selectBox(world, d[0], d[1], p[0], p[1], app.prng.random());
            }

            const screen_map: gfx.Canvas = .{ .target = app.screen, .clip = area };
            app.factory_list.draw(screen_map, world, app.control.team, &app.list_images, &app.fonts, area);
            app.notices.draw(screen_map, world, app.control.team, world.clock.paused, app.voteBox(), &app.msg_images, &app.fonts, area, now);
            app.news.draw(screen_map, &app.fonts, if (app.factory_list.shown) 5 + 142 else 5, area.h, now);

            app.hud.updateButtons(world, app.session.team);
            app.hud.update(world, time, now, app.prng.random());
            // The HUD shows a new unit: it reports.
            if (app.control.hud_unit != app.hud.portrait.ref_id) app.hud.showUnit(world.findOpt(app.control.hud_unit), now, app.prng.random());
            app.playSounds(world, v, now);
            app.hud.draw(app.screen, .{
                .world = world,
                .team = app.session.team,
                .selected = world.findOpt(app.control.hud_unit),
                .time = time,
                .real_time = now,
                .view = v,
                .chat = if (app.chat) |t_| t_.items else null,
            });
        }

        const screen_cv: gfx.Canvas = .{ .target = app.screen, .clip = .{ .x = 0, .y = 0, .w = app.width, .h = app.height } };
        const ctx = app.menuContext();
        app.menus.update(ctx, now);
        app.menus.draw(screen_cv, &app.menu_art, &app.fonts, ctx, app.width, app.height);
        const over_menu = app.menus.contains(ctx, app.mouse_x, app.mouse_y);
        const kind = if (app.overMap(app.mouse_x, app.mouse_y) and !over_menu) app.control.cursorKind(world, app.drag != null) else .cursor;
        app.cursors.draw(screen_cv, kind, app.control.team, now, app.mouse_x, app.mouse_y);
        _ = c.SDL_Flip(app.screen.surface);
    }
};
