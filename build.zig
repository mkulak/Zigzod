//! Build the Zod Engine (C++ / SDL 1.2) with the Zig toolchain.
//!
//!   ./macos/build_deps.sh      # once: SDL 1.2 + SDL_image/SDL_mixer/SDL_ttf
//!   zig build                  # -> zig-out/bin/zod_engine, zig-out/bin/zod_map_editor
//!   zig build run              # play (campaign, windowed); `zig build run -- -h` for options
//!   zig build run-editor -- -f blank_maps/level_blank_01.map
//!
//! Zig's bundled clang compiles the existing C++ sources against libc++.
//! SDL comes from the system through pkg-config, so only native builds are
//! supported (the SDL libraries are for the host machine).
//!
//! Tested with Zig 0.16.0.

const std = @import("std");

/// The eight engine libraries of the original qmake project. They reference
/// each other circularly, so all of them are compiled into every executable.
const engine_libs = [_]struct { dir: []const u8, files: []const []const u8 }{
    .{ .dir = "QZod_DnSeparate", .files = &.{
        "qzod_dnseparate.cpp", "common.cpp",       "event_handler.cpp",
        "zfont.cpp",           "zfont_engine.cpp", "zmysql.cpp",
        "zpsettings.cpp",      "zsdl.cpp",         "zsdl_opengl.cpp",
    } },
    .{ .dir = "QZod_DnMap", .files = &.{
        "qzod_dnmap.cpp",                "qzod_map.cpp", "zmap_crater_graphics.cpp", "zteam.cpp",
        "finding/zpath_finding_old.cpp",
    } },
    .{ .dir = "QZod_DnSoundEngine", .files = &.{
        "qzod_dnsoundengine.cpp", "qzod_soundengine_old.cpp", "zvote.cpp",
    } },
    .{ .dir = "QZod_DnSettings", .files = &.{
        "qzod_dnsettings.cpp", "qzod_settings_old.cpp", "zbuildlist.cpp",
    } },
    .{ .dir = "QZod_DnGui", .files = &.{
        "qzod_dngui.cpp",             "gmm_change_teams.cpp", "gmm_main_menu.cpp",
        "gmm_manage_bots.cpp",        "gmm_options.cpp",      "gmm_player_list.cpp",
        "gmm_select_map.cpp",         "gmm_warning.cpp",      "zgui_main_menu_base.cpp",
        "zgui_main_menu_widgets.cpp", "gmmw_button.cpp",      "gmmw_label.cpp",
        "gmmw_list.cpp",              "gmmw_radio.cpp",       "gmmw_team_color.cpp",
    } },
    .{ .dir = "QZod_DnEffect", .files = &.{
        "qzod_dneffect.cpp",    "ebridgeturrent.cpp",    "ebullet.cpp",
        "ecannondeath.cpp",     "ecraneconco.cpp",       "edeath.cpp",
        "edeathsparks.cpp",     "eflame.cpp",            "elaser.cpp",
        "elightinitfire.cpp",   "elightrocket.cpp",      "emapobjectturrent.cpp",
        "emissilecrockets.cpp", "emomissilerockets.cpp", "epyrofire.cpp",
        "erobotdeath.cpp",      "erobotturrent.cpp",     "erockparticle.cpp",
        "erockturrent.cpp",     "esideexplosion.cpp",    "estandard.cpp",
        "etankdirt.cpp",        "etankoil.cpp",          "etanksmoke.cpp",
        "etankspark.cpp",       "etoughmushroom.cpp",    "etoughrocket.cpp",
        "etoughsmoke.cpp",      "etrack.cpp",            "eturrentmissile.cpp",
        "eunitparticle.cpp",    "qzod_effect_old.cpp",
    } },
    // Buildings/zbuildlist.cpp is left out on purpose: it duplicates
    // QZod_DnSettings/zbuildlist.cpp (same ZBuildList class).
    .{ .dir = "QZod_DnObjects", .files = &.{
        "qzod_dnobjects.cpp",      "cursor.cpp",                    "oflag.cpp",
        "ogrenades.cpp",           "ohut.cpp",                      "omapobject.cpp",
        "orock.cpp",               "orockets.cpp",                  "zcomp_message_engine.cpp",
        "zgfile.cpp",              "zgui_window.cpp",               "zhud.cpp",
        "zmini_map.cpp",           "zmusic_engine.cpp",             "zobject.cpp",
        "zunitrating.cpp",         "Animals/abird.cpp",             "Animals/ahutanimal.cpp",
        "Buildings/bbridge.cpp",   "Buildings/bfort.cpp",           "Buildings/bradar.cpp",
        "Buildings/brepair.cpp",   "Buildings/brobot.cpp",          "Buildings/bvehicle.cpp",
        "Buildings/zbuilding.cpp", "Cannon/cgatling.cpp",           "Cannon/cgun.cpp",
        "Cannon/chowitzer.cpp",    "Cannon/cmissilecannon.cpp",     "Cannon/zcannon.cpp",
        "Gw/gwcreateuser.cpp",     "Gw/gwfactory_list.cpp",         "Gw/gwlogin.cpp",
        "Gw/gwproduction.cpp",     "Gw/gwproduction_fus.cpp",       "Gw/gwproduction_us.cpp",
        "Robots/rgrunt.cpp",       "Robots/rlaser.cpp",             "Robots/rpsycho.cpp",
        "Robots/rpyro.cpp",        "Robots/rsniper.cpp",            "Robots/rtough.cpp",
        "Robots/zrobot.cpp",       "Vehicles/vapc.cpp",             "Vehicles/vcrane.cpp",
        "Vehicles/vheavy.cpp",     "Vehicles/vjeep.cpp",            "Vehicles/vlight.cpp",
        "Vehicles/vmedium.cpp",    "Vehicles/vmissilelauncher.cpp", "Vehicles/zvehicle.cpp",
    } },
    .{ .dir = "QZod_DnClientServer", .files = &.{
        "qzod_dnclientserver.cpp", "client_socket.cpp", "server_socket.cpp",
        "socket_handler.cpp",      "zbot.cpp",          "zbot_events.cpp",
        "zclient.cpp",             "zcore.cpp",         "zplayer.cpp",
        "zplayer_events.cpp",      "zserver.cpp",       "zserver_commands.cpp",
        "zserver_events.cpp",      "ztray.cpp",
    } },
};

/// "Export" macros of the libraries. Everything is linked statically into
/// the executables, so they just have to be defined consistently.
const export_macros = [_][]const u8{
    "QZOD_DNSEPARATE_LIBRARY", "QZOD_DNMAP_LIBRARY",          "QZOD_DNSOUNDENGINE_LIBRARY",
    "QZOD_DNSETTINGS_LIBRARY", "QZOD_DNGUI_LIBRARY",          "QZOD_DNEFFECT_LIBRARY",
    "QZOD_DNOBJECTS_LIBRARY",  "QZOD_DNCLIENTSERVER_LIBRARY",
};

const cxx_flags = [_][]const u8{
    "-std=gnu++11",
    "-fno-strict-aliasing",
    // Decades-old code: don't drown the build in warnings.
    "-w",
    "-Wno-c++11-narrowing",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Optimized by default: a Debug build of the game is noticeably slower.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const use_opengl = b.option(bool, "opengl", "Build with OpenGL rendering support (default: true)") orelse true;
    const deps_prefix = b.option([]const u8, "deps-prefix", "Where macos/build_deps.sh installed the SDL add-on libraries (default: deps/install)") orelse
        b.pathFromRoot("deps/install");

    const os_tag = target.result.os.tag;
    const native = target.query.isNativeOs() and target.query.isNativeCpu();
    if (!native) {
        std.debug.print("warning: SDL is taken from this machine via pkg-config; cross-compiling is not supported\n", .{});
    }

    // pkg-config should also find the libraries built by macos/build_deps.sh
    // and, on macOS, the Homebrew ones.
    setupPkgConfigPath(b, deps_prefix, os_tag);

    // Sources include engine headers as <lib_qZod_DnXxx/header.h>; the qmake
    // build produced that layout by copying headers into include/. Recreate it
    // from the source tree in the build cache.
    const gen_includes = b.addWriteFiles();
    for (engine_libs) |lib| {
        _ = gen_includes.addCopyDirectory(
            b.path(b.fmt("ZodEgine_Libs/{s}", .{lib.dir})),
            b.fmt("lib_qZod_{s}", .{lib.dir["QZod_".len..]}),
            .{ .include_extensions = &.{ ".h", ".hpp" } },
        );
    }

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

    // The engine: the remaining C++ sources plus the parts already ported to
    // Zig (src/root.zig), as one static library shared by both programs.
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        // The C++ code relies on behaviour UBSan would turn into traps.
        .sanitize_c = .off,
    });
    addEngineCompileFlags(b, core_mod, gen_includes.getDirectory(), sdl, use_opengl, os_tag);
    for (engine_libs) |lib| {
        core_mod.addCSourceFiles(.{
            .root = b.path(b.fmt("ZodEgine_Libs/{s}", .{lib.dir})),
            .files = lib.files,
            .flags = &cxx_flags,
        });
    }
    core_mod.addImport("c", c_mod);
    const core = b.addLibrary(.{ .name = "zodcore", .root_module = core_mod, .linkage = .static });

    const exes = [_]struct { name: []const u8, sources: []const []const u8 }{
        .{ .name = "zod_engine", .sources = &.{ "zod_engine/main.cpp", "zod_engine/main_options.cpp" } },
        .{ .name = "zod_map_editor", .sources = &.{"zod_map_editor/main.cpp"} },
    };

    var compiled: [exes.len]*std.Build.Step.Compile = undefined;
    for (exes, 0..) |e, i| {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .sanitize_c = .off,
        });
        addEngineCompileFlags(b, mod, gen_includes.getDirectory(), sdl, use_opengl, os_tag);
        linkEngineLibraries(mod, sdl, use_opengl, os_tag);
        mod.addCSourceFiles(.{ .files = e.sources, .flags = &cxx_flags });
        mod.linkLibrary(core);

        const exe = b.addExecutable(.{ .name = e.name, .root_module = mod });
        b.installArtifact(exe);
        compiled[i] = exe;
    }

    // `zig build test`: unit tests of the Zig modules.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("c", c_mod);
    linkEngineLibraries(test_mod, sdl, use_opengl, os_tag);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    b.step("test", "Run the unit tests of the Zig modules").dependOn(&run_tests.step);

    // `zig build run` / `zig build run-editor`: the game loads assets
    // relative to bin/, so run from there.
    const run_game = b.addRunArtifact(compiled[0]);
    run_game.setCwd(b.path("bin"));
    run_game.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_game.addArgs(args);
    } else {
        run_game.addArgs(&.{ "-l", "map_list.txt", "-t", "red", "-b", "blue", "-w", "-r", "800x600" });
    }
    b.step("run", "Run the game (default: campaign in a window; pass options after --)").dependOn(&run_game.step);

    const run_editor = b.addRunArtifact(compiled[1]);
    run_editor.setCwd(b.path("bin"));
    run_editor.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_editor.addArgs(args);
    b.step("run-editor", "Run the map editor (pass options after --)").dependOn(&run_editor.step);
}

/// Include paths and macros needed to compile engine C++ code.
fn addEngineCompileFlags(
    b: *std.Build,
    mod: *std.Build.Module,
    gen_includes: std.Build.LazyPath,
    sdl: SdlFlags,
    use_opengl: bool,
    os_tag: std.Target.Os.Tag,
) void {
    mod.addIncludePath(b.path("cmake/qt_shim"));
    mod.addIncludePath(gen_includes);
    // C declarations of the Zig functions (zod_zig.h).
    mod.addIncludePath(b.path("src"));
    // Each engine directory is also on the include path, like qmake did.
    for (engine_libs) |lib| {
        mod.addIncludePath(b.path(b.fmt("ZodEgine_Libs/{s}", .{lib.dir})));
    }

    for (export_macros) |m| mod.addCMacro(m, "1");
    mod.addCMacro("DISABLE_MYSQL", "1");
    // Lets the executables find assets/ from any directory (zdata_dir.h).
    mod.addCMacro("ZOD_DATA_DIR", b.fmt("\"{s}\"", .{b.pathFromRoot("bin")}));
    if (!use_opengl) mod.addCMacro("DISABLE_OPENGL", "1");
    if (use_opengl and os_tag == .macos) mod.addCMacro("GL_SILENCE_DEPRECATION", "1");

    for (sdl.include_dirs) |dir| mod.addSystemIncludePath(.{ .cwd_relative = dir });
    for (sdl.macros) |m| mod.addCMacro(m.name, m.value);
}

/// System libraries the executables link against (not the static library,
/// or they would end up inside the archive).
fn linkEngineLibraries(mod: *std.Build.Module, sdl: SdlFlags, use_opengl: bool, os_tag: std.Target.Os.Tag) void {
    for (sdl.lib_dirs) |dir| {
        mod.addLibraryPath(.{ .cwd_relative = dir });
        if (os_tag != .macos) mod.addRPath(.{ .cwd_relative = dir });
    }
    for (sdl.libs) |lib| mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    for (sdl.frameworks) |fw| mod.linkFramework(fw, .{});

    if (use_opengl) {
        if (os_tag == .macos) {
            mod.linkFramework("OpenGL", .{});
        } else {
            mod.linkSystemLibrary("GL", .{ .use_pkg_config = .no });
        }
    }
    if (os_tag == .macos) mod.linkFramework("Cocoa", .{});
    if (os_tag == .linux) mod.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
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
/// into build-system calls ourselves. (The sources include <SDL/SDL.h>, so
/// the parent of every include dir is needed too, and macOS link flags such
/// as -Wl,-framework,Cocoa need translating.)
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
    for ([_][]const u8{ "SDL_image", "SDL_mixer", "SDL_ttf" }) |name| {
        var code: u8 = undefined;
        _ = b.runAllowFail(&.{ "pkg-config", "--exists", name }, &code, .ignore) catch
            std.process.fatal("{s} (SDL 1.2 version) not found via pkg-config. Run ./macos/build_deps.sh first.", .{name});
    }

    const pkgs = [_][]const u8{ "SDL_image", "SDL_mixer", "SDL_ttf", sdl_pkg };
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
        // Anything else (-pthread, -Wl,-rpath,...) is handled elsewhere or not needed.
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
