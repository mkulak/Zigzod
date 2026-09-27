# Qt_ZodEngine
Old game Z, Z95, Z-Expansion Kit - new engine

This is an ZodEngine revision.
The original is located here:
http://zod.sourceforge.net  http://www.nighsoft.com

" Welcome to the Zod Engine project. The Zod Engine is an open source remake of the 1996 game Z by the Bitmap Brothers written in C++ using the SDL library for Linux / Windows / Etc."

A forum for the discussion here http://zzone.lewe.com. 
A branch for open source here http://zzone.lewe.com/forum/viewforum.php?f=5

This option is divided into dynamic libraries. Project files for IDE QtCreator (qmake build system).
Building with Ubuntu LTS 18.04.1.

Before running the binaries, remember to add the path to the libraries to the environment variable:
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/your/custom/path_to_folder_bin_ZodEngine/lib


=== Building (Zig toolchain; macOS Apple Silicon/Intel and Linux) ======

This branch is being ported from C++ to Zig one module at a time. The ported
modules live in src/*.zig; the rest is still the original C++ in
ZodEgine_Libs/, zod_engine/ and zod_map_editor/. Everything is built with
build.zig; the old qmake project files no longer work here, because the C++
code now calls functions that are implemented in Zig.

Requires Zig 0.16.0 or newer (https://ziglang.org/download/, or: brew install zig).
It does not need Qt, wxWidgets or MySQL.

1. macOS only: install the Xcode command line tools and Homebrew (https://brew.sh):
       xcode-select --install

2. Build the SDL 1.2 dependencies once (installs the Homebrew packages it
   needs and builds SDL_image / SDL_mixer / SDL_ttf 1.2 into deps/):
       ./macos/build_deps.sh

3. Build and play:
       zig build                  # -> zig-out/bin/zod_engine, zig-out/bin/zod_map_editor
       zig build run              # campaign in an 800x600 window, you = red vs blue bot
       zig build run -- -h        # all game options (anything after -- replaces the defaults)
       zig build run -- -l map_list.txt -t red -b blue -w -o     # e.g. without OpenGL
       zig build run-editor -- -f blank_maps/level_blank_01.map
       zig build test             # unit tests of the Zig modules

   ./macos/run_zod.sh [--editor] [options] runs the built programs the same way.

   The game data lives in bin/, and relative map paths are relative to bin/.
   The programs in zig-out/bin/ can also be started from any directory; they
   switch to bin/ themselves when assets/ isn't in the current directory.

Build options: -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall (default
ReleaseFast), -Dopengl=false, -Ddeps-prefix=/path (default deps/install).
SDL is found through pkg-config (including Homebrew on macOS), so only native
builds are supported, not cross-compilation.

Notes:
* SDL 1.2 comes from Homebrew's "sdl12-compat", which runs on SDL2 and
  builds natively for arm64.
* Homebrew no longer ships the SDL 1.2 versions of SDL_image, SDL_mixer and
  SDL_ttf, so macos/build_deps.sh builds them from the maintained SDL-1.2
  branches at github.com/libsdl-org. Delete deps/ to rebuild them.
* On Linux, install the -dev packages for SDL 1.2, libpng, libjpeg,
  freetype, libvorbis and mpg123 first.
* Some sound files the code refers to (for example assets/sounds/explosion_*.wav)
  are not in this repository. The game prints "could not load" for them and runs without them.


=== for linux systems ======
" Installing the required libraries -
The required libraries for this game are as follows...
* SDL
* SDL_ttf
* SDL_mixer
* SDL_image
* libmysqlclient (or sometimes called libmysql)
* wx (sometimes called libwx, or libwxgtk)
Notes: It is possible to compile the game without mysql support. 
Also wx is only needed for the zod_launcher.

Installing the required libraries on Ubuntu:
sudo apt-get install libsdl-dev libsdl-ttf2.0-dev libsdl-mixer1.2-dev 
libsdl-image1.2-dev libmysqlclient-dev libwxgtk2.8-dev "



