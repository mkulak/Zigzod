//! The window (SDL3): everything is drawn in software into `frame`, which
//! is shown each frame through a texture, scaled to the window's real
//! pixels without smoothing (sharp on high density screens).

const std = @import("std");
const c = @import("c");
const gfx = @import("gfx.zig");

pub const Error = error{ SdlInitFailed, SdlWindowFailed, OutOfMemory };

pub const Display = struct {
    gpa: std.mem.Allocator,
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    /// What to draw into; the window's size in (logical) pixels.
    frame: gfx.Image,

    /// Open a window (and SDL).
    pub fn open(gpa: std.mem.Allocator, title: [:0]const u8, w: i32, h: i32, fullscreen: bool) Error!Display {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.log.err("SDL: {s}", .{c.SDL_GetError()});
            return error.SdlInitFailed;
        }
        errdefer c.SDL_Quit();
        var flags: c.SDL_WindowFlags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (fullscreen) flags |= c.SDL_WINDOW_FULLSCREEN;
        var window: ?*c.SDL_Window = null;
        var renderer: ?*c.SDL_Renderer = null;
        if (!c.SDL_CreateWindowAndRenderer(title.ptr, w, h, flags, &window, &renderer)) {
            std.log.err("SDL: {s}", .{c.SDL_GetError()});
            return error.SdlWindowFailed;
        }
        errdefer {
            c.SDL_DestroyRenderer(renderer);
            c.SDL_DestroyWindow(window);
        }
        _ = c.SDL_HideCursor();
        var d: Display = .{ .gpa = gpa, .window = window.?, .renderer = renderer.?, .texture = undefined, .frame = undefined };
        // Full screen may have given another size.
        var ww: c_int = w;
        var wh: c_int = h;
        _ = c.SDL_GetWindowSize(d.window, &ww, &wh);
        try d.makeFrame(ww, wh);
        return d;
    }

    pub fn close(d: *Display) void {
        c.SDL_DestroyTexture(d.texture);
        d.frame.deinit(d.gpa);
        c.SDL_DestroyRenderer(d.renderer);
        c.SDL_DestroyWindow(d.window);
        c.SDL_Quit();
    }

    fn makeFrame(d: *Display, w: i32, h: i32) Error!void {
        d.frame = try gfx.Image.create(d.gpa, @max(w, 1), @max(h, 1));
        errdefer d.frame.deinit(d.gpa);
        d.texture = c.SDL_CreateTexture(d.renderer, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_STREAMING, d.frame.w, d.frame.h) orelse return error.SdlWindowFailed;
        _ = c.SDL_SetTextureScaleMode(d.texture, c.SDL_SCALEMODE_NEAREST);
        // The frame's alpha means nothing on screen.
        _ = c.SDL_SetTextureBlendMode(d.texture, c.SDL_BLENDMODE_NONE);
    }

    /// The window changed size.
    pub fn resize(d: *Display, w: i32, h: i32) Error!void {
        if (w == d.frame.w and h == d.frame.h) return;
        c.SDL_DestroyTexture(d.texture);
        d.frame.deinit(d.gpa);
        try d.makeFrame(w, h);
    }

    /// Show the frame.
    pub fn present(d: *Display) void {
        _ = c.SDL_UpdateTexture(d.texture, null, d.frame.pixels, d.frame.w * 4);
        _ = c.SDL_RenderTexture(d.renderer, d.texture, null, null);
        _ = c.SDL_RenderPresent(d.renderer);
    }

    /// Typed text arrives as text events while this is on (chat).
    pub fn textInput(d: *Display, on: bool) void {
        _ = if (on) c.SDL_StartTextInput(d.window) else c.SDL_StopTextInput(d.window);
    }
};
