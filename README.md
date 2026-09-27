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


=== Building on macOS (Apple Silicon M1-M5 / Intel) ======

The CMake build (CMakeLists.txt) does not need Qt, wxWidgets or MySQL.
The qmake project is still there for Linux/QtCreator users.

1. Install the Xcode command line tools and Homebrew (https://brew.sh):
       xcode-select --install

2. Build (this installs the Homebrew packages it needs, builds SDL_image /
   SDL_mixer / SDL_ttf 1.2 into deps/, then builds the game into build/):
       ./macos/build.sh

3. Play:
       ./macos/run_zod.sh                 # original campaign, 800x600 window, you = red vs blue bot
       ./macos/run_zod.sh -o              # same, without OpenGL
       ./macos/run_zod.sh -h              # all command line options
       ./macos/run_zod.sh --editor -f blank_maps/level_blank_01.map   # map editor

   The game data lives in bin/. run_zod.sh starts the programs from there, so
   relative map paths are relative to bin/. You can also run build/zod_engine
   or build/zod_map_editor directly from any directory; they switch to bin/
   themselves when assets/ isn't in the current directory.

Notes:
* SDL 1.2 comes from Homebrew's "sdl12-compat", which runs on SDL2 and
  builds natively for arm64.
* Homebrew no longer ships the SDL 1.2 versions of SDL_image, SDL_mixer and
  SDL_ttf, so macos/build_deps.sh builds them from the maintained SDL-1.2
  branches at github.com/libsdl-org. Delete deps/ to rebuild them.
* The same scripts also work on Linux (install the -dev packages for
  SDL 1.2, libpng, libjpeg, freetype, libvorbis and mpg123 first).
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



