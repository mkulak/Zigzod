//! Text formatted into fixed buffers (for the screen, chat and news).
//!
//! Such text is cut to its buffer when it doesn't fit, rather than being
//! dropped or failing: a long player name shortens the line it is in.

const std = @import("std");

/// `fmt` formatted into `buf`, cut to fit.
pub fn fit(buf: []u8, comptime fmt: []const u8, args: anytype) []u8 {
    var w: std.Io.Writer = .fixed(buf);
    // A full buffer is the only error of a fixed writer.
    w.print(fmt, args) catch {};
    return w.buffered();
}

/// A line put together piece by piece, cut to its buffer.
pub const Line = struct {
    w: std.Io.Writer,

    pub fn init(buf: []u8) Line {
        return .{ .w = .fixed(buf) };
    }

    pub fn add(l: *Line, comptime fmt: []const u8, args: anytype) void {
        // A full buffer is the only error of a fixed writer.
        l.w.print(fmt, args) catch {};
    }

    pub fn text(l: *const Line) []const u8 {
        return l.w.buffered();
    }
};

test "text is cut to its buffer" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("12:05", fit(&buf, "{d}:{d:0>2}", .{ 12, 5 }));
    try std.testing.expectEqualStrings("a long n", fit(&buf, "{s}", .{"a long name"}));
    var line: Line = .init(&buf);
    line.add("{s}", .{"abc"});
    line.add(", {d}", .{12345});
    try std.testing.expectEqualStrings("abc, 123", line.text());
}
