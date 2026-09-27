//! Zig port of ZodEgine_Libs/QZod_DnSeparate/ztime.cpp: the game clock,
//! which can be paused and run at a different speed.
//!
//! The ZTime class is still declared in C++ (ztime.h) because the rest of
//! the engine uses it; its methods forward to the functions below, which
//! operate on the same memory through this extern struct.

const std = @import("std");
const common = @import("common.zig");

/// Must match the field layout of `class ZTime` in ztime.h (checked by a
/// static_assert there and the comptime check below).
pub const ZTime = extern struct {
    paused: bool = false,
    game_speed: f64 = 1.0,
    /// Current game time in seconds, refreshed by update().
    ztime: f64 = 0,
    /// Game time at the last pause/resume/speed change...
    last_change_front_time: f64 = 0,
    /// ...and the real time when it happened.
    last_change_back_time: f64 = 0,

    comptime {
        std.debug.assert(@sizeOf(ZTime) == 40);
        std.debug.assert(@offsetOf(ZTime, "game_speed") == 8);
        std.debug.assert(@offsetOf(ZTime, "last_change_back_time") == 32);
    }

    /// Game time that corresponds to real time `now`.
    fn gameTimeAt(self: *const ZTime, now: f64) f64 {
        return self.last_change_front_time + (now - self.last_change_back_time) * self.game_speed;
    }

    /// Start a new segment at real time `now` (keeps game time continuous).
    fn rebase(self: *ZTime, now: f64) void {
        self.last_change_front_time = self.gameTimeAt(now);
        self.last_change_back_time = now;
    }

    pub fn updateAt(self: *ZTime, now: f64) void {
        if (!self.paused) self.ztime = self.gameTimeAt(now);
    }

    pub fn pauseAt(self: *ZTime, now: f64) void {
        if (self.paused) return;
        self.paused = true;
        self.rebase(now);
    }

    pub fn resumeAt(self: *ZTime, now: f64) void {
        if (!self.paused) return;
        self.paused = false;
        // Game time stood still while paused: continue from the same value.
        self.last_change_back_time = now;
    }

    pub fn setGameSpeedAt(self: *ZTime, new_speed: f64, now: f64) void {
        if (!self.paused) self.rebase(now);
        self.game_speed = @max(new_speed, 0);
    }
};

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

test "game time runs, pauses and changes speed" {
    const eq = std.testing.expectApproxEqAbs;
    var t: ZTime = .{};

    t.updateAt(10);
    try eq(10, t.ztime, 1e-9);

    t.pauseAt(10);
    t.updateAt(15); // paused: no progress
    try eq(10, t.ztime, 1e-9);

    t.resumeAt(15);
    t.updateAt(17);
    try eq(12, t.ztime, 1e-9);

    t.setGameSpeedAt(2, 17);
    t.updateAt(18);
    try eq(14, t.ztime, 1e-9);

    t.setGameSpeedAt(-1, 18); // clamped to 0
    t.updateAt(100);
    try eq(14, t.ztime, 1e-9);
}
