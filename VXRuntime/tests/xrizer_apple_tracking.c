#include "xrizer_apple_tracking.h"
#include <assert.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif
int main(void) {
    int64_t value = 123;
    assert(vx_xr_mach_ticks_to_ns(100, 125, 3, &value) == 0 && value == 4166);
    assert(vx_xr_mach_ticks_to_ns(UINT64_MAX, UINT32_MAX, 1, &value) == -1 && value == 4166);
    assert(vx_xr_mach_ticks_to_ns(1, 1, 0, &value) == -1 && value == 4166);
    assert(vx_xr_mach_ticks_to_ns(0, 1, 1, &value) == -1 && value == 4166);
    assert(vx_xr_mach_seconds_to_ns(2.5, &value) == 0 && value == 2500000000LL);
    assert(vx_xr_mach_seconds_to_ns(INFINITY, &value) == -1 && value == 2500000000LL);
    assert(vx_xr_mach_seconds_to_ns(NAN, &value) == -1 && value == 2500000000LL);
    assert(vx_xr_mach_seconds_to_ns(0, &value) == -1 && value == 2500000000LL);
    assert(vx_xr_mach_seconds_to_ns(1e20, &value) == -1 && value == 2500000000LL);
    assert(vx_xr_mach_seconds_to_ns(0x1p63 / 1e9, &value) == -1 && value == 2500000000LL);
#ifdef __APPLE__
    mach_timebase_info_data_t timebase;
    assert(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.numer && timebase.denom);
    uint64_t tick = mach_absolute_time();
    int64_t exact, via_seconds;
    assert(vx_xr_mach_ticks_to_ns(tick, timebase.numer, timebase.denom, &exact) == 0);
    double seconds = (double)tick * (double)timebase.numer / (double)timebase.denom / 1e9;
    assert(vx_xr_mach_seconds_to_ns(seconds, &via_seconds) == 0);
    int64_t difference = exact > via_seconds ? exact - via_seconds : via_seconds - exact;
    assert(difference < 10000); /* double precision, not a separate clock calibration */
#endif
    puts("Apple XR clock arithmetic: pass; no clock epoch calibration or headset claim");
    return 0;
}
