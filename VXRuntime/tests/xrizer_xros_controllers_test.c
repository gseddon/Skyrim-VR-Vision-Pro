/* Mac check: controller observations -> input host version 3 samples (mapping, disconnection, NAN, ids, test script). */
#include <assert.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <openxr/openxr.h>
#include "input_host.h"
#include "xrizer_xros_controllers.h"
void vx_log(const char *f, ...) { va_list a; va_start(a, f); fputs("  log: ", stdout); vprintf(f, a); putchar('\n'); va_end(a); }
static vx_xros_controller_hand rest(int right) {
    vx_xros_controller_hand h; memset(&h, 0, sizeof h);
    h.connected = 1; h.grip_position_tracked = 1; h.aim_position_tracked = 0;
    float g[7] = {right ? .2f : -.2f, 1, -.3f, 0, 0, 0, 1}; memcpy(h.grip, g, sizeof g); memcpy(h.aim, g, sizeof g); h.aim[2] = -.4f;
    h.trigger = NAN; h.stick_x = h.stick_y = NAN;
    return h;
}
int main(int argc, char **argv) {
    KlNativeInputSample3 s, t;
    if (argc > 1) {   /* script mode: VXRT_XROS_TEST_HANDS comes from the environment */
        int rc = vx_xros_controllers_test_script();
        if (!strcmp(argv[1], "bad")) { assert(rc == -1); assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS); assert(!s.hand[0].controls.connected && !s.hand[1].controls.connected && !s.hand[0].profile); puts("controllers malformed script ok"); return 0; }
        assert(rc == 1);
        assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS);
        for (int i = 0; i < 2; i++) { assert(s.hand[i].controls.connected && s.hand[i].profile == KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH); assert(s.hand[i].controls.grip_position_tracked); }
        assert(s.hand[0].controls.trigger == 0 && !s.hand[1].controls.primary_pressed);
        usleep(150000);
        assert(vx_xros_controllers_sample(NULL, &t) == XR_SUCCESS);   /* 100 ms: right trigger and A, left stick */
        assert(t.sample_id > s.sample_id && t.sample_time > s.sample_time);
        assert(t.hand[1].controls.trigger == 1.f && t.hand[1].controls.primary_pressed && t.hand[0].controls.stick_x == .5f && t.hand[0].controls.stick_y == -.25f);
        assert(!t.hand[0].controls.primary_pressed);
        usleep(250000);
        assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS);   /* 300 ms: left disconnected */
        assert(!s.hand[0].controls.connected && s.hand[0].profile == 0 && isnan(s.hand[0].controls.trigger));
        assert(s.hand[0].local_from_grip.orientation.w == 0 && s.hand[0].local_from_aim.position.y == 0 && s.hand[1].controls.connected);
        assert(vx_xros_controllers_sample(NULL, &t) == XR_SUCCESS && t.sample_id == s.sample_id && t.sample_time == s.sample_time);
        puts("controllers script ok"); return 0;
    }
    /* before anything is published: explicit disconnected hands, repeats keep id and time */
    assert(vx_xros_controllers_test_script() == 0);
    assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS && s.sample_id == 1 && s.sample_time > 0);
    assert(!s.hand[0].controls.connected && !s.hand[1].controls.connected && isnan(s.hand[1].controls.stick_x));
    assert(vx_xros_controllers_sample(NULL, &t) == XR_SUCCESS && t.sample_id == 1 && t.sample_time == s.sample_time);
    /* connected right hand, tracked grip, untracked aim */
    vx_xros_controller_hand h[2]; h[0] = (vx_xros_controller_hand){0}; h[1] = rest(1);
    h[1].secondary = 1; h[1].stick_pressed = 1; h[1].trigger = .75f; h[1].stick_x = -1; h[1].stick_y = .5f;
    int64_t at = (int64_t)s.sample_time + 1000;
    vx_xros_controllers_publish(h, at);
    assert(vx_xros_controllers_sample(NULL, &t) == XR_SUCCESS && t.sample_id == 2 && t.sample_time == at);
    assert(!t.hand[0].controls.connected && t.hand[0].profile == 0 && isnan(t.hand[0].controls.trigger));
    const KlNativeInputHand3 *r = &t.hand[1];
    assert(r->controls.connected && r->profile == KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH && r->controls.grip_position_tracked && !r->controls.aim_position_tracked);
    assert(r->controls.trigger == .75f && r->controls.stick_x == -1 && r->controls.stick_y == .5f && r->controls.secondary_pressed && r->controls.stick_pressed && !r->controls.primary_pressed);
    assert(r->local_from_grip.position.x == .2f && r->local_from_aim.position.z == -.4f && r->local_from_grip.orientation.w == 1);
    /* same content again: same id; a time that does not advance still gives a later, ordered time on change */
    vx_xros_controllers_publish(h, at + 5000);
    assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS && s.sample_id == 2 && s.sample_time == at);
    h[1].trigger = 1.f; vx_xros_controllers_publish(h, at - 10);
    assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS && s.sample_id == 3 && s.sample_time == at + 1);
    /* out-of-range analog is not observed; a lone stick axis is dropped as a pair; an invalid pose disconnects */
    h[1].trigger = 2.f; h[1].stick_y = NAN; vx_xros_controllers_publish(h, at + 100);
    assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS && isnan(s.hand[1].controls.trigger) && isnan(s.hand[1].controls.stick_x) && isnan(s.hand[1].controls.stick_y));
    h[1].aim[3] = 2.f; vx_xros_controllers_publish(h, at + 200);
    assert(vx_xros_controllers_sample(NULL, &s) == XR_SUCCESS && !s.hand[1].controls.connected && !s.hand[1].profile);
    puts("controllers ok");
    return 0;
}
