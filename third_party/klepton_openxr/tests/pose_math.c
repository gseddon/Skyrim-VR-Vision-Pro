#include "../src/pose_math.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
static int near(float a, float b) { return fabsf(a-b) < 0.0001f; }
int main(void) {
    const float r = 0.7071067811865475f;
    XrPosef local_from_stage = { .orientation = {0, r, 0, r}, .position = {10, 2, 3} };
    XrPosef stage_from_head = { .orientation = {0, 0, 0, 1}, .position = {1, 1.5f, -2} };
    XrPosef local_from_head = kl_native_pose_compose(local_from_stage, stage_from_head);
    assert(kl_native_pose_valid(local_from_head));
    assert(near(local_from_head.position.x, 8) && near(local_from_head.position.y, 3.5f) && near(local_from_head.position.z, 2));
    XrPosef recovered = kl_native_pose_relative(local_from_stage, local_from_head);
    assert(near(recovered.position.x, 1) && near(recovered.position.y, 1.5f) && near(recovered.position.z, -2));
    assert(near(recovered.orientation.w, 1) && near(recovered.orientation.y, 0));
    XrPosef head_from_eye = { .orientation = {0, 0, 0, 1}, .position = {-0.032f, 0, 0} };
    XrPosef local_from_eye = kl_native_pose_compose(local_from_head, head_from_eye);
    XrPosef eye_in_head = kl_native_pose_relative(local_from_head, local_from_eye);
    assert(near(eye_in_head.position.x, -0.032f) && near(eye_in_head.position.y, 0) && near(eye_in_head.position.z, 0));
    XrPosef invalid = stage_from_head; invalid.orientation.w = 0;
    assert(!kl_native_pose_valid(invalid));
    invalid = stage_from_head; invalid.position.x = NAN;
    assert(!kl_native_pose_valid(invalid));
    puts("Klepton pose algebra owned fixture: pass; no tracking or headset");
}
