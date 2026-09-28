//! Build the Zod engine: one program, `zod`, with the game server, client,
//! computer player and map editor.
//!
//!   zig build                  # -> zig-out/bin/zod
//!   zig build run              # play the campaign against a bot
//!   zig build run -- edit bin/blank_maps/level_blank_01.map
//!   zig build test
//!
//! Everything it needs is built from source: SDL 3 (castholm/SDL, SDL
//! ported to the Zig build system) and stb_vorbis for the music. On macOS
//! the Xcode command line tools provide the system SDK.
//!
//! Tested with Zig 0.16.0.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Optimized by default: a Debug build of the game is noticeably slower.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
    });
    const sdl = sdl_dep.artifact("SDL3");
    const stb = b.dependency("stb", .{});

    // C headers for the Zig code (src/c.h -> `@import("c")`).
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(sdl_dep.path("include"));
    translate_c.addIncludePath(stb.path("."));
    const c_mod = translate_c.createModule();

    const options = b.addOptions();
    options.addOption([]const u8, "data_dir", b.pathFromRoot("bin"));

    const zod_mod = makeModule(b, target, optimize, c_mod, options, sdl, stb);
    const zod = b.addExecutable(.{ .name = "zod", .root_module = zod_mod });
    b.installArtifact(zod);

    // `zig build run [-- command options]`: by default, the campaign on a
    // local server with a bot, and the client joining it.
    const run = b.addRunArtifact(zod);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args) else run.addArgs(&.{"play"});
    b.step("run", "Run zod (default: `zod play`; pass a command after --)").dependOn(&run.step);

    // `zig build test`: the unit tests.
    const test_mod = makeModule(b, target, optimize, c_mod, options, sdl, stb);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    // Tests read game data relative to the repository root.
    run_tests.setCwd(b.path("."));
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);
}

fn makeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_mod: *std.Build.Module,
    options: *std.Build.Step.Options,
    sdl: *std.Build.Step.Compile,
    stb: *std.Build.Dependency,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);
    mod.addImport("c", c_mod);
    mod.linkLibrary(sdl);
    mod.addCSourceFile(.{
        .file = stb.path("stb_vorbis.c"),
        // Decoding only; stb's own code has warnings we can't fix.
        .flags = &.{ "-std=c99", "-w", "-fno-sanitize=undefined" },
    });
    return mod;
}
