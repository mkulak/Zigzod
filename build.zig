//! Build the Zod engine: one program, `zod`, with the game server, client,
//! computer player and map editor.
//!
//!   ./macos/build_deps.sh      # once: SDL 1.2 + SDL_image/SDL_mixer
//!   zig build                  # -> zig-out/bin/zod
//!   zig build run              # play the campaign against a bot
//!   zig build run -- edit bin/blank_maps/level_blank_01.map
//!   zig build test
//!
//! SDL comes from the system through pkg-config, so only native builds are
//! supported (the SDL libraries are for the host machine).
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
    const deps_prefix = b.option([]const u8, "deps-prefix", "Where macos/build_deps.sh installed the SDL add-on libraries (default: deps/install)") orelse
        b.pathFromRoot("deps/install");

    const os_tag = target.result.os.tag;
    if (!(target.query.isNativeOs() and target.query.isNativeCpu())) {
        std.debug.print("warning: SDL is taken from this machine via pkg-config; cross-compiling is not supported\n", .{});
    }

    // pkg-config should also find the libraries built by macos/build_deps.sh
    // and, on macOS, the Homebrew ones.
    setupPkgConfigPath(b, deps_prefix, os_tag);
    const sdl = querySdl(b);

    // C headers for the Zig code (src/c.h -> `@import("c")`).
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    for (sdl.include_dirs) |dir| translate_c.addSystemIncludePath(.{ .cwd_relative = dir });
    for (sdl.macros) |m| translate_c.defineCMacro(m.name, m.value);
    const c_mod = translate_c.createModule();

    const options = b.addOptions();
    options.addOption([]const u8, "data_dir", b.pathFromRoot("bin"));

    const zod_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zod_mod.addOptions("build_options", options);
    zod_mod.addImport("c", c_mod);
    linkSdl(zod_mod, sdl, os_tag);
    const zod = b.addExecutable(.{ .name = "zod", .root_module = zod_mod });
    b.installArtifact(zod);

    // `zig build run [-- command options]`: by default, the campaign on a
    // local server with a bot, and the client joining it.
    const run = b.addRunArtifact(zod);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args) else run.addArgs(&.{"play"});
    b.step("run", "Run zod (default: `zod play`; pass a command after --)").dependOn(&run.step);

    // `zig build test`: the unit tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addImport("c", c_mod);
    linkSdl(test_mod, sdl, os_tag);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    // Tests read game data relative to the repository root.
    run_tests.setCwd(b.path("."));
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);
}

fn linkSdl(mod: *std.Build.Module, sdl: SdlFlags, os_tag: std.Target.Os.Tag) void {
    for (sdl.lib_dirs) |dir| {
        mod.addLibraryPath(.{ .cwd_relative = dir });
        if (os_tag != .macos) mod.addRPath(.{ .cwd_relative = dir });
    }
    for (sdl.libs) |lib| mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    for (sdl.frameworks) |fw| mod.linkFramework(fw, .{});
    if (os_tag == .macos) mod.linkFramework("Cocoa", .{});
}

const Macro = struct { name: []const u8, value: []const u8 };

const SdlFlags = struct {
    include_dirs: []const []const u8,
    lib_dirs: []const []const u8,
    libs: []const []const u8,
    frameworks: []const []const u8,
    macros: []const Macro,
};

/// Ask pkg-config for SDL 1.2 and its add-on libraries and turn the flags
/// into build-system calls ourselves. (src/c.h includes <SDL/SDL.h>, so the
/// parent of every include dir is needed too, and macOS link flags such as
/// -Wl,-framework,Cocoa need translating.)
fn querySdl(b: *std.Build) SdlFlags {
    const sdl_pkg: []const u8 = blk: {
        var code: u8 = undefined;
        for ([_][]const u8{ "sdl12_compat", "sdl" }) |name| {
            _ = b.runAllowFail(&.{ "pkg-config", "--exists", name }, &code, .ignore) catch continue;
            break :blk name;
        }
        std.process.fatal(
            "SDL 1.2 not found via pkg-config. Run ./macos/build_deps.sh first " ++
                "(macOS: it installs sdl12-compat with Homebrew).",
            .{},
        );
    };
    for ([_][]const u8{ "SDL_image", "SDL_mixer" }) |name| {
        var code: u8 = undefined;
        _ = b.runAllowFail(&.{ "pkg-config", "--exists", name }, &code, .ignore) catch
            std.process.fatal("{s} (SDL 1.2 version) not found via pkg-config. Run ./macos/build_deps.sh first.", .{name});
    }

    const pkgs = [_][]const u8{ "SDL_image", "SDL_mixer", sdl_pkg };
    const cflags = b.run(&(.{ "pkg-config", "--cflags" } ++ pkgs));
    const ldflags = b.run(&(.{ "pkg-config", "--libs" } ++ pkgs));

    var include_dirs: std.ArrayList([]const u8) = .empty;
    var lib_dirs: std.ArrayList([]const u8) = .empty;
    var libs: std.ArrayList([]const u8) = .empty;
    var frameworks: std.ArrayList([]const u8) = .empty;
    var macros: std.ArrayList(Macro) = .empty;
    const gpa = b.allocator;

    var it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            const dir = flag[2..];
            appendUnique(gpa, &include_dirs, dir);
            appendUnique(gpa, &include_dirs, std.fs.path.dirname(dir) orelse dir);
        } else if (std.mem.startsWith(u8, flag, "-D")) {
            const def = flag[2..];
            if (std.mem.indexOfScalar(u8, def, '=')) |eq| {
                macros.append(gpa, .{ .name = def[0..eq], .value = def[eq + 1 ..] }) catch @panic("OOM");
            } else {
                macros.append(gpa, .{ .name = def, .value = "1" }) catch @panic("OOM");
            }
        }
    }

    var expect_framework = false;
    it = std.mem.tokenizeAny(u8, ldflags, " \t\r\n");
    while (it.next()) |flag| {
        if (expect_framework) {
            appendUnique(gpa, &frameworks, flag);
            expect_framework = false;
        } else if (std.mem.startsWith(u8, flag, "-L")) {
            appendUnique(gpa, &lib_dirs, flag[2..]);
        } else if (std.mem.startsWith(u8, flag, "-l")) {
            appendUnique(gpa, &libs, flag[2..]);
        } else if (std.mem.eql(u8, flag, "-framework")) {
            expect_framework = true;
        } else if (std.mem.startsWith(u8, flag, "-Wl,-framework,")) {
            appendUnique(gpa, &frameworks, flag["-Wl,-framework,".len..]);
        }
        // Anything else (-pthread, -Wl,-rpath,...) is not needed.
    }

    return .{
        .include_dirs = include_dirs.items,
        .lib_dirs = lib_dirs.items,
        .libs = libs.items,
        .frameworks = frameworks.items,
        .macros = macros.items,
    };
}

fn appendUnique(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []const u8) void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, item)) return;
    list.append(gpa, item) catch @panic("OOM");
}

fn setupPkgConfigPath(b: *std.Build, deps_prefix: []const u8, os_tag: std.Target.Os.Tag) void {
    const env = &b.graph.environ_map;
    var path: []const u8 = b.fmt("{s}/lib/pkgconfig", .{deps_prefix});
    if (os_tag == .macos) {
        var code: u8 = undefined;
        if (b.runAllowFail(&.{ "brew", "--prefix" }, &code, .ignore)) |out| {
            path = b.fmt("{s}:{s}/lib/pkgconfig", .{ path, std.mem.trim(u8, out, " \t\r\n") });
        } else |_| {}
    }
    if (env.get("PKG_CONFIG_PATH")) |existing| path = b.fmt("{s}:{s}", .{ path, existing });
    env.put("PKG_CONFIG_PATH", path) catch @panic("OOM");
}
