/* See xrizer_xros_controllers.h. */
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <openxr/openxr.h>
#include "input_host.h"
#include "xrizer_xros_controllers.h"

void vx_log(const char *, ...);
#define MAX_EVENTS 64
typedef struct { int64_t ms; char text[96]; } script_event;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static KlNativeInputSample3 current;     /* what sample() returns; id 0 = nothing observed yet */
static uint64_t next_id;
static int64_t last_time;
static int script_state;                 /* 0 unread, 1 none, 2 active, 3 malformed */
static script_event events[MAX_EVENTS];
static unsigned event_count;
static int64_t script_start;

static int64_t now_ns(void) {
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return t > (uint64_t)INT64_MAX ? 0 : (int64_t)t;
}
static XrPosef pose_of(const float p[7]) {
    return (XrPosef){.orientation = {p[3], p[4], p[5], p[6]}, .position = {p[0], p[1], p[2]}};
}
static int valid_pose(const float p[7]) {
    float n = p[3] * p[3] + p[4] * p[4] + p[5] * p[5] + p[6] * p[6];
    for (int i = 0; i < 7; i++) if (!isfinite(p[i])) return 0;
    return fabsf(n - 1.f) < 0.01f;
}
static float analog(float v, float lo) { return isfinite(v) && v >= lo && v <= 1.f ? v : NAN; }
static KlNativeInputHand3 disconnected(void) {
    KlNativeInputHand3 out;
    memset(&out, 0, sizeof out);
    out.controls.trigger = out.controls.stick_x = out.controls.stick_y = NAN;
    return out;
}
static KlNativeInputHand3 convert(const vx_xros_controller_hand *in) {
    if (!in->connected || !valid_pose(in->grip) || !valid_pose(in->aim)) return disconnected();
    KlNativeInputHand3 out;
    memset(&out, 0, sizeof out);
    float sx = analog(in->stick_x, -1.f), sy = analog(in->stick_y, -1.f);
    int stick = !isnan(sx) && !isnan(sy);
    out.controls = (KlNativeInputHand2){.connected = XR_TRUE, .grip_position_tracked = in->grip_position_tracked ? XR_TRUE : XR_FALSE,
        .aim_position_tracked = in->aim_position_tracked ? XR_TRUE : XR_FALSE, .trigger = analog(in->trigger, 0.f),
        .stick_x = stick ? sx : NAN, .stick_y = stick ? sy : NAN,
        .primary_pressed = in->primary ? XR_TRUE : XR_FALSE, .secondary_pressed = in->secondary ? XR_TRUE : XR_FALSE,
        .grip_pressed = in->grip_pressed ? XR_TRUE : XR_FALSE, .menu_pressed = in->menu ? XR_TRUE : XR_FALSE,
        .stick_pressed = in->stick_pressed ? XR_TRUE : XR_FALSE};
    out.profile = KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH;
    out.local_from_grip = pose_of(in->grip); out.local_from_aim = pose_of(in->aim);
    return out;
}
static void log_hand(const KlNativeInputSample3 *s, int i) {
    const KlNativeInputHand3 *h = &s->hand[i];
    vx_log("xrizer xros controllers: sample %llu %s hand %s", (unsigned long long)s->sample_id, i ? "right" : "left",
           h->controls.connected ? (h->controls.grip_position_tracked ? "connected as oculus/touch_controller, position tracked"
                                                                       : "connected as oculus/touch_controller, position untracked")
                                 : "disconnected");
}
/* Bytewise comparison (NAN payloads are normalised by convert). */
static void store(const KlNativeInputHand3 hands[2], int64_t time_ns) {
    KlNativeInputSample3 next;
    memset(&next, 0, sizeof next);
    memcpy(next.hand, hands, sizeof next.hand);
    if (current.sample_id && !memcmp(current.hand, next.hand, sizeof next.hand)) return;
    if (time_ns <= last_time) time_ns = last_time + 1;
    last_time = time_ns;
    int was[2] = {current.hand[0].controls.connected != 0, current.hand[1].controls.connected != 0};
    int first = !current.sample_id;
    next.sample_id = ++next_id; next.sample_time = time_ns;
    current = next;
    for (int i = 0; i < 2; i++)
        if (first || was[i] != (next.hand[i].controls.connected != 0)) log_hand(&next, i);
}

void vx_xros_controllers_publish(const vx_xros_controller_hand hands[2], int64_t time_ns) {
    if (!hands || time_ns <= 0) return;
    KlNativeInputHand3 c[2] = {convert(&hands[0]), convert(&hands[1])};
    pthread_mutex_lock(&lock);
    if (script_state != 2) store(c, time_ns);
    pthread_mutex_unlock(&lock);
}

/* VXRT_XROS_TEST_HANDS: events "<ms>@<assignment> <assignment>..." separated by ';'. Both hands start connected, at rest,
 * in front of the origin (1.1 m up, +-0.2 m, 0.35 m ahead, position tracked); an event applies from that many ms after the
 * first sample. Assignment: <l|r|b>.<name>=<value>, name one of connected trigger stick (x,y) a b grip menu click
 * tracked; trigger/stick accept nan. "1" alone is the rest state. Test input, not tracking. */
static void rest_hand(vx_xros_controller_hand *h, int right) {
    memset(h, 0, sizeof *h);
    h->connected = 1; h->grip_position_tracked = h->aim_position_tracked = 1;
    float x = right ? .2f : -.2f;
    float g[7] = {x, 1.1f, -.35f, 0, 0, 0, 1}, a[7] = {x, 1.1f, -.4f, 0, 0, 0, 1};
    memcpy(h->grip, g, sizeof g); memcpy(h->aim, a, sizeof a);
}
static int apply(vx_xros_controller_hand *h, int right, const char *name, const char *value) {
    char *end;
    if (!strcmp(name, "connected")) { if (atoi(value)) rest_hand(h, right); else memset(h, 0, sizeof *h); return 0; }
    if (!strcmp(name, "stick")) {
        float x = strtof(value, &end); if (*end != ',') return -1;
        float y = strtof(end + 1, &end); if (*end) return -1;
        h->stick_x = x; h->stick_y = y; return 0;
    }
    float v = strtof(value, &end); if (*end || value == end) return -1;
    if (!strcmp(name, "trigger")) h->trigger = v;
    else if (!strcmp(name, "a")) h->primary = v != 0;
    else if (!strcmp(name, "b")) h->secondary = v != 0;
    else if (!strcmp(name, "grip")) h->grip_pressed = v != 0;
    else if (!strcmp(name, "menu")) h->menu = v != 0;
    else if (!strcmp(name, "click")) h->stick_pressed = v != 0;
    else if (!strcmp(name, "tracked")) h->grip_position_tracked = h->aim_position_tracked = v != 0;
    else return -1;
    return 0;
}
/* Applies one event's assignments; with out == NULL only validates. */
static int run_event(const script_event *e, vx_xros_controller_hand out[2]) {
    char text[sizeof e->text], *save = NULL;
    memcpy(text, e->text, sizeof text);
    for (char *tok = strtok_r(text, " ", &save); tok; tok = strtok_r(NULL, " ", &save)) {
        char *eq = strchr(tok, '='), *dot = strchr(tok, '.');
        if (!eq || !dot || dot != tok + 1 || dot > eq) return -1;
        int sides = tok[0] == 'l' ? 1 : tok[0] == 'r' ? 2 : tok[0] == 'b' ? 3 : 0;
        if (!sides) return -1;
        *eq = 0;
        for (int i = 0; i < 2; i++) {
            if (!(sides & (1 << i))) continue;
            vx_xros_controller_hand scratch, *h = out ? &out[i] : &scratch;
            if (!out) rest_hand(&scratch, i);
            if (apply(h, i, dot + 1, eq + 1)) return -1;
        }
    }
    return 0;
}
static int parse_script(const char *s) {
    event_count = 0;
    if (!strcmp(s, "1")) return 0;
    char *copy = strdup(s), *save = NULL;
    if (!copy) return -1;
    int rc = 0;
    for (char *ev = strtok_r(copy, ";", &save); ev && !rc; ev = strtok_r(NULL, ";", &save)) {
        char *at = strchr(ev, '@');
        if (!at || event_count == MAX_EVENTS || strlen(at + 1) >= sizeof events[0].text) { rc = -1; break; }
        *at = 0;
        char *end; long long ms = strtoll(ev, &end, 10);
        if (*end || end == ev || ms < 0 || (event_count && ms < events[event_count - 1].ms)) { rc = -1; break; }
        events[event_count].ms = ms; snprintf(events[event_count].text, sizeof events[event_count].text, "%s", at + 1);
        if (run_event(&events[event_count], NULL)) { rc = -1; break; }
        event_count++;
    }
    free(copy);
    return rc;
}
static void script_at(int64_t elapsed_ms, vx_xros_controller_hand out[2]) {
    rest_hand(&out[0], 0); rest_hand(&out[1], 1);
    for (unsigned e = 0; e < event_count && events[e].ms <= elapsed_ms; e++) (void)run_event(&events[e], out);
}
static void script_init_locked(void) {
    if (script_state) return;
    vx_log("xrizer xros controllers: input host version 3; haptics: the provider has no haptic host boundary, xrApplyHapticFeedback refuses (not wired)");
    const char *s = getenv("VXRT_XROS_TEST_HANDS");
    if (!s || !*s) { script_state = 1; return; }
    if (parse_script(s)) {
        script_state = 3;
        vx_log("xrizer xros controllers: VXRT_XROS_TEST_HANDS=%s is malformed (expected \"<ms>@<l|r|b>.<name>=<value> ...;...\"); hands stay disconnected", s);
        return;
    }
    script_state = 2;
    vx_log("xrizer xros controllers: VXRT_XROS_TEST_HANDS script active (%u events): synthetic stationary Oculus Touch controllers, test input, not physical tracking", event_count);
}
int vx_xros_controllers_test_script(void) {
    pthread_mutex_lock(&lock); script_init_locked(); int s = script_state; pthread_mutex_unlock(&lock);
    return s == 3 ? -1 : s == 2;
}

XrResult vx_xros_controllers_sample(void *context, KlNativeInputSample3 *out) {
    (void)context;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    pthread_mutex_lock(&lock);
    script_init_locked();
    int64_t t = now_ns();
    if (t <= 0) { pthread_mutex_unlock(&lock); return XR_ERROR_RUNTIME_FAILURE; }
    if (script_state == 2) {
        if (!script_start) script_start = t;
        vx_xros_controller_hand hands[2];
        script_at((t - script_start) / 1000000, hands);
        KlNativeInputHand3 c[2] = {convert(&hands[0]), convert(&hands[1])};
        store(c, t);
    } else if (!current.sample_id) {
        KlNativeInputHand3 none[2] = {disconnected(), disconnected()};   /* nothing published yet */
        store(none, t);
    }
    *out = current;
    pthread_mutex_unlock(&lock);
    return XR_SUCCESS;
}
