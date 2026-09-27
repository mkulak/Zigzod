#!/usr/bin/env bash
#
# Run the game. The engine loads assets/ and maps relative to the working
# directory, so it has to be started from bin/.
#
# Without arguments it starts the original campaign in an 800x600 window
# against a bot. Any arguments replace these defaults (see ./macos/run_zod.sh -h).
#
#   ./macos/run_zod.sh                      # campaign, windowed
#   ./macos/run_zod.sh -o                   # campaign without OpenGL
#   ./macos/run_zod.sh -m ../Data/.../x.map -b 2 -w -r 1024x768
#   EDITOR=1 ./macos/run_zod.sh -f blank_maps/level_blank_01.map   # map editor
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ZOD_BUILD_DIR:-$ROOT/build}"
EXE="zod_engine"
[[ -n "${EDITOR:-}" ]] && EXE="zod_map_editor"

if [[ ! -x "$BUILD_DIR/$EXE" ]]; then
  echo "error: $BUILD_DIR/$EXE not found. Run ./macos/build.sh first." >&2
  exit 1
fi

cd "$ROOT/bin"
if [[ $# -eq 0 && "$EXE" == "zod_engine" ]]; then
  set -- -l map_list.txt -t red -b blue -w -r 800x600
fi
exec "$BUILD_DIR/$EXE" "$@"
