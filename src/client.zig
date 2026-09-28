//! The game client (in progress; the C++ client is still the one to play).

pub const gfx = @import("client/gfx.zig");
pub const terrain = @import("client/terrain.zig");
pub const session = @import("client/session.zig");
pub const app = @import("client/app.zig");

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(terrain.Terrain);
    @import("std").testing.refAllDecls(session.Session);
    @import("std").testing.refAllDecls(app.App);
}
