#include "native_vr.h"
#include <stdio.h>
#include <math.h>
#include <string.h>

static int failures, refs[8], retains, releases;
#define CHECK(x) do { if (!(x)) { printf("FAIL line %d: %s\n", __LINE__, #x); failures++; } } while (0)
static void retain(void *p) { refs[*(int *)p]++; retains++; }
static void release(void *p) { refs[*(int *)p]--; releases++; }
static vx_native_vr_eye image(int *token) {
    vx_native_vr_eye e = { token, 100, 100, 1, 1, VX_NATIVE_VR_COLOR_SRGB, 0, 0, 1, 1 }; return e;
}
int main(void) {
    int tokens[] = { 0, 1, 2, 3, 4, 5, 6, 7 };
    vx_native_vr *q = vx_native_vr_create(retain, release);
    vx_native_vr_pose pose = { .frame_id = 10, .pose_id = 20, .pose_time = 1.5, .tracking_valid = 1 };
    pose.origin_from_head[0] = 3; pose.head_from_eye[1][2] = 4; pose.frustum[1][3] = 5;
    vx_native_vr_handle a = 0, b = 0, c = 0; vx_native_vr_frame f, g;
    vx_native_vr_eye l = image(&tokens[0]), r = image(&tokens[1]), bad = r;
    CHECK(!vx_native_vr_create(NULL, release)); CHECK(!vx_native_vr_create(retain, NULL));
    CHECK(vx_native_vr_begin(q, NULL, &a)); CHECK(vx_native_vr_begin(q, &pose, NULL));
    vx_native_vr_pose invalid = pose; invalid.pose_time = NAN; CHECK(vx_native_vr_begin(q, &invalid, &a));
    invalid = pose; invalid.origin_from_head[0] = INFINITY; CHECK(vx_native_vr_begin(q, &invalid, &a));
    invalid = pose; invalid.head_from_eye[1][15] = NAN; CHECK(vx_native_vr_begin(q, &invalid, &a));
    invalid = pose; invalid.frustum[0][3] = NAN; CHECK(vx_native_vr_begin(q, &invalid, &a));
    CHECK(q && !vx_native_vr_begin(q, &pose, &a));
    CHECK(vx_native_vr_acquire(q, &f));
    CHECK(vx_native_vr_complete(q, a, 0));
    CHECK(vx_native_vr_submit(q, a, 0, 11, 20, &l));
    CHECK(vx_native_vr_submit(q, a, 0, 10, 21, &l));
    CHECK(vx_native_vr_submit(q, a, 2, 10, 20, &l)); CHECK(vx_native_vr_submit(q, a, 0, 10, 20, NULL));
    bad.width = 0; CHECK(vx_native_vr_submit(q, a, 0, 10, 20, &bad));
    bad = r; bad.sample_count = 0; CHECK(vx_native_vr_submit(q, a, 0, 10, 20, &bad));
    bad = r; bad.color_space = 0; CHECK(vx_native_vr_submit(q, a, 0, 10, 20, &bad));
    bad = r; bad.u_min = NAN; CHECK(vx_native_vr_submit(q, a, 0, 10, 20, &bad));
    bad = r; bad.u_max = 2; CHECK(vx_native_vr_submit(q, a, 0, 10, 20, &bad));
    CHECK(!vx_native_vr_submit(q, a, 0, 10, 20, &l));
    CHECK(vx_native_vr_submit(q, a, 0, 10, 20, &l));
    bad = r; bad.format = 2; CHECK(vx_native_vr_submit(q, a, 1, 10, 20, &bad));
    bad = r; bad.sample_count = 2; CHECK(vx_native_vr_submit(q, a, 1, 10, 20, &bad));
    bad = r; bad.color_space = VX_NATIVE_VR_COLOR_LINEAR; CHECK(vx_native_vr_submit(q, a, 1, 10, 20, &bad));
    CHECK(retains == 1 && releases == 0);
    CHECK(!vx_native_vr_submit(q, a, 1, 10, 20, &r));
    CHECK(!vx_native_vr_complete(q, a, 1)); CHECK(vx_native_vr_acquire(q, &f));
    CHECK(vx_native_vr_complete(q, a, 1)); CHECK(!vx_native_vr_complete(q, a, 0));
    CHECK(!vx_native_vr_acquire(q, &f));
    CHECK(f.handle == a && f.pose.pose_time == 1.5 && f.pose.tracking_valid == 1 && f.pose.origin_from_head[0] == 3 && f.pose.head_from_eye[1][2] == 4 && f.pose.frustum[1][3] == 5);
    CHECK(vx_native_vr_acquire(q, &g));
    uint64_t old_lease = f.lease;
    CHECK(!vx_native_vr_release(q, f.lease)); CHECK(!vx_native_vr_acquire(q, &f));
    CHECK(f.lease != old_lease && vx_native_vr_release(q, old_lease));
    pose.frame_id++; pose.pose_id++;
    CHECK(!vx_native_vr_begin(q, &pose, &b));
    l = image(&tokens[2]); r = image(&tokens[3]);
    CHECK(!vx_native_vr_submit(q, b, 0, 11, 21, &l)); CHECK(!vx_native_vr_submit(q, b, 1, 11, 21, &r));
    CHECK(!vx_native_vr_complete(q, b, 0));
    vx_native_vr_reset(q);
    CHECK(refs[0] == 1 && refs[1] == 1 && refs[2] == 1 && refs[3] == 1);
    CHECK(vx_native_vr_acquire(q, &g)); CHECK(vx_native_vr_destroy(q));
    CHECK(!vx_native_vr_begin(q, &pose, &c)); CHECK(c != a && c != b);
    CHECK(!vx_native_vr_release(q, f.lease)); CHECK(!refs[0] && !refs[1]);
    CHECK(!vx_native_vr_complete(q, b, 1)); CHECK(!refs[2] && !refs[3]);
    CHECK(vx_native_vr_complete(q, b, 1));
    l = image(&tokens[4]); r = image(&tokens[5]);
    CHECK(!vx_native_vr_submit(q, c, 0, 11, 21, &l)); CHECK(!vx_native_vr_submit(q, c, 1, 11, 21, &r));
    pose.frame_id++; pose.pose_id++; CHECK(!vx_native_vr_begin(q, &pose, &a));
    l = image(&tokens[6]); r = image(&tokens[7]);
    CHECK(!vx_native_vr_submit(q, a, 0, 12, 22, &l)); CHECK(!vx_native_vr_submit(q, a, 1, 12, 22, &r));
    CHECK(!vx_native_vr_complete(q, a, 1)); CHECK(!vx_native_vr_complete(q, a, 0));
    CHECK(!vx_native_vr_complete(q, c, 0)); CHECK(!vx_native_vr_complete(q, c, 1));
    CHECK(!refs[4] && !refs[5]); CHECK(!vx_native_vr_acquire(q, &g) && g.handle == a);
    CHECK(!vx_native_vr_release(q, g.lease)); CHECK(!vx_native_vr_destroy(q));
    // Hold an older pair while both newer slots are reused. Releasing the old lease
    // must not expose that pair again while the newest publication is being replaced.
    q = vx_native_vr_create(retain, release);
    vx_native_vr_handle h[5];
    l = image(&tokens[0]); r = image(&tokens[1]);
    for (int i = 0; i < 3; i++) {
        pose.frame_id = (uint64_t)(30 + i); pose.pose_id = (uint64_t)(40 + i);
        CHECK(!vx_native_vr_begin(q, &pose, &h[i]));
        CHECK(!vx_native_vr_submit(q, h[i], 0, pose.frame_id, pose.pose_id, &l));
        CHECK(!vx_native_vr_submit(q, h[i], 1, pose.frame_id, pose.pose_id, &r));
        CHECK(!vx_native_vr_complete(q, h[i], 0)); CHECK(!vx_native_vr_complete(q, h[i], 1));
        if (!i) CHECK(!vx_native_vr_acquire(q, &f));
    }
    pose.frame_id = 33; pose.pose_id = 43; CHECK(!vx_native_vr_begin(q, &pose, &h[3]));
    pose.frame_id = 34; pose.pose_id = 44; CHECK(!vx_native_vr_begin(q, &pose, &h[4]));
    CHECK(!vx_native_vr_release(q, f.lease)); CHECK(vx_native_vr_acquire(q, &g));
    vx_native_vr_reset(q); CHECK(vx_native_vr_acquire(q, &g));
    pose.frame_id = 35; pose.pose_id = 45; CHECK(!vx_native_vr_begin(q, &pose, &a));
    CHECK(vx_native_vr_acquire(q, &g));
    CHECK(!vx_native_vr_submit(q, a, 0, 35, 45, &l)); CHECK(!vx_native_vr_submit(q, a, 1, 35, 45, &r));
    CHECK(!vx_native_vr_complete(q, a, 0)); CHECK(!vx_native_vr_complete(q, a, 1));
    CHECK(!vx_native_vr_acquire(q, &g) && g.handle == a); CHECK(!vx_native_vr_release(q, g.lease));
    CHECK(!vx_native_vr_destroy(q));
    // A late cancellation cannot invalidate B, and A's resources survive GPU work.
    q = vx_native_vr_create(retain, release);
    l = image(&tokens[0]); r = image(&tokens[1]);
    pose.frame_id = 50; pose.pose_id = 60; CHECK(!vx_native_vr_begin(q, &pose, &a));
    CHECK(!vx_native_vr_submit(q, a, 0, 50, 60, &l)); CHECK(!vx_native_vr_submit(q, a, 1, 50, 60, &r));
    pose.frame_id = 51; pose.pose_id = 61; CHECK(!vx_native_vr_begin(q, &pose, &b));
    l = image(&tokens[2]); r = image(&tokens[3]);
    CHECK(!vx_native_vr_submit(q, b, 0, 51, 61, &l)); CHECK(!vx_native_vr_submit(q, b, 1, 51, 61, &r));
    CHECK(!vx_native_vr_complete(q, b, 0)); CHECK(!vx_native_vr_complete(q, b, 1));
    CHECK(!vx_native_vr_cancel(q, a)); CHECK(vx_native_vr_cancel(q, a));
    CHECK(refs[0] == 1 && refs[1] == 1);
    CHECK(!vx_native_vr_acquire(q, &f) && f.handle == b);
    CHECK(!vx_native_vr_complete(q, a, 1)); CHECK(refs[0] == 1 && refs[1] == 1);
    CHECK(!vx_native_vr_complete(q, a, 0)); CHECK(!refs[0] && !refs[1]);
    CHECK(vx_native_vr_complete(q, a, 0) && vx_native_vr_cancel(q, a));
    CHECK(!vx_native_vr_release(q, f.lease)); CHECK(!vx_native_vr_destroy(q));

    // Cancel a partial C while B completes; B still publishes. A cancelled
    // reader's reference also remains valid until the unique lease is released.
    q = vx_native_vr_create(retain, release);
    pose.frame_id = 52; pose.pose_id = 62; CHECK(!vx_native_vr_begin(q, &pose, &b));
    l = image(&tokens[2]); r = image(&tokens[3]);
    CHECK(!vx_native_vr_submit(q, b, 0, 52, 62, &l)); CHECK(!vx_native_vr_submit(q, b, 1, 52, 62, &r));
    CHECK(!vx_native_vr_complete(q, b, 0));
    pose.frame_id = 53; pose.pose_id = 63; CHECK(!vx_native_vr_begin(q, &pose, &c));
    l = image(&tokens[4]); CHECK(!vx_native_vr_submit(q, c, 0, 53, 63, &l));
    CHECK(!vx_native_vr_cancel(q, c)); CHECK(vx_native_vr_submit(q, c, 1, 53, 63, &r));
    CHECK(!vx_native_vr_complete(q, b, 1)); CHECK(!vx_native_vr_acquire(q, &f) && f.handle == b);
    CHECK(!vx_native_vr_cancel(q, b)); CHECK(refs[2] == 1 && refs[3] == 1);
    CHECK(vx_native_vr_acquire(q, &g)); CHECK(!vx_native_vr_release(q, f.lease));
    CHECK(!refs[2] && !refs[3]); CHECK(vx_native_vr_release(q, f.lease));
    CHECK(refs[4] == 1); CHECK(!vx_native_vr_complete(q, c, 0)); CHECK(!refs[4]);
    CHECK(vx_native_vr_cancel(q, c)); CHECK(!vx_native_vr_destroy(q));
    CHECK(retains == releases); for (int i = 0; i < 8; i++) CHECK(!refs[i]);
    if (failures) { printf("native_vr: %d failures\n", failures); return 1; }
    puts("native_vr: ok"); return 0;
}
