#ifndef ZDATA_DIR_H
#define ZDATA_DIR_H

// The engine loads assets/ (and map lists, settings...) relative to the
// working directory, which must be the game's bin/ folder. The build (build.zig)
// defines ZOD_DATA_DIR as that folder, so the executables can be started from
// anywhere: if assets/ is not in the current directory, switch to ZOD_DATA_DIR.

#include <string>
#include <stdio.h>

#if defined(ZOD_DATA_DIR) && !defined(_WIN32)
#include <unistd.h>
#include <sys/stat.h>

static inline bool zod_dir_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

// Turn a path relative to the directory the user started us from into an
// absolute one, so it still points to the same file after the chdir.
static inline std::string zod_absolute_path(const std::string &path)
{
    if(path.empty() || path[0] == '/') return path;
    char cwd[4096];
    if(!getcwd(cwd, sizeof(cwd))) return path;
    return std::string(cwd) + "/" + path;
}

static inline void zod_enter_data_dir()
{
    if(zod_dir_exists("assets")) return;
    if(!zod_dir_exists(ZOD_DATA_DIR "/assets")) return;
    if(chdir(ZOD_DATA_DIR) == 0)
        printf("Using game data from %s\n", ZOD_DATA_DIR);
}
#else
static inline std::string zod_absolute_path(const std::string &path) { return path; }
static inline void zod_enter_data_dir() {}
#endif

#endif // ZDATA_DIR_H
