#include "xrizer_xros_optics.h"
#import <simd/simd.h>
#include <string.h>
#include <time.h>

int vx_xros_host_time_is_current(double seconds, double slack_seconds) {
    if (!isfinite(seconds) || !isfinite(slack_seconds) || seconds <= 0 || slack_seconds < 0) return 0;
    uint64_t before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double low = (double)before * 1e-9 - slack_seconds;
    double high = (double)after * 1e-9 + slack_seconds;
    return seconds >= low && seconds <= high;
}

static int pose_from_matrix(const float *v, float orientation[4], float position[3]) {
    for (unsigned i = 0; i < 16; i++) if (!isfinite(v[i])) return -1;
    simd_float4x4 m;
    memcpy(&m, v, sizeof m);
    simd_quatf q = simd_quaternion(m);
    orientation[0] = q.vector.x;
    orientation[1] = q.vector.y;
    orientation[2] = q.vector.z;
    orientation[3] = q.vector.w;
    position[0] = v[12];
    position[1] = v[13];
    position[2] = v[14];
    return 0;
}

int vx_xros_optics_from_tangents(const float eyes[32], const float tangents[8],
    float orientation_xyzw[2][4], float position[2][3], float fov_angles[2][4]) {
    if (!eyes || !tangents || !orientation_xyzw || !position || !fov_angles) return -1;
    for (unsigned i = 0; i < 2; i++) {
        if (pose_from_matrix(eyes + 16 * i, orientation_xyzw[i], position[i])) return -1;
        const float *f = tangents + 4 * i;
        for (unsigned j = 0; j < 4; j++) if (!isfinite(f[j])) return -1;
        /* Tangent order is left, right, down, up. OpenXR up/down are negated
         * so a positive tangent is a positive angle away from the forward axis. */
        fov_angles[i][0] = atanf(f[0]);
        fov_angles[i][1] = atanf(f[1]);
        fov_angles[i][2] = atanf(-f[2]);
        fov_angles[i][3] = atanf(-f[3]);
    }
    return 0;
}

int vx_xros_head_pose(const float head[16], int tracked, float orientation_xyzw[4], float position[3], uint64_t *flags) {
    float identity[16] = {0};
    if (!orientation_xyzw || !position || !flags) return -1;
    for (int i = 0; i < 4; i++) identity[i * 5] = 1.f;
    if (pose_from_matrix(head ? head : identity, orientation_xyzw, position)) return -1;
    *flags = head && tracked ? (VX_XROS_INJECTED_HEAD_FLAGS | VX_XROS_TRACKED_HEAD_FLAGS) : VX_XROS_INJECTED_HEAD_FLAGS;
    return 0;
}
