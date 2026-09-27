# CMake build for the Zod Engine (SDL 1.2 game, map editor).
#
# This is an alternative to the qmake project (Q_ZodEngine.pro) that does not
# need Qt, wxWidgets or MySQL, and works on macOS (Apple Silicon) and Linux.
# See README.md -> "Building on macOS" for usage.

cmake_minimum_required(VERSION 3.16)
project(ZodEngine CXX C)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

option(ZOD_USE_OPENGL "Build with OpenGL rendering support" ON)
option(ZOD_BUILD_MAP_EDITOR "Build the zod_map_editor executable" ON)

# The engine loads its assets relative to the working directory, so the
# executables must be started from bin/ (see run_zod.sh). They are kept in the
# build directory so the prebuilt Linux binaries in bin/ are not overwritten.
set(ZOD_OUTPUT_DIR "${CMAKE_BINARY_DIR}" CACHE PATH
    "Directory where zod_engine / zod_map_editor are placed")

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------
find_package(PkgConfig REQUIRED)
# sdl12-compat installs "sdl12_compat.pc"; classic SDL 1.2 installs "sdl.pc".
pkg_search_module(SDL REQUIRED IMPORTED_TARGET sdl12_compat sdl)
pkg_check_modules(SDL_IMAGE REQUIRED IMPORTED_TARGET SDL_image)
pkg_check_modules(SDL_MIXER REQUIRED IMPORTED_TARGET SDL_mixer)
pkg_check_modules(SDL_TTF   REQUIRED IMPORTED_TARGET SDL_ttf)
find_package(Threads REQUIRED)

if(ZOD_USE_OPENGL)
  if(APPLE)
    set(GL_SILENCE_DEPRECATION ON)
  endif()
  find_package(OpenGL REQUIRED)
endif()

# The sources include SDL headers as <SDL/SDL.h>, while pkg-config points at
# .../include/SDL. Add the parent directories as well.
set(ZOD_SDL_PARENT_INCLUDES "")
foreach(dir IN LISTS SDL_INCLUDE_DIRS SDL_IMAGE_INCLUDE_DIRS SDL_MIXER_INCLUDE_DIRS SDL_TTF_INCLUDE_DIRS)
  get_filename_component(parent "${dir}" DIRECTORY)
  list(APPEND ZOD_SDL_PARENT_INCLUDES "${parent}")
endforeach()
list(REMOVE_DUPLICATES ZOD_SDL_PARENT_INCLUDES)

# --------------------------------------------------------------------------
# Header layout: sources use <lib_qZod_DnXxx/header.h>, which qmake produced by
# copying headers into include/. Recreate that with symlinks in the build dir
# so the headers are always the ones from the source tree.
# --------------------------------------------------------------------------
set(ZOD_LIBS DnSeparate DnMap DnSoundEngine DnSettings DnGui DnEffect DnObjects DnClientServer)
set(ZOD_GEN_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/zod_include")
file(MAKE_DIRECTORY "${ZOD_GEN_INCLUDE}")
foreach(lib IN LISTS ZOD_LIBS)
  set(link "${ZOD_GEN_INCLUDE}/lib_qZod_${lib}")
  if(NOT EXISTS "${link}")
    file(CREATE_LINK "${CMAKE_CURRENT_SOURCE_DIR}/ZodEgine_Libs/QZod_${lib}" "${link}" SYMBOLIC)
  endif()
endforeach()

# --------------------------------------------------------------------------
# Engine sources (the eight "libraries" of the qmake build). They have
# circular references to each other, so they are compiled into a single
# object library and linked straight into each executable.
# --------------------------------------------------------------------------
set(L "${CMAKE_CURRENT_SOURCE_DIR}/ZodEgine_Libs")

set(SRC_DnSeparate
  qzod_dnseparate.cpp common.cpp event_handler.cpp SDL_rotozoom.cpp
  zencrypt_aes.cpp zfont.cpp zfont_engine.cpp zmysql.cpp zpsettings.cpp
  zsdl.cpp zsdl_opengl.cpp ztime.cpp)
set(SRC_DnMap
  qzod_dnmap.cpp qzod_map.cpp zmap_crater_graphics.cpp zteam.cpp
  finding/zpath_finding_old.cpp)
set(SRC_DnSoundEngine
  qzod_dnsoundengine.cpp qzod_soundengine_old.cpp zvote.cpp)
set(SRC_DnSettings
  qzod_dnsettings.cpp qzod_settings_old.cpp zbuildlist.cpp)
set(SRC_DnGui
  qzod_dngui.cpp gmm_change_teams.cpp gmm_main_menu.cpp gmm_manage_bots.cpp
  gmm_options.cpp gmm_player_list.cpp gmm_select_map.cpp gmm_warning.cpp
  zgui_main_menu_base.cpp zgui_main_menu_widgets.cpp gmmw_button.cpp
  gmmw_label.cpp gmmw_list.cpp gmmw_radio.cpp gmmw_team_color.cpp)
set(SRC_DnEffect
  qzod_dneffect.cpp ebridgeturrent.cpp ebullet.cpp ecannondeath.cpp
  ecraneconco.cpp edeath.cpp edeathsparks.cpp eflame.cpp elaser.cpp
  elightinitfire.cpp elightrocket.cpp emapobjectturrent.cpp
  emissilecrockets.cpp emomissilerockets.cpp epyrofire.cpp erobotdeath.cpp
  erobotturrent.cpp erockparticle.cpp erockturrent.cpp esideexplosion.cpp
  estandard.cpp etankdirt.cpp etankoil.cpp etanksmoke.cpp etankspark.cpp
  etoughmushroom.cpp etoughrocket.cpp etoughsmoke.cpp etrack.cpp
  eturrentmissile.cpp eunitparticle.cpp qzod_effect_old.cpp)
set(SRC_DnObjects
  qzod_dnobjects.cpp cursor.cpp oflag.cpp ogrenades.cpp ohut.cpp
  omapobject.cpp orock.cpp orockets.cpp zcomp_message_engine.cpp zgfile.cpp
  zgui_window.cpp zhud.cpp zmini_map.cpp zmusic_engine.cpp zobject.cpp
  zunitrating.cpp
  Animals/abird.cpp Animals/ahutanimal.cpp
  Buildings/bbridge.cpp Buildings/bfort.cpp Buildings/bradar.cpp
  Buildings/brepair.cpp Buildings/brobot.cpp Buildings/bvehicle.cpp
  Buildings/zbuilding.cpp
  Cannon/cgatling.cpp Cannon/cgun.cpp Cannon/chowitzer.cpp
  Cannon/cmissilecannon.cpp Cannon/zcannon.cpp
  Gw/gwcreateuser.cpp Gw/gwfactory_list.cpp Gw/gwlogin.cpp
  Gw/gwproduction.cpp Gw/gwproduction_fus.cpp Gw/gwproduction_us.cpp
  Robots/rgrunt.cpp Robots/rlaser.cpp Robots/rpsycho.cpp Robots/rpyro.cpp
  Robots/rsniper.cpp Robots/rtough.cpp Robots/zrobot.cpp
  Vehicles/vapc.cpp Vehicles/vcrane.cpp Vehicles/vheavy.cpp
  Vehicles/vjeep.cpp Vehicles/vlight.cpp Vehicles/vmedium.cpp
  Vehicles/vmissilelauncher.cpp Vehicles/zvehicle.cpp)
# Note: QZod_DnObjects/Buildings/zbuildlist.cpp is intentionally omitted; it is
# a duplicate of QZod_DnSettings/zbuildlist.cpp (same ZBuildList class).
set(SRC_DnClientServer
  qzod_dnclientserver.cpp client_socket.cpp server_socket.cpp
  socket_handler.cpp zbot.cpp zbot_events.cpp zclient.cpp zcore.cpp
  zplayer.cpp zplayer_events.cpp zserver.cpp zserver_commands.cpp
  zserver_events.cpp ztray.cpp)

set(ZOD_ENGINE_SOURCES "")
set(ZOD_ENGINE_INCLUDES "")
foreach(lib IN LISTS ZOD_LIBS)
  foreach(src IN LISTS SRC_${lib})
    list(APPEND ZOD_ENGINE_SOURCES "${L}/QZod_${lib}/${src}")
  endforeach()
  list(APPEND ZOD_ENGINE_INCLUDES "${L}/QZod_${lib}")
endforeach()

add_library(zod_core OBJECT ${ZOD_ENGINE_SOURCES})

target_include_directories(zod_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/qt_shim"
  "${ZOD_GEN_INCLUDE}"
  ${ZOD_SDL_PARENT_INCLUDES})
# Each engine directory is also on the include path for its own sources
# (qmake compiled every library from inside its own directory).
target_include_directories(zod_core PRIVATE ${ZOD_ENGINE_INCLUDES})

# Everything is linked statically into the executables, so the per-library
# export macros must not turn into dllimport or similar.
target_compile_definitions(zod_core PUBLIC
  DISABLE_MYSQL
  QZOD_DNSEPARATE_LIBRARY QZOD_DNMAP_LIBRARY QZOD_DNSOUNDENGINE_LIBRARY
  QZOD_DNSETTINGS_LIBRARY QZOD_DNGUI_LIBRARY QZOD_DNEFFECT_LIBRARY
  QZOD_DNOBJECTS_LIBRARY QZOD_DNCLIENTSERVER_LIBRARY)
if(NOT ZOD_USE_OPENGL)
  target_compile_definitions(zod_core PUBLIC DISABLE_OPENGL)
endif()
if(APPLE)
  target_compile_definitions(zod_core PUBLIC GL_SILENCE_DEPRECATION)
endif()

# The code base predates modern compilers; keep the build quiet and tolerant.
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(zod_core PUBLIC
    -w
    -fno-strict-aliasing
    $<$<COMPILE_LANGUAGE:CXX>:-Wno-c++11-narrowing>
    $<$<COMPILE_LANGUAGE:CXX>:-Wno-register>)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    target_compile_options(zod_core PUBLIC -Wno-error=c++11-narrowing)
  endif()
endif()

target_link_libraries(zod_core PUBLIC
  PkgConfig::SDL_IMAGE PkgConfig::SDL_MIXER PkgConfig::SDL_TTF PkgConfig::SDL
  Threads::Threads)
if(ZOD_USE_OPENGL)
  target_link_libraries(zod_core PUBLIC OpenGL::GL)
endif()

# --------------------------------------------------------------------------
# Executables
# --------------------------------------------------------------------------
add_executable(zod_engine
  zod_engine/main.cpp
  zod_engine/main_options.cpp)
target_link_libraries(zod_engine PRIVATE zod_core)
set_target_properties(zod_engine PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${ZOD_OUTPUT_DIR}")
foreach(cfg Debug Release RelWithDebInfo MinSizeRel)
  string(TOUPPER ${cfg} CFG)
  set_target_properties(zod_engine PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY_${CFG} "${ZOD_OUTPUT_DIR}")
endforeach()

if(ZOD_BUILD_MAP_EDITOR)
  add_executable(zod_map_editor zod_map_editor/main.cpp)
  target_link_libraries(zod_map_editor PRIVATE zod_core)
  set_target_properties(zod_map_editor PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${ZOD_OUTPUT_DIR}")
  foreach(cfg Debug Release RelWithDebInfo MinSizeRel)
    string(TOUPPER ${cfg} CFG)
    set_target_properties(zod_map_editor PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY_${CFG} "${ZOD_OUTPUT_DIR}")
  endforeach()
endif()
