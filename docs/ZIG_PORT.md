# Porting Zod to Zig

Goal: an idiomatic Zig implementation of the Zod engine (server, client, bot
and map editor) that replaces the C++ code in `ZodEgine_Libs/`,
`zod_engine/` and `zod_map_editor/`.

## Approach

The C++ engine is built around a deep `ZObject` class hierarchy (~150
virtual methods), `std::vector<ZObject*>` everywhere and global state.
Translating it class by class would force the Zig code to imitate C++ and
need a lot of glue. Instead the engine is **re-implemented in Zig, subsystem
by subsystem, with the C++ version as the reference**, and the two are kept
interoperable through the network protocol:

* even single player runs a server and clients that talk over TCP with a
  fixed binary protocol (`src/net/protocol.zig`);
* the Zig code keeps that protocol byte-compatible, so a Zig server can be
  tested with the C++ client and bots, a Zig client against a C++ server,
  and so on;
* the C++ programs stay buildable until the Zig ones reach parity, then
  they are deleted.

Data formats (maps, `.tileinfo`, settings files, assets) are unchanged.

## Layout

    src/game.zig          game data and rules shared by all programs
      game/constants.zig  enums (teams, unit types, ...) - wire values
      game/settings.zig   unit stats / tunables, also the SET_SETTINGS message
      game/map.zig        .map format, tile properties, zones
    src/net.zig           networking
      net/protocol.zig    message ids and packed payload structs
      net/conn.zig        non-blocking framed TCP connections

    src/root.zig          (transitional) Zig code linked into the C++ programs:
                          common, ztime, zencrypt_aes, sdl_rotozoom, zfont

`zig build test` runs all Zig unit tests. Tests that read game data run from
the repository root.

## Milestones

1. **Foundations** - constants, settings, map format, protocol, networking.
2. **Server** - the game simulation (objects, pathfinding, combat, production,
   zones, bots' server side, votes, commands). Validated by connecting the
   C++ client and C++ bots to the Zig server.
3. **Client** - rendering (SDL/OpenGL), HUD, menus, sound and music.
4. **Bot**, then **map editor**.
5. **Remove the C++** and the transitional C-ABI code in `src/root.zig`.

## Behaviour changes

Where the C++ code has bugs, the Zig code does the intended thing instead of
copying them (each one is noted in the commit that fixes it), e.g.:

* network sends buffer partial writes instead of dropping data;
* players are identified by stable ids, not by their position in a vector
  that shifts when someone disconnects;
* image scaling no longer reads outside images, and font rendering handles
  bytes above 127.
