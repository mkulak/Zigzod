//! The Zig Zod engine: game data and rules shared by server, client, bot
//! and map editor.

pub const constants = @import("game/constants.zig");
pub const settings = @import("game/settings.zig");
pub const map = @import("game/map.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
