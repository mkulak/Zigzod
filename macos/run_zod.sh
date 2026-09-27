#!/usr/bin/env bash
#
# Run the game (or, with --editor, the map editor).
#
# Without arguments it starts the original campaign in an 800x600 window
# against a bot. Any arguments replace these defaults (see ./macos/run_zod.sh -h).
# Map/list paths are relative to bin/, where the game data lives.
#
#   ./macos/run_zod.sh                      # campaign, windowed
#   ./macos/run_zod.sh -o                   # campaign without OpenGL
#   ./macos/run_zod.sh -m ../Data/Campaing/Z_original/p02_bb_orig01.map -t red -b blue -w
#   ./macos/run_zod.sh --editor -f blank_maps/level_blank_01.map
#   ./macos/run_zod.sh --editor -n -f ~/my.map -d 64x64 -p desert -m my_map
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ZOD_BUILD_DIR:-$ROOT/build}"
EXE="zod_engine"
if [[ "${1:-}" == "--editor" ]]; then
  EXE="zod_map_editor"
  shift
fi

if [[ ! -x "$BUILD_DIR/$EXE" ]]; then
  echo "error: $BUILD_DIR/$EXE not found. Run ./macos/build.sh first." >&2
  exit 1
fi

# The executables switch to bin/ on their own when started elsewhere, but
# starting from bin/ keeps relative -f/-m/-l paths pointing at the game data.
cd "$ROOT/bin"
if [[ $# -eq 0 && "$EXE" == "zod_engine" ]]; then
  set -- -l map_list.txt -t red -b blue -w -r 800x600
fi
exec "$BUILD_DIR/$EXE" "$@"
