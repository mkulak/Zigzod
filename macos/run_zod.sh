#!/usr/bin/env bash
#
# Run zod (build it first with `zig build`). Without arguments it plays the
# campaign as red against a blue bot; otherwise the arguments are a zod
# command (see ./macos/run_zod.sh --help):
#
#   ./macos/run_zod.sh                                   # zod play
#   ./macos/run_zod.sh play -m ../Data/Campaing/Z_original/p02_bb_orig01.map -r 1024x768
#   ./macos/run_zod.sh edit ~/my.map -n 64x64 -P arctic -N my_map
#   ./macos/run_zod.sh server -l map_list.txt -b blue
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZOD="${ZOD_BUILD_DIR:-$ROOT/zig-out/bin}/zod"
if [[ ! -x "$ZOD" ]]; then
  echo "error: $ZOD not found. Run 'zig build' first." >&2
  exit 1
fi
[[ $# -eq 0 ]] && set -- play
exec "$ZOD" "$@"
