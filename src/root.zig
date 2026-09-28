//! Zig part of the Zod Engine.
//!
//! The engine is being ported from C++ to Zig one module at a time. Each
//! file here replaces the implementation of one C++ source file and exports
//! C-ABI functions that the remaining C++ code calls (declared in
//! src/zod_zig.h).

comptime {
    _ = @import("common.zig");
    _ = @import("ztime.zig");
    _ = @import("zencrypt_aes.zig");
    _ = @import("sdl_rotozoom.zig");
    _ = @import("zfont.zig");
}

test {
    _ = @import("game.zig");
    _ = @import("net.zig");
    _ = @import("server.zig");
    _ = @import("client.zig");
    _ = @import("common.zig");
    _ = @import("ztime.zig");
    _ = @import("zencrypt_aes.zig");
    _ = @import("sdl_rotozoom.zig");
    _ = @import("zfont.zig");
}
