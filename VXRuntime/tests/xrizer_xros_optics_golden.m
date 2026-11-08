/* Owned golden for the injected simulator calibration. Near 0.1 m and far 100 m
 * are the game's GetProjectionMatrix arguments. The drawable depth range, far
 * 10000 m, is a separate compositor plane and is not this matrix. */
#include "xrizer_xros_optics.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int near(float got, float want) {
    float scale = fabsf(want) > 1.f ? fabsf(want) : 1.f;
    return fabsf(got - want) <= 1e-5f * scale;
}

/* OpenVR IVRSystem::GetProjectionMatrix for finite near/far, matching
 * xrizer system.rs. Raw tangents are left, right, up, down after the
 * provider's top/bottom exchange. */
static void openvr_projection(float left, float right, float up, float down, float near_z, float far_z, float m[4][4]) {
    float idx = 1.f / (right - left), idy = 1.f / (up - down), idz = 1.f / (far_z - near_z);
    float sx = right + left, sy = up + down;
    float rows[4][4] = {
        {2.f * idx, 0, sx * idx, 0},
        {0, 2.f * idy, sy * idy, 0},
        {0, 0, -far_z * idz, -far_z * near_z * idz},
        {0, 0, -1.f, 0},
    };
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) m[r][c] = rows[r][c];
}

int main(void) {
    float eyes[32] = {0}, tangents[8];
    for (int eye = 0; eye < 2; eye++) {
        for (int j = 0; j < 16; j += 5) eyes[eye * 16 + j] = 1.f;
        eyes[eye * 16 + 12] = eye == 0 ? -0.032f : 0.032f;
        for (int j = 0; j < 4; j++) tangents[eye * 4 + j] = (j & 1) ? 1.f : -1.f;
    }
    float orientation[2][4], position[2][3], fov[2][4];
    if (vx_xros_optics_from_tangents(eyes, tangents, orientation, position, fov)) return 1;
    const float quarter = atanf(1.f);
    for (int eye = 0; eye < 2; eye++) {
        if (!near(position[eye][0], eye ? 0.032f : -0.032f) || !near(position[eye][1], 0) || !near(position[eye][2], 0)) return 2;
        if (!near(orientation[eye][0], 0) || !near(orientation[eye][1], 0) || !near(orientation[eye][2], 0) || !near(orientation[eye][3], 1)) return 3;
        if (!near(fov[eye][0], -quarter) || !near(fov[eye][1], quarter) || !near(fov[eye][2], quarter) || !near(fov[eye][3], -quarter)) return 4;
    }
    float expect[4][4], got[4][4];
    openvr_projection(-1.f, 1.f, 1.f, -1.f, 0.1f, 100.f, expect);
    /* Published angles are already left, right, up, down. Their tangents are the raw OpenVR inputs. */
    openvr_projection(tanf(fov[0][0]), tanf(fov[0][1]), tanf(fov[0][2]), tanf(fov[0][3]), 0.1f, 100.f, got);
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) if (!near(got[r][c], expect[r][c])) return 5;
    if (!near(expect[0][0], 1.f) || !near(expect[1][1], 1.f) || !near(expect[3][2], -1.f)) return 6;
    if (!near(expect[2][2], -100.f / 99.9f) || !near(expect[2][3], -10.f / 99.9f)) return 7;
    if (fabsf(position[1][0] - position[0][0] - 0.064f) > 1e-6f) return 8;
    /* A one-metre origin shift is recentering. It is not an eye offset and not a tracked head. */
    float origin[16];
    vx_xros_pose_matrix(0, 0, 0, 1, 0, 1.f, 0, origin);
    if (!near(origin[0], 1) || !near(origin[5], 1) || !near(origin[10], 1) || !near(origin[15], 1)) return 10;
    if (!near(origin[12], 0) || !near(origin[13], 1.f) || !near(origin[14], 0)) return 11;
    if (!vx_xros_pose_is_current(10, 10, 1) || !vx_xros_pose_is_current(11, 10, 1) || !vx_xros_pose_is_current(9.9, 10, 1)) return 12;
    if (vx_xros_pose_is_current(11.2, 10, 1) || vx_xros_pose_is_current(9.8, 10, 1)) return 13;
    if (vx_xros_pose_is_current(10, 10, 0) || vx_xros_pose_is_current(NAN, 10, 1)) return 14;
    const char msg[] = "xrizer_xros_optics_golden: 64 mm separation, ±pi/4 fields, OpenVR near 0.1 far 100, 1 m origin, stale pose rejected -> ok\n";
    if (fwrite(msg, 1, sizeof msg - 1, stdout) != sizeof msg - 1) return 9;
    return 0;
}
