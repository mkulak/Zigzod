#!/usr/bin/env bash
#
# One-step build for macOS (Apple Silicon or Intel); it also works on Linux.
#   1. installs/builds the SDL 1.2 dependencies (macos/build_deps.sh)
#   2. configures and builds zod_engine + zod_map_editor with CMake into build/
#
# Extra arguments are passed to CMake, e.g.  ./macos/build.sh -DZOD_USE_OPENGL=OFF
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${ZOD_DEPS_PREFIX:-$ROOT/deps/install}"
BUILD_DIR="${ZOD_BUILD_DIR:-$ROOT/build}"
JOBS="$( (sysctl -n hw.ncpu || nproc) 2>/dev/null || echo 4)"

"$ROOT/macos/build_deps.sh"

PREFIX_PATH="$PREFIX"
if [[ "$(uname -s)" == "Darwin" ]]; then
  BREW_PREFIX="$(brew --prefix)"
  export PATH="$BREW_PREFIX/bin:$PATH"
  PREFIX_PATH="$PREFIX;$BREW_PREFIX"
fi
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

cmake -S "$ROOT" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH="$PREFIX_PATH" \
  "$@"
cmake --build "$BUILD_DIR" -j"$JOBS"

echo
echo "Build finished. Start the game with:  ./macos/run_zod.sh"
