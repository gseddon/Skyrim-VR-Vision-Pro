#include "xrizer_xros_optics.h"
#import <simd/simd.h>
#include <string.h>

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
