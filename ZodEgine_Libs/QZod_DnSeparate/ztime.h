#ifndef ZTIME_H
#define ZTIME_H

//#include <string>
//#include <vector>
//#include <stdlib.h>
#include "qzod_dnseparate_global.h"
#include "common.h"
using namespace COMMON;
// =========================================================
// *********************************************************
// =========================================================
#include <cstddef>
#include <zod_zig.h>


// The game clock. Implemented in Zig (src/ztime.zig), which works on this
// object's memory directly: keep the fields in sync with `ZTime` there.
class QZOD_DNSEPARATESHARED_EXPORT ZTime
{
public:
    ZTime() { zod_ztime_init(this); }

    void UpdateTime() { zod_ztime_update(this); }
    void Pause() { zod_ztime_pause(this); }
    void Resume() { zod_ztime_resume(this); }
    inline bool IsPaused() { return paused; }
    void SetGameSpeed(double new_speed) { zod_ztime_set_game_speed(this, new_speed); }
    inline double GameSpeed() { return game_speed; }


    bool paused{};
    double game_speed{};
    double ztime{};
    double last_change_front_time{};
    double last_change_back_time{};
};

static_assert(sizeof(ZTime) == 40 && offsetof(ZTime, game_speed) == 8 &&
              offsetof(ZTime, last_change_back_time) == 32,
              "ZTime layout must match src/ztime.zig");

#endif // ZTIME_H
