//! The client program: window, main loop, camera and input (from ZPlayer).

const std = @import("std");
const c = @import("c");
const game = @import("../game.zig");
const net = @import("../net.zig");
const gfx = @import("gfx.zig");
const terrain_mod = @import("terrain.zig");
const Session = @import("session.zig").Session;

const k = game.constants;
const Object = game.object.Object;

pub const hud_width = 100;
pub const hud_height = 36;

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
    session: Session,
    prng: std.Random.DefaultPrng,
    clock_origin: std.Io.Timestamp,

    /// Top-left map pixel shown.
    view_x: i32 = 0,
    view_y: i32 = 0,
    keys: struct { left: bool = false, right: bool = false, up: bool = false, down: bool = false } = .{},
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
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
            .session = Session.init(gpa, conn, terrain_info, .{ .name = options.name, .team = options.team }),
            .prng = .init(@truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)))),
            .clock_origin = std.Io.Clock.awake.now(io),
        };
        app.sheets = terrain_mod.Sheets.load(assets, &app.palettes);
        try app.session.start();
        return app;
    }

    pub fn deinit(app: *App) void {
        const gpa = app.gpa;
        if (app.terrain) |*t| t.deinit();
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
            app.scroll(now - app.last_frame);
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
            },
            .news => |n| std.log.info("news: {s}", .{n.text}),
            else => {},
        };
    }

    // -----------------------------------------------------------------------
    // Camera and input
    // -----------------------------------------------------------------------

    fn mapArea(app: *const App) gfx.Rect {
        return .{ .x = 0, .y = 0, .w = @max(app.width - hud_width, 0), .h = @max(app.height - hud_height, 0) };
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

    fn scroll(app: *App, dt: f64) void {
        const speed = 900.0;
        const amount: i32 = @intFromFloat(@min(dt, 0.1) * speed);
        const edge = 3;
        if (app.keys.left or app.mouse_x < edge) app.view_x -= amount;
        if (app.keys.right or app.mouse_x >= app.width - edge) app.view_x += amount;
        if (app.keys.up or app.mouse_y < edge) app.view_y -= amount;
        if (app.keys.down or app.mouse_y >= app.height - edge) app.view_y += amount;
        app.clampView();
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
                c.SDL_MOUSEMOTION => {
                    app.mouse_x = ev.motion.x;
                    app.mouse_y = ev.motion.y;
                },
                c.SDL_KEYDOWN, c.SDL_KEYUP => {
                    const down = ev.type == c.SDL_KEYDOWN;
                    switch (ev.key.keysym.sym) {
                        c.SDLK_LEFT => app.keys.left = down,
                        c.SDLK_RIGHT => app.keys.right = down,
                        c.SDLK_UP => app.keys.up = down,
                        c.SDLK_DOWN => app.keys.down = down,
                        c.SDLK_ESCAPE => if (down) {
                            app.quit = true;
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    fn render(app: *App, now: f64) void {
        const black: gfx.Color = .{ .r = 0, .g = 0, .b = 0 };
        app.screen.fill(null, black);
        const area = app.mapArea();
        const cv: gfx.Canvas = .{ .target = app.screen, .clip = area, .dx = -app.view_x, .dy = -app.view_y };
        const view: gfx.Rect = .{ .x = app.view_x, .y = app.view_y, .w = area.w, .h = area.h };

        if (app.terrain) |*t| {
            t.draw(cv, view, app.session.world.now(), app.session.world.zones.items, app.prng.random());
            app.renderObjects(cv, view);
        }
        _ = now;
        _ = c.SDL_Flip(app.screen.surface);
    }

    /// Placeholder until the objects' graphics are ported: team colored
    /// boxes with a health bar.
    fn renderObjects(app: *App, cv: gfx.Canvas, view: gfx.Rect) void {
        for (app.session.world.objects.items) |o| {
            const r: gfx.Rect = .{ .x = o.x, .y = o.y, .w = o.width_pix, .h = o.height_pix };
            if (r.intersect(view) == null) continue;
            const color = app.palettes.color(o.owner);
            cv.outline(r, if (o.isDestroyed()) gfx.Color{ .r = 60, .g = 60, .b = 60 } else color);
            if (o.isUnit()) {
                const w: i32 = @intFromFloat(@as(f64, @floatFromInt(r.w)) * o.healthRatio());
                cv.fill(.{ .x = r.x, .y = r.y - 3, .w = w, .h = 2 }, .{ .r = 0, .g = 200, .b = 0 });
            }
        }
    }
};
