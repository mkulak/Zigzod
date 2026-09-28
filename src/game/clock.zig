//! The game clock: game time follows real time at an adjustable speed and
//! stands still while paused (from QZod_DnSeparate/ztime.cpp).

const std = @import("std");

/// Extern because the C++ engine shares it (`class ZTime` in ztime.h must
/// have the same layout, checked by a static_assert there and below).
pub const Clock = extern struct {
    paused: bool = false,
    game_speed: f64 = 1.0,
    /// Current game time in seconds, refreshed by update().
    ztime: f64 = 0,
    /// Game time at the last pause/resume/speed change...
    last_change_front_time: f64 = 0,
    /// ...and the real time when it happened.
    last_change_back_time: f64 = 0,

    comptime {
        std.debug.assert(@sizeOf(Clock) == 40);
        std.debug.assert(@offsetOf(Clock, "game_speed") == 8);
        std.debug.assert(@offsetOf(Clock, "last_change_back_time") == 32);
    }

    /// Game time that corresponds to real time `now`.
    fn gameTimeAt(self: *const Clock, now: f64) f64 {
        return self.last_change_front_time + (now - self.last_change_back_time) * self.game_speed;
    }

    /// Start a new segment at real time `now` (keeps game time continuous).
    fn rebase(self: *Clock, now: f64) void {
        self.last_change_front_time = self.gameTimeAt(now);
        self.last_change_back_time = now;
    }

    pub fn updateAt(self: *Clock, now: f64) void {
        if (!self.paused) self.ztime = self.gameTimeAt(now);
    }

    pub fn pauseAt(self: *Clock, now: f64) void {
        if (self.paused) return;
        self.paused = true;
        self.rebase(now);
    }

    pub fn resumeAt(self: *Clock, now: f64) void {
        if (!self.paused) return;
        self.paused = false;
        // Game time stood still while paused: continue from the same value.
        self.last_change_back_time = now;
    }

    pub fn setGameSpeedAt(self: *Clock, new_speed: f64, now: f64) void {
        if (!self.paused) self.rebase(now);
        self.game_speed = @max(new_speed, 0);
    }
};

test "game time runs, pauses and changes speed" {
    const eq = std.testing.expectApproxEqAbs;
    var t: Clock = .{};

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
