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

    src/main.zig          the `zod` program: `zod server`, `zod client`
    src/game.zig          game data and rules shared by all programs
      game/constants.zig  enums (teams, unit types, ...) - wire values
      game/settings.zig   unit stats / tunables, also the SET_SETTINGS message
      game/map.zig        .map format, tile properties, zones
      game/clock.zig      the game clock (pause, speed)
      game/pathfinding.zig  passability grid, regions, A*
      game/buildlist.zig  what each factory can build per level
      game/object.zig     the object model: one struct, a tagged union for
                          per-kind data, references by ref id
      game/world.zig      objects, map, zones, missiles and the rules tying
                          them together; queues messages for clients
      game/sim.zig        the simulation step (orders, movement, combat,
                          production) and validation of players' orders
    src/net.zig           networking
      net/protocol.zig    message ids and packed payload structs
      net/conn.zig        non-blocking framed TCP connections
    src/server.zig        the game server
      server/server.zig   players, handshake, messages, votes, map rotation
      server/commands.zig chat commands (/help, /changemap, ...)
      server/bots.zig     bots (C++ zod_engine processes for now)
    src/client.zig        the game client (work in progress)
      client/session.zig  connection and game state kept in sync with the
                          server; reports what happened as events
      client/gfx.zig      images, drawing with clipping, team colors
      client/terrain.zig  the ground, animated water, zone markers, craters
      client/sprites.zig  all object and effect images
      client/objects.zig  object animations and drawing (buildings, items)
      client/units.zig    cannon, vehicle and robot animations
      client/effects.zig  shots, explosions, debris, wrecks, fires, tracks
      client/font.zig     bitmap fonts
      client/hud.zig      side panel, bottom bar, buttons, minimap
      client/cursor.zig   mouse cursors
      client/control.zig  selecting units, control groups, giving orders
      client/windows.zig  production window, factory list
      client/messages.zig news and chat lines, computer messages, vote box
      client/app.zig      window, main loop, camera

    src/root.zig          (transitional) Zig code linked into the C++ programs:
                          common, ztime, zencrypt_aes, sdl_rotozoom, zfont

`zig build test` runs all Zig unit tests (including a simulated battle and a
client talking to a server over a real socket). Tests that read game data
run from the repository root.

## Milestones

1. **Foundations** - constants, settings, map format, protocol, networking. Done.
2. **Server** - the game simulation (objects, pathfinding, combat, production,
   zones, votes, commands). Done: `zod server` replaces the C++ dedicated
   server; the C++ client and C++ bots (`zod_engine -c host -b team`) play on
   it. The C++ server code is still built because `zod_engine` without `-c`
   starts one in-process.
3. **Client** - rendering (SDL/OpenGL), HUD, menus, sound and music.
   In progress: `zod client` connects, keeps the game in sync, draws the
   map, all objects with their animations and the effects, has the HUD and
   minimap, units can be selected and ordered, and production is run from
   the building windows and the factory list; news, computer messages and
   votes are shown. Missing: portraits, menus, sound.
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
* path finding runs synchronously instead of in threads (it is fast enough
  with a binary heap);
* without user accounts every player has one vote; the original, without its
  MySQL database, let any single player decide every vote;
* a DODGE waypoint sent by a client became an ATTACK order; dodge directions
  could be NaN; a destroyed back fort did not stop buildings in its zone from
  repairing themselves;
* new units get their factory's rally points before they are announced, so
  clients see the full route;
* rotated and scaled effect images are cached per angle and size; the C++
  cache was invalidated the wrong way round (rebuilt when nothing changed,
  kept stale when the angle or size did);
* the selection's abilities are recomputed from scratch (a crane leaving the
  selection left "can repair" set); the camera glides at the same speed
  whatever the frame rate; the HUD clock shows the game time; a gun being
  placed is dimmed where it can't go; news lines have the color the server
  gives them (the C++ client drew all of them white); computer messages
  blink on one clock (the C++ mixed real and game time).
