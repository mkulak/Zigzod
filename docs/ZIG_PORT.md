# Porting Zod to Zig

An idiomatic Zig implementation of the Zod engine (server, client, bot and
map editor). It replaced the C++ code (`ZodEgine_Libs/`, `zod_engine/`,
`zod_map_editor/` and the Qt launcher), which was removed once the Zig
programs could do everything it did; it is in this repository's history.

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
* the C++ programs stayed buildable until the Zig ones reached parity, then
  they were deleted.

Data formats (maps, `.tileinfo`, settings files, assets) are unchanged.

## Layout

    src/main.zig          the `zod` program: play, server, client, bot, edit
    src/text.zig          text formatted into fixed buffers
    src/game.zig          game data and rules shared by all programs
      game/constants.zig  enums (teams, unit types, ...) - wire values
      game/settings.zig   unit stats / tunables, also the SET_SETTINGS message
      game/map.zig        .map format, tile properties, zones
      game/tiles.zig      tile positions and tile numbers
      game/clock.zig      the game clock (pause, speed)
      game/pathfinding.zig  passability grid, regions, A*
      game/buildlist.zig  what each factory can build per level
      game/object.zig     the object model: one struct, a tagged union for
                          per-kind data, references by ref id
      game/world.zig      objects, map, zones, missiles and the rules tying
                          them together; queues messages for clients
      game/sim.zig        the simulation step (orders, movement, combat,
                          production) and validation of players' orders
      game/unit_rating.zig  which units beat which
    src/net.zig           networking
      net/protocol.zig    message ids and packed payload structs
      net/conn.zig        non-blocking framed TCP connections
    src/server.zig        the game server
      server/server.zig   players, handshake, messages, votes, map rotation
      server/commands.zig chat commands (/help, /changemap, ...)
      server/bots.zig     the server's own bots
    src/bot.zig           the computer player
    src/editor.zig        the map editor
    src/client.zig        the game client
      client/session.zig  connection and game state kept in sync with the
                          server; reports what happened as events
      client/gfx.zig      images (plain ARGB buffers), drawing with clipping,
                          team colors
      client/assets.zig   the art, loaded once into one arena; missing
                          files become a placeholder (and are logged)
      client/display.zig  the window: the frame shown through an SDL texture
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
      client/portrait.zig the talking faces in the HUD
      client/portrait_frames.zon  their animation frames (data)
      client/sound.zig    sound effects, voices, music (SDL3 audio streams,
                          stb_vorbis)
      client/menus.zig    in-game menus (main, options, teams, bots,
                          players, maps, "are you sure")
      client/app.zig      window, main loop, camera

`zig build test` runs all unit tests (including a simulated battle and a
client talking to a server over a real socket). Tests that read game data
run from the repository root.

## Errors

* Running out of memory while changing game state (server, world, the
  client's selection and orders, news, the editor's map) is an error that
  goes up with `try` to the main loop, which reports it and stops.
* Visual effects are decoration: an effect that can't get memory is left
  out (effects.zig), and so is a rotated image the cache can't make.
* Text for the screen, chat and news is formatted into fixed buffers with
  `text.fit`, which cuts it to fit instead of dropping it.
* Missing art is replaced by a placeholder and logged (assets.zig); other
  files that can't be read (settings, sounds, music, maps) are logged and
  done without. The map editor reports failures in its status line.
* A cancelled sleep ends the loop it is in.

## Milestones

1. **Foundations** - constants, settings, map format, protocol, networking. Done.
2. **Server** - the game simulation (objects, pathfinding, combat, production,
   zones, votes, commands). Done; it was validated with the C++ client and
   bots playing on it.
3. **Client** - rendering, HUD, windows, menus, sound and music. Done. Not
   ported: the animals (birds, hut animals) and the crane's construction
   effect, which are decoration.
4. **Bot** and **map editor** - done: `zod bot` joins any server, and
   `zod server -b team` (or the Manage Bots menu) runs bots inside the
   server; `zod edit file.map` edits maps, `-n WxH` makes a new one.
5. **Remove the C++** - done: `zod` is the only program; `zod play` replaces
   the single player mode of `zod_engine` (a server with bots and a client
   in one loop). The transitional C-ABI ports of single C++ files are gone
   too; the SDL_gfx rotozoomer became `Image.rotozoom` (checked to give the
   same pixels).
6. **SDL 3** - done: the client and editor moved from SDL 1.2 (through
   sdl12-compat, with SDL_image and SDL_mixer) to SDL 3, built from source
   by `zig build` together with stb_vorbis, so building needs nothing but
   Zig. Images are loaded by SDL 3 (PNG, BMP) into plain pixel buffers;
   the frame is drawn in software as before and shown through a texture,
   scaled without smoothing on high density screens; sounds are SDL 3
   audio streams mixed by the device.

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
  blink on one clock (the C++ mixed real and game time);
* the "you're losing" warnings play (the C++ looked for comp_youre_losing_0.wav
  instead of comp_youre_losing_00.wav);
* menus: "Pause Game" also resumes; Escape closes the front menu or opens
  the main menu instead of quitting at once (Quit Game asks first); the
  dead "Multiplayer" button is gone; menus stay inside the window; the mouse
  wheel scrolls the list under the mouse only.
* the bot: a unit that found nothing to do no longer blocks the others from
  being paired with their targets; bots run inside the server instead of
  as separate processes; the two unused older AIs were not ported.
* the map editor: placing a gun no longer also places a robot (a missing
  `break`), howitzers and missile cannons are checked with their own size,
  a map picture saved with P is no longer blank where objects sit, a new
  zone is dragged out in any direction, a zone is removed by clicking
  anywhere in it (not only its top-left tile), one mouse stroke is undone
  at once, and what the mouse would place is drawn exactly as the game
  will show it;
* drawing images no longer goes through SDL's blit, which costs ~200 us a
  call on sdl12-compat: preparing a map's ground went from 1.2 s to 6 ms.
* the map editor saves its map picture as PNG (was a 5 MB BMP).
