//! Zig port of ZodEgine_Libs/QZod_DnSeparate/ztime.cpp: the game clock,
//! which can be paused and run at a different speed.
//!
//! The ZTime class is still declared in C++ (ztime.h) because the rest of
//! the engine uses it; its methods forward to the functions below, which
//! operate on the same memory through this extern struct.

const std = @import("std");
const common = @import("common.zig");

pub const ZTime = @import("game/clock.zig").Clock;

pub export fn zod_ztime_init(t: *ZTime) void {
    t.* = .{};
}

pub export fn zod_ztime_update(t: *ZTime) void {
    t.updateAt(common.zod_current_time());
}

pub export fn zod_ztime_pause(t: *ZTime) void {
    t.pauseAt(common.zod_current_time());
}

pub export fn zod_ztime_resume(t: *ZTime) void {
    t.resumeAt(common.zod_current_time());
}

pub export fn zod_ztime_set_game_speed(t: *ZTime, new_speed: f64) void {
    t.setGameSpeedAt(new_speed, common.zod_current_time());
}
