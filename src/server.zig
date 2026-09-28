//! The game server.

pub const server = @import("server/server.zig");
pub const commands = @import("server/commands.zig");
pub const bots = @import("server/bots.zig");

pub const Server = server.Server;
pub const Options = server.Options;

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(server.Server);
}
