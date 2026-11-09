/* Injected simulator optics shared by the fixture and the owned golden.
 * Column-major eye matrices and tangent tuples are the host drawable's units.
 * This does not observe an ARKit head or a two-view compositor drawable. */
#pragma once
#include <math.h>
#include <stdint.h>
/* orientation_xyzw[eye] is x,y,z,w. position[eye] is metres.
 * fov_angles[eye] is OpenXR order: left, right, up, down, radians. */
int vx_xros_optics_from_tangents(const float eyes[32], const float tangents[8],
    float orientation_xyzw[2][4], float position[2][3], float fov_angles[2][4]);
/* Column-major origin-from-head. A position here is a recentered origin, not an eye offset. */
static inline void vx_xros_pose_matrix(float ox, float oy, float oz, float ow, float px, float py, float pz, float m[16]) {
    float x = ox, y = oy, z = oz, w = ow;
    m[0] = 1 - 2 * y * y - 2 * z * z; m[1] = 2 * x * y + 2 * w * z; m[2] = 2 * x * z - 2 * w * y; m[3] = 0;
    m[4] = 2 * x * y - 2 * w * z; m[5] = 1 - 2 * x * x - 2 * z * z; m[6] = 2 * y * z + 2 * w * x; m[7] = 0;
    m[8] = 2 * x * z + 2 * w * y; m[9] = 2 * y * z - 2 * w * x; m[10] = 1 - 2 * x * x - 2 * y * y; m[11] = 0;
    m[12] = px; m[13] = py; m[14] = pz; m[15] = 1;
}
/* A sample stays current from 0.1 s in the future through 1 s in the past. */
static inline int vx_xros_pose_is_current(double display_time, double pose_time, int tracking_valid) {
    double age = display_time - pose_time;
    return tracking_valid && isfinite(age) && age >= -0.1 && age <= 1.0;
}
/* OpenXR location bits. Injected eyes and the identity head are valid positions.
 * They omit the tracked bits, so an identity head is not an ARKit tracking result. */
#define VX_XROS_INJECTED_HEAD_FLAGS (UINT64_C(0x1) | UINT64_C(0x2))
#define VX_XROS_TRACKED_HEAD_FLAGS (UINT64_C(0x4) | UINT64_C(0x8))
/* True when seconds is within slack of Mach absolute time (CLOCK_UPTIME_RAW).
 * Compositor and ARKit presentation use that clock. CLOCK_MONOTONIC includes
 * sleep and is a different epoch, so it must not become an XrTime. */
int vx_xros_host_time_is_current(double seconds, double slack_seconds);
/* Column-major origin-from-head. A null matrix is identity and untracked.
 * Tracked bits are set only when the caller observed a device anchor. */
int vx_xros_head_pose(const float head[16], int tracked, float orientation_xyzw[4], float position[3], uint64_t *flags);
