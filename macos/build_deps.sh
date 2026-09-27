#!/usr/bin/env bash
#
# Build the SDL 1.2 add-on libraries (SDL_image, SDL_mixer, SDL_ttf) that the
# Zod Engine needs. Homebrew still ships SDL 1.2 itself (as "sdl12-compat",
# which runs on top of SDL2), but its SDL 1.2 add-on formulae were removed. So
# this script builds them from the maintained SDL-1.2 branches on GitHub.
#
# The libraries are installed into deps/install (or $ZOD_DEPS_PREFIX).
# This is safe to run more than once. Delete deps/ to rebuild from scratch.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${ZOD_DEPS_PREFIX:-$ROOT/deps/install}"
SRC="$ROOT/deps/src"
JOBS="$( (sysctl -n hw.ncpu || nproc) 2>/dev/null || echo 4)"

mkdir -p "$PREFIX/lib/pkgconfig" "$SRC"

# --------------------------------------------------------------------------
# 1. System packages (macOS / Homebrew)
# --------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew is required. Install it from https://brew.sh first." >&2
    exit 1
  fi
  BREW_PKGS=(cmake pkg-config sdl12-compat libpng jpeg-turbo freetype libogg libvorbis mpg123)
  missing=()
  for p in "${BREW_PKGS[@]}"; do
    brew list --versions "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    echo "==> brew install ${missing[*]}"
    brew install "${missing[@]}"
  fi
  BREW_PREFIX="$(brew --prefix)"
  export PATH="$BREW_PREFIX/bin:$PATH"
  export CPPFLAGS="-I$BREW_PREFIX/include ${CPPFLAGS:-}"
  export LDFLAGS="-L$BREW_PREFIX/lib ${LDFLAGS:-}"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$BREW_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
else
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

if ! command -v sdl-config >/dev/null 2>&1; then
  echo "error: sdl-config not found. Install SDL 1.2 (macOS: brew install sdl12-compat)." >&2
  exit 1
fi

# sdl12-compat installs only "sdl12_compat.pc", but the add-on libraries'
# pkg-config files use "Requires: sdl". Add a small alias if needed.
if ! pkg-config --exists sdl; then
  echo "==> adding sdl.pc alias for sdl12_compat"
  cat > "$PREFIX/lib/pkgconfig/sdl.pc" <<EOF
Name: sdl
Description: Alias for sdl12_compat (SDL 1.2 API on top of SDL2)
Version: $(pkg-config --modversion sdl12_compat)
Requires: sdl12_compat
EOF
fi

# --------------------------------------------------------------------------
# 2. SDL_image / SDL_mixer / SDL_ttf (SDL 1.2 versions)
# --------------------------------------------------------------------------
build_lib() {
  local name="$1"; shift
  if pkg-config --exists "$name" && [[ -f "$PREFIX/lib/pkgconfig/$name.pc" ]]; then
    echo "==> $name already built ($(pkg-config --modversion "$name"))"
    return
  fi
  echo "==> building $name"
  if [[ ! -d "$SRC/$name" ]]; then
    git clone --depth 1 --branch SDL-1.2 "https://github.com/libsdl-org/$name.git" "$SRC/$name"
  fi
  (
    cd "$SRC/$name"
    ./configure --prefix="$PREFIX" --disable-dependency-tracking --disable-static "$@"
    make -j"$JOBS"
    make install
  )
}

# Load PNG/JPEG via libpng/libjpeg directly (linked, not dlopen'ed). This
# avoids the macOS ImageIO path, which handles paletted/alpha images
# differently from the other platforms.
build_lib SDL_image \
  --disable-imageio \
  --disable-png-shared --disable-jpg-shared \
  --disable-tif --disable-webp

# The game uses WAV sound effects plus OGG/MP3 music.
build_lib SDL_mixer \
  --disable-music-cmd \
  --disable-music-mod --disable-music-midi --disable-music-flac \
  --enable-music-ogg --disable-music-ogg-shared \
  --enable-music-mp3 --disable-music-mp3-shared \
  --disable-smpegtest

# SDL_ttf's configure looks for GNU libiconv's libiconv_open, which the
# iconv built into macOS doesn't provide, so its showfont demo fails to link
# (undefined _iconv_open). Link the system libiconv explicitly.
TTF_ARGS=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  TTF_ARGS+=(LIBS=-liconv)
fi
build_lib SDL_ttf ${TTF_ARGS[@]+"${TTF_ARGS[@]}"}

echo
echo "Dependencies installed into: $PREFIX"
