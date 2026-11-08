/* Clock conversion helpers for the native Apple XR host. */
#ifndef VX_XRIZER_APPLE_TRACKING_H
#define VX_XRIZER_APPLE_TRACKING_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Mach absolute ticks and CompositorServices/ARKit absolute seconds share the
 * Mach absolute epoch (XROS26.1 SDK cp_types.h and accessory_tracking.h).
 * Return 0 on success, -1 for invalid input or overflow; leave *out unchanged
 * on failure. Times are positive, signed nanoseconds for the OpenXR boundary. */
int vx_xr_mach_ticks_to_ns(uint64_t ticks, uint32_t numer, uint32_t denom, int64_t *out);
int vx_xr_mach_seconds_to_ns(double seconds, int64_t *out);
#ifdef __cplusplus
}
#endif
#endif
