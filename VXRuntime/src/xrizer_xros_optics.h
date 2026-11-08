/* Injected simulator optics shared by the fixture and the owned golden.
 * Column-major eye matrices and tangent tuples are the host drawable's units.
 * This does not observe an ARKit head or a two-view compositor drawable. */
#pragma once
#include <math.h>
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
