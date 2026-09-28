# Zigzod

The Zod Engine in Zig: an open source remake of the 1996 real-time strategy
game Z by the Bitmap Brothers.

This is a rewrite of the Zod Engine (http://zod.sourceforge.net,
http://www.nighsoft.com; forum: http://zzone.lewe.com), which was written in
C++. The game, its rules, its network protocol and its data files (maps,
settings, art, sounds) are the same; docs/ZIG_PORT.md tells how the port was
done and where it deliberately differs from the original.

One program, `zod`, does everything:

    zod play      play on this computer (a server with bots, and you)
    zod server    run a game server
    zod client    join a server
    zod bot       add a computer player to a server
    zod edit      the map editor

`zod --help` lists their options.


## Building (macOS and Linux)

Requires Zig 0.16.0 or newer (https://ziglang.org/download/, or
`brew install zig`) and SDL 1.2 with SDL_image and SDL_mixer.

1. macOS: install the Xcode command line tools and Homebrew
   (https://brew.sh), then build the SDL add-ons once:

       xcode-select --install
       ./macos/build_deps.sh

   This installs sdl12-compat (SDL 1.2 running on SDL2, native on Apple
   Silicon) with Homebrew and builds SDL_image and SDL_mixer 1.2 into deps/.
   Linux: install the development packages of SDL 1.2, SDL_image 1.2 and
   SDL_mixer 1.2 (Debian/Ubuntu: libsdl1.2-dev libsdl-image1.2-dev
   libsdl-mixer1.2-dev), or run ./macos/build_deps.sh as well.

2. Build and play:

       zig build                  # -> zig-out/bin/zod
       zig build run              # the campaign as red against a blue bot
       zig build run -- play -m ../Data/Campaing/Z_original/p02_bb_orig01.map -r 1024x768
       zig build run -- edit my.map -n 64x64 -P desert -N "My map"
       zig build test             # unit tests

   ./macos/run_zod.sh [command options] does the same as `zig build run`.

The game data lives in bin/; map and settings paths given to `zod play` and
`zod server` are relative to it (-D picks another folder).

Build options: -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall
(default ReleaseFast), -Ddeps-prefix=/path (default deps/install). SDL is
found through pkg-config (including Homebrew's on macOS), so only native
builds are supported.

Some sound files the game refers to (for example
assets/sounds/explosion_*.wav) are not in this repository; the game says it
could not load them and plays without them.


## Playing over a network

    zod server -l map_list.txt -b blue        # on one computer
    zod client -c <server address> -t red     # on each player's computer

Players can change teams, start and stop bots, pick maps, change the game
speed and pause from the in-game menu (Escape or the Menu button); some
changes are put to a vote (F1 yes, F2 no, F3 pass). Chat with Enter; chat
commands start with / (/help lists them).
