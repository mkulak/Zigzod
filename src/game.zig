//! The Zig Zod engine: game data and rules shared by server, client, bot
//! and map editor.

pub const constants = @import("game/constants.zig");
pub const clock = @import("game/clock.zig");
pub const settings = @import("game/settings.zig");
pub const map = @import("game/map.zig");
pub const pathfinding = @import("game/pathfinding.zig");
pub const buildlist = @import("game/buildlist.zig");
pub const object = @import("game/object.zig");
pub const world = @import("game/world.zig");
pub const sim = @import("game/sim.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
