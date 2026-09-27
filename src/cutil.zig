//! Helpers for calling C APIs (SDL) from Zig.

const std = @import("std");

/// A C pointer (`[*c]T`) as an optional single-item Zig pointer.
pub fn nonNull(p: anytype) ?*std.meta.Child(@TypeOf(p)) {
    return if (p == null) null else @ptrCast(p);
}
