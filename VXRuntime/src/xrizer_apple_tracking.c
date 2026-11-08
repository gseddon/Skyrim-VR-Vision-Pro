#include "xrizer_apple_tracking.h"
#include <limits.h>
#include <math.h>
int vx_xr_mach_ticks_to_ns(uint64_t ticks, uint32_t numer, uint32_t denom, int64_t *out) {
    if (!out || !ticks || !numer || !denom) return -1;
    __uint128_t ns = (__uint128_t)ticks * numer / denom;
    if (!ns || ns > INT64_MAX) return -1;
    *out = (int64_t)ns;
    return 0;
}
int vx_xr_mach_seconds_to_ns(double seconds, int64_t *out) {
    if (!out || !isfinite(seconds) || seconds <= 0) return -1;
    long double ns = (long double)seconds * 1000000000.0L;
    /* INT64_MAX rounds to 2^63 where long double has double precision. */
    if (ns < 1 || ns >= 0x1p63L) return -1;
    *out = (int64_t)ns;
    return 0;
}
