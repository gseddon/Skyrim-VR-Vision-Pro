/* Experimental Mac development host, never a physical tracking/presentation claim.
 *
 * Development keyboard controllers (VXRT_XRIZER_DEV_KEYBOARD), diagnostic input only:
 *   VXRT_XRIZER_DEV_KEYBOARD=1       a "dev keyboard" window mirrors the two eyes side by side; while it is the key
 *                                    window (click it) its keys drive the two synthetic controllers and a mouse drag
 *                                    in it turns the synthetic head (the controllers follow the head). Keys reach
 *                                    only this window: no global key hooks, no Accessibility permission.
 *   VXRT_XRIZER_DEV_KEYBOARD=script  no window; only VXRT_XRIZER_DEV_KEY_SCRIPT drives the keys (fixtures, harness).
 *   Either implies VXRT_XRIZER_DEV_CONTROLLERS=touch when that is unset. The Oculus Touch profile is the one whose
 *   xrizer legacy mapping covers every button Skyrim VR's Oculus columns use (controlmapvr.txt): through xrizer
 *   (src/input/profiles/oculus_touch.rs) trigger -> k_EButton_SteamVR_Trigger + rAxis[1].x, squeeze -> k_EButton_Grip
 *   + k_EButton_Axis2 + rAxis[2].x, X (left) / A (right) -> k_EButton_A, Y (left) / B (right) ->
 *   k_EButton_ApplicationMenu, thumbstick -> rAxis[0], thumbstick click -> k_EButton_Axis0.
 *
 * Default key map (Mac key positions, layout independent) and what Skyrim VR's Oculus columns bind them to:
 *   W A S D      left stick       move; menus: navigate              Left Shift  left stick click   sprint
 *   Q            left trigger     left hand attack/block/cast        R           left grip          ready/sheathe weapon; menus: cancel
 *   Tab          left X           tween (system) menu; journal       J           left Y             journal/wait; menus: tab left
 *   arrows       right stick      turn (look); menus: navigate       Right Shift right stick click  item zoom (inventory)
 *   Space        right trigger    right hand attack; menus: accept   E, Return   right A            activate; menus: accept
 *   F            right B          favorites; menus: tab right        Z, Backspace right grip        shout; menus: cancel
 *   [ ]          head turn left/right (90 deg/s)   Page Up/Down  head pitch   Home  head and aim reset
 *   , .  ; /     the hands' aim left/right/up/down relative to the head (90 deg/s)
 *   mouse drag   head turn/pitch (the hands follow the head)   right-button drag  the hands' aim relative to the head
 *   (menus are world-locked panels: aim the hands' pointer at an item, then trigger/A)
 * (left.menu, the Oculus left menu button, is accepted but xrizer's legacy mapping does not bind it.)
 * Skyrim VR's first-launch VR setup is skipped by the harness's seeded SkyrimPrefs.ini (tools/prefs_seed/611670);
 * without it: any button, A, then right stick right + A picks Right Hand, A, then a teleport playroom.
 *
 * VXRT_XRIZER_DEV_KEYMAP overrides it: entries "key=hand.control" separated by spaces, commas or newlines, replacing
 * the default for that key; "key=none" unbinds it; "clear" drops all defaults first; a value starting with '/' is a
 * file of such entries ('#' comments). hand.control: left|right . trigger|grip|primary|a|x|secondary|b|y|menu|
 * stick_click|stick_up|stick_down|stick_left|stick_right, or head . left|right|up|down|reset|aim_left|aim_right|aim_up|aim_down. Key names: a-z 0-9
 * space return enter tab backspace escape lshift rshift lctrl rctrl lalt ralt up down left right home end pageup
 * pagedown minus equal lbracket rbracket semicolon quote comma period slash backslash grave f1-f12.
 *
 * VXRT_XRIZER_DEV_KEY_SCRIPT="START:KEYS:HOLD[,...]" presses KEYS (names joined by '+') at START for HOLD; times are
 * seconds since the dev host started, or fN for frame N / N frames. Applied at frame waits; works with or without
 * the window. Every change of the synthetic controller sample is logged ("xrizer dev keyboard: sample ...").
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <time.h>
#include "vx.h"
#include "d3d11_capture.h"
#include "xrizer_dev_host.h"
#include "xrizer_openvr_exports.h"
#include "xrizer_guest_d3d.h"
#include "native_vr.h"
#include "klepton_native.h"
#include "view_host.h"
#include "session_host.h"
#include "frame_host.h"
#include "input_host.h"
#include "haptic_host.h"
#include "apple_metal_host.h"
#include "xrizer_eye_ring.h"
#ifdef VXRT_XRIZER_DEV_AUDIT
extern int vx_xrizer_dev_audit_observe(uint32_t variant);
#endif

@interface VXDevXRHost : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic) KlNativeMetalHost metal;
@property(nonatomic) XrizerMetalHost source;
@property(nonatomic) vx_native_vr *frames;
@property(nonatomic) void *library;
@property(nonatomic) KlNativeSessionEvent event;
@property(nonatomic) KlNativeFrameSample sample;
@property(nonatomic) XrTime inputTime;
@property(nonatomic) uint64_t nextFrame;
@property(nonatomic) XrTime deadline;   // when the next frame is due (one 90 Hz period after the previous one)
@property(nonatomic) unsigned width, height;
@property(nonatomic) BOOL outstanding;
@property(nonatomic) vx_eye_ring *ring;   /* NULL: VXRT_XR_SYNC_SUBMIT=1 (or the audit build's audit mode): blocking submit */
/* Opt-in development choice (VXRT_XRIZER_DEV_STAGE=1): declare the synthetic local origin to be the floor. */
@property(nonatomic) BOOL syntheticStage;
/* Opt-in diagnostic (VXRT_XRIZER_DEV_CONTROLLERS=1|touch|index|vive): two connected, stationary synthetic controllers
 * of that kind (KL_NATIVE_INPUT_PROFILE_*; 0 = off) through the provider's version-3 input host. Not physical input. */
@property(nonatomic) uint32_t syntheticControllers;
/* Opt-in diagnostic (VXRT_XRIZER_DEV_DUMP=<absolute dir>): write raw RGBA of the published eyes for a few frames. */
@property(nonatomic,copy) NSString *dumpDir;
#ifdef VXRT_XRIZER_DEV_AUDIT
@property(nonatomic) BOOL audit;
@property(nonatomic) unsigned published, acquired, released, begins, exits, ends;
@property(nonatomic) uint64_t auditFrame, auditPose;
#endif
@end
@implementation VXDevXRHost
@end
static VXDevXRHost *dev_host;
static XrTime now_ns(void) { struct timespec t; if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0; return (XrTime)t.tv_sec * INT64_C(1000000000) + t.tv_nsec; }
/* ---- development keyboard (see the header comment) ---------------------------------------------------------------- */
void vx_cocoa_ensure(void);
enum { DK_LEFT, DK_RIGHT, DK_HEAD };
enum { DK_NONE, DK_TRIGGER, DK_GRIP, DK_PRIMARY, DK_SECONDARY, DK_MENU, DK_STICK_CLICK, DK_STICK_UP, DK_STICK_DOWN,
       DK_STICK_LEFT, DK_STICK_RIGHT,
       DK_HEAD_LEFT = 1, DK_HEAD_RIGHT, DK_HEAD_UP, DK_HEAD_DOWN, DK_HEAD_RESET, DK_AIM_LEFT, DK_AIM_RIGHT, DK_AIM_UP, DK_AIM_DOWN };
typedef struct { uint8_t hand, control; } dk_binding;
static const struct { const char *name; uint8_t code; } dk_key_names[] = {   /* macOS virtual key codes (kVK_*) */
    {"a",0},{"s",1},{"d",2},{"f",3},{"h",4},{"g",5},{"z",6},{"x",7},{"c",8},{"v",9},{"b",11},{"q",12},{"w",13},{"e",14},
    {"r",15},{"y",16},{"t",17},{"1",18},{"2",19},{"3",20},{"4",21},{"6",22},{"5",23},{"equal",24},{"9",25},{"7",26},
    {"minus",27},{"8",28},{"0",29},{"rbracket",30},{"o",31},{"u",32},{"lbracket",33},{"i",34},{"p",35},{"return",36},
    {"enter",36},{"l",37},{"j",38},{"quote",39},{"k",40},{"semicolon",41},{"backslash",42},{"comma",43},{"slash",44},
    {"n",45},{"m",46},{"period",47},{"tab",48},{"space",49},{"grave",50},{"backspace",51},{"escape",53},{"lshift",56},
    {"lalt",58},{"lctrl",59},{"rshift",60},{"ralt",61},{"rctrl",62},{"f5",96},{"f6",97},{"f7",98},{"f3",99},{"f8",100},
    {"f9",101},{"f11",103},{"f10",109},{"f12",111},{"home",115},{"pageup",116},{"f4",118},{"end",119},{"f2",120},
    {"pagedown",121},{"f1",122},{"left",123},{"right",124},{"down",125},{"up",126}};
static const char *const dk_hand_names[] = {"left","right","head"};
static const struct { const char *name; uint8_t control; } dk_controls_named[] = {
    {"trigger",DK_TRIGGER},{"grip",DK_GRIP},{"primary",DK_PRIMARY},{"a",DK_PRIMARY},{"x",DK_PRIMARY},
    {"secondary",DK_SECONDARY},{"b",DK_SECONDARY},{"y",DK_SECONDARY},{"menu",DK_MENU},{"stick_click",DK_STICK_CLICK},
    {"stick_up",DK_STICK_UP},{"stick_down",DK_STICK_DOWN},{"stick_left",DK_STICK_LEFT},{"stick_right",DK_STICK_RIGHT}};
static const char *const dk_head_controls[] = {NULL,"left","right","up","down","reset","aim_left","aim_right","aim_up","aim_down"};
static const char dk_default_map[] =
    "w=left.stick_up a=left.stick_left s=left.stick_down d=left.stick_right lshift=left.stick_click q=left.trigger "
    "r=left.grip tab=left.x j=left.y up=right.stick_up down=right.stick_down left=right.stick_left "
    "right=right.stick_right rshift=right.stick_click space=right.trigger e=right.a return=right.a f=right.b "
    "z=right.grip backspace=right.grip lbracket=head.left rbracket=head.right pageup=head.up pagedown=head.down "
    "home=head.reset comma=head.aim_left period=head.aim_right semicolon=head.aim_up slash=head.aim_down";
typedef struct { int64_t at; uint8_t frames, code, down, done; } dk_event;   /* at: ns since start, or a frame */
static struct {
    int enabled, window;
    dk_binding map[128];
    _Atomic uint64_t keys[2], script_keys[2];         /* key codes 0..127 held in the window / by the script */
    _Atomic uint32_t yaw_bits, pitch_bits;            /* head angles (float bits, radians) */
    _Atomic int mirror;                               /* the window is on screen and its layer is ready */
    _Atomic int drag_dx_milli, drag_dy_milli;         /* unapplied mouse drag, thousandths of a point */
    _Atomic int aim_dx_milli, aim_dy_milli;           /* unapplied right-button drag (hands' aim) */
    _Atomic uint32_t aim_yaw_bits, aim_pitch_bits;    /* the hands' aim relative to the head (float bits, radians) */
    dk_event script[256]; unsigned script_count;
    XrTime start, last_head;
    pthread_mutex_t lock;                             /* the sample below */
    uint64_t sample_id; XrTime sample_time; KlNativeInputHand3 hands[2]; unsigned changes;
} dk = {.lock = PTHREAD_MUTEX_INITIALIZER};
static CAMetalLayer *dk_layer;                        /* set on the main thread before dk.mirror */
static id<MTLRenderPipelineState> dk_pipeline;
static NSWindow *dk_window;                           /* kept open through process exit */
static float dk_float(_Atomic uint32_t *v) { uint32_t b = atomic_load(v); float f; memcpy(&f, &b, 4); return f; }
static void dk_set_float(_Atomic uint32_t *v, float f) { uint32_t b; memcpy(&b, &f, 4); atomic_store(v, b); }
static int dk_key_code(const char *name, size_t n) {
    for (size_t i = 0; i < sizeof dk_key_names / sizeof dk_key_names[0]; i++)
        if (strlen(dk_key_names[i].name) == n && !strncasecmp(dk_key_names[i].name, name, n)) return dk_key_names[i].code;
    return -1;
}
static const char *dk_code_name(unsigned code) {
    for (size_t i = 0; i < sizeof dk_key_names / sizeof dk_key_names[0]; i++) if (dk_key_names[i].code == code) return dk_key_names[i].name;
    return "?";
}
/* One "key=hand.control" entry; 0 or -1 (logged). */
static int dk_entry(const char *e, size_t n) {
    const char *eq = memchr(e, '=', n);
    if (n == 5 && !strncasecmp(e, "clear", 5)) { memset(dk.map, 0, sizeof dk.map); return 0; }
    if (!eq) goto bad;
    int code = dk_key_code(e, (size_t)(eq - e)); if (code < 0) goto bad;
    const char *v = eq + 1; size_t vn = n - (size_t)(v - e);
    if (vn == 4 && !strncasecmp(v, "none", 4)) { dk.map[code] = (dk_binding){0}; return 0; }
    const char *dot = memchr(v, '.', vn); if (!dot) goto bad;
    size_t hn = (size_t)(dot - v), cn = vn - hn - 1; const char *c = dot + 1;
    for (unsigned hand = 0; hand < 3; hand++) {
        if (strlen(dk_hand_names[hand]) != hn || strncasecmp(dk_hand_names[hand], v, hn)) continue;
        if (hand == DK_HEAD) {
            for (unsigned k = 1; k < sizeof dk_head_controls / sizeof dk_head_controls[0]; k++)
                if (strlen(dk_head_controls[k]) == cn && !strncasecmp(dk_head_controls[k], c, cn)) { dk.map[code] = (dk_binding){(uint8_t)hand, (uint8_t)k}; return 0; }
        } else {
            for (size_t k = 0; k < sizeof dk_controls_named / sizeof dk_controls_named[0]; k++)
                if (strlen(dk_controls_named[k].name) == cn && !strncasecmp(dk_controls_named[k].name, c, cn)) {
                    dk.map[code] = (dk_binding){(uint8_t)hand, dk_controls_named[k].control}; return 0;
                }
        }
    }
bad:
    vx_log("xrizer dev keyboard: key map entry \"%.*s\" not understood (expected key=hand.control)", (int)n, e);
    return -1;
}
static int dk_parse_map(const char *s) {
    while (*s) {
        if (*s == '#') { while (*s && *s != '\n') s++; continue; }
        if (strchr(" \t\r\n,", *s)) { s++; continue; }
        size_t n = strcspn(s, " \t\r\n,#");
        if (dk_entry(s, n)) return -1;
        s += n;
    }
    return 0;
}
/* "START:KEYS:HOLD[,...]": times in seconds since the host started, or fN frames. */
static int dk_time(const char *s, size_t n, int64_t *at, uint8_t *frames) {
    char buf[32]; if (!n || n >= sizeof buf) return -1;
    memcpy(buf, s, n); buf[n] = 0; char *end;
    if (buf[0] == 'f') { long long f = strtoll(buf + 1, &end, 10); if (*end || end == buf + 1 || f < 0) return -1; *at = f; *frames = 1; return 0; }
    double t = strtod(buf, &end); if (*end || end == buf || !(t >= 0) || t > 1e6) return -1;
    *at = (int64_t)(t * 1e9); *frames = 0; return 0;
}
static int dk_parse_script(const char *s) {
    while (*s) {
        if (*s == ',' || *s == ' ') { s++; continue; }
        size_t n = strcspn(s, ", "); const char *c1 = memchr(s, ':', n), *c2 = c1 ? memchr(c1 + 1, ':', n - (size_t)(c1 + 1 - s)) : NULL;
        int64_t start, hold; uint8_t fs, fh;
        if (!c2 || dk_time(s, (size_t)(c1 - s), &start, &fs) || dk_time(c2 + 1, n - (size_t)(c2 + 1 - s), &hold, &fh) || fs != fh) goto bad;
        for (const char *k = c1 + 1; k < c2;) {
            size_t kn = strcspn(k, "+:"); if (k + kn > c2) kn = (size_t)(c2 - k);
            int code = dk_key_code(k, kn);
            if (code < 0 || dk.script_count + 2 > sizeof dk.script / sizeof dk.script[0]) goto bad;
            dk.script[dk.script_count++] = (dk_event){start, fs, (uint8_t)code, 1, 0};
            dk.script[dk.script_count++] = (dk_event){start + hold, fs, (uint8_t)code, 0, 0};
            k += kn; if (*k == '+') k++;
        }
        s += n; continue;
    bad:
        vx_log("xrizer dev keyboard: VXRT_XRIZER_DEV_KEY_SCRIPT entry \"%.*s\" not understood (expected START:KEY[+KEY]:HOLD, seconds or fN)", (int)n, s);
        return -1;
    }
    return 0;
}
static void dk_key(unsigned code, int down) {
    if (code >= 128) return;
    uint64_t bit = 1ull << (code & 63);
    if (down) atomic_fetch_or(&dk.keys[code >> 6], bit); else atomic_fetch_and(&dk.keys[code >> 6], ~bit);
}
static int dk_held(const uint64_t bits[2], unsigned hand, unsigned control) {
    for (unsigned code = 0; code < 128; code++)
        if ((bits[code >> 6] >> (code & 63) & 1) && dk.map[code].hand == hand && dk.map[code].control == control) return 1;
    return 0;
}
static void dk_bits(uint64_t bits[2]) {
    for (unsigned i = 0; i < 2; i++) bits[i] = atomic_load(&dk.keys[i]) | atomic_load(&dk.script_keys[i]);
}
/* At a frame wait: the script's due events, then the head (keys at 90 deg/s, mouse drag at 0.25 deg/point). */
static void dk_frame(uint64_t frame, XrTime now) {
    if (!dk.enabled) return;
    for (unsigned i = 0; i < dk.script_count; i++) {
        dk_event *e = &dk.script[i];
        if (e->done || (e->frames ? (uint64_t)e->at > frame : now - dk.start < e->at)) continue;
        e->done = 1; uint64_t bit = 1ull << (e->code & 63);
        if (e->down) atomic_fetch_or(&dk.script_keys[e->code >> 6], bit); else atomic_fetch_and(&dk.script_keys[e->code >> 6], ~bit);
        vx_log("xrizer dev keyboard: script %s %s at frame %llu (%.3f s)", e->down ? "press" : "release", dk_code_name(e->code),
               (unsigned long long)frame, (double)(now - dk.start) / 1e9);
    }
    uint64_t bits[2]; dk_bits(bits);
    float dt = dk.last_head ? (float)((double)(now - dk.last_head) / 1e9) : 0; dk.last_head = now;
    if (dt > .1f) dt = .1f;
    float yaw = dk_float(&dk.yaw_bits), pitch = dk_float(&dk.pitch_bits), rate = (float)M_PI / 2;
    yaw += rate * dt * (float)(dk_held(bits, DK_HEAD, DK_HEAD_LEFT) - dk_held(bits, DK_HEAD, DK_HEAD_RIGHT));
    pitch += rate * dt * (float)(dk_held(bits, DK_HEAD, DK_HEAD_UP) - dk_held(bits, DK_HEAD, DK_HEAD_DOWN));
    float per = .25f * (float)M_PI / 180 / 1000;
    yaw -= per * (float)atomic_exchange(&dk.drag_dx_milli, 0); pitch -= per * (float)atomic_exchange(&dk.drag_dy_milli, 0);
    float ayaw = dk_float(&dk.aim_yaw_bits) - per * (float)atomic_exchange(&dk.aim_dx_milli, 0) +
                 rate * dt * (float)(dk_held(bits, DK_HEAD, DK_AIM_LEFT) - dk_held(bits, DK_HEAD, DK_AIM_RIGHT));
    float apitch = dk_float(&dk.aim_pitch_bits) - per * (float)atomic_exchange(&dk.aim_dy_milli, 0) +
                 rate * dt * (float)(dk_held(bits, DK_HEAD, DK_AIM_UP) - dk_held(bits, DK_HEAD, DK_AIM_DOWN));
    if (dk_held(bits, DK_HEAD, DK_HEAD_RESET)) yaw = pitch = ayaw = apitch = 0;
    if (ayaw > 1.4f) ayaw = 1.4f; if (ayaw < -1.4f) ayaw = -1.4f; if (apitch > 1.4f) apitch = 1.4f; if (apitch < -1.4f) apitch = -1.4f;
    dk_set_float(&dk.aim_yaw_bits, ayaw); dk_set_float(&dk.aim_pitch_bits, apitch);
    yaw = remainderf(yaw, 2 * (float)M_PI);
    if (pitch > 1.4f) pitch = 1.4f; if (pitch < -1.4f) pitch = -1.4f;
    dk_set_float(&dk.yaw_bits, yaw); dk_set_float(&dk.pitch_bits, pitch);
}
static XrQuaternionf dk_yaw_pitch(float yaw, float pitch) {   /* yaw about +Y, then pitch about +X */
    float y = yaw / 2, p = pitch / 2;
    return (XrQuaternionf){cosf(y) * sinf(p), sinf(y) * cosf(p), -sinf(y) * sinf(p), cosf(y) * cosf(p)};
}
static XrQuaternionf dk_head_orientation(void) { return dk_yaw_pitch(dk_float(&dk.yaw_bits), dk_float(&dk.pitch_bits)); }
/* The two hands: held still 0.5 m below the 1.6 m head, 0.2 m to each side and 0.35 m (aim 0.4 m) ahead of it,
 * turned with the head's yaw and pointing where it looks; controls from the held keys. */
static void dk_hands(uint32_t profile, KlNativeInputHand3 out[2]) {
    uint64_t bits[2] = {0, 0}; if (dk.enabled) dk_bits(bits);
    float yaw = dk_float(&dk.yaw_bits), c = cosf(yaw), s = sinf(yaw);
    /* where the head looks, turned further by the hands' aim (right-button drag) */
    XrQuaternionf q = dk_yaw_pitch(yaw + dk_float(&dk.aim_yaw_bits), dk_float(&dk.pitch_bits) + dk_float(&dk.aim_pitch_bits));
    for (unsigned i = 0; i < 2; i++) {
        float x = i ? .2f : -.2f, sx = (float)(dk_held(bits, i, DK_STICK_RIGHT) - dk_held(bits, i, DK_STICK_LEFT)),
              sy = (float)(dk_held(bits, i, DK_STICK_UP) - dk_held(bits, i, DK_STICK_DOWN));
        if (sx && sy) { sx *= (float)M_SQRT1_2; sy *= (float)M_SQRT1_2; }
        out[i] = (KlNativeInputHand3){.controls={.connected=XR_TRUE,.trigger=dk_held(bits, i, DK_TRIGGER) ? 1.f : 0.f,.stick_x=sx,.stick_y=sy,
                .primary_pressed=(XrBool32)dk_held(bits, i, DK_PRIMARY),.secondary_pressed=(XrBool32)dk_held(bits, i, DK_SECONDARY),
                .grip_pressed=(XrBool32)dk_held(bits, i, DK_GRIP),.menu_pressed=(XrBool32)dk_held(bits, i, DK_MENU),
                .stick_pressed=(XrBool32)dk_held(bits, i, DK_STICK_CLICK)},.profile=profile,
            .local_from_grip={.orientation=q,.position={x * c - .35f * s,1.1f,-x * s - .35f * c}},
            .local_from_aim={.orientation=q,.position={x * c - .4f * s,1.1f,-x * s - .4f * c}}};
    }
}
static void dk_log_sample(uint64_t id, const KlNativeInputHand3 h[2]) {
    if (++dk.changes > 2000 && dk.changes % 100) return;
    char text[2][160];
    for (unsigned i = 0; i < 2; i++) {
        const KlNativeInputHand2 *c = &h[i].controls;
        snprintf(text[i], sizeof text[i], "trigger %.0f grip %u %s %u %s %u menu %u stick %.2f %.2f click %u", c->trigger, c->grip_pressed,
                 i ? "a" : "x", c->primary_pressed, i ? "b" : "y", c->secondary_pressed, c->menu_pressed, c->stick_x, c->stick_y, c->stick_pressed);
    }
    vx_log("xrizer dev keyboard: sample %llu left %s | right %s | head yaw %.1f pitch %.1f aim %.1f %.1f deg (change %u)", (unsigned long long)id, text[0], text[1],
           dk_float(&dk.yaw_bits) * 180 / M_PI, dk_float(&dk.pitch_bits) * 180 / M_PI, dk_float(&dk.aim_yaw_bits) * 180 / M_PI,
           dk_float(&dk.aim_pitch_bits) * 180 / M_PI, dk.changes);
}

/* Live rates for the mirror window's title (VXRT_XRIZER_DEV_KEYBOARD=1), updated twice a second over the last second.
 * pairs: fresh eye pairs the game submitted (one per publish: repeats of the last pair are not counted); waits: the
 * host's frame ticks (paced at 90 Hz); interval: time between consecutive fresh pairs; GPU: Metal GPUEndTime -
 * GPUStartTime of the command buffer that copies the pair and draws the mirror (not the game's own rendering). */
static struct { pthread_mutex_t lock; unsigned pairs, waits, gpu_n; double max_iv, gpu_sum; double last_pair; } dk_stats = {.lock = PTHREAD_MUTEX_INITIALIZER};
static double dk_now_s(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9; }
static void dk_stats_wait(void) { if (!dk.window) return; pthread_mutex_lock(&dk_stats.lock); ++dk_stats.waits; pthread_mutex_unlock(&dk_stats.lock); }
static void dk_stats_pair(double gpu_s) {
    if (!dk.window) return;
    double t = dk_now_s();
    pthread_mutex_lock(&dk_stats.lock);
    ++dk_stats.pairs;
    if (dk_stats.last_pair > 0) { double iv = t - dk_stats.last_pair; if (iv > dk_stats.max_iv) dk_stats.max_iv = iv; }
    dk_stats.last_pair = t;
    if (gpu_s > 0) { dk_stats.gpu_sum += gpu_s; ++dk_stats.gpu_n; }
    pthread_mutex_unlock(&dk_stats.lock);
}
static void dk_start_title_timer(void) {   /* main thread */
    static dispatch_source_t timer; if (timer) return;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 2, NSEC_PER_SEC / 20);
    __block double prev_t = dk_now_s();
    struct hist { double max[2], gpu[2], dt[2]; unsigned pairs[2], waits[2], gn[2]; } *hp = calloc(1, sizeof *hp);   /* two half-second slots */
    __block unsigned slot = 0;
    dispatch_source_set_event_handler(timer, ^{
        if (!dk_window) return;
        double t = dk_now_s();
        pthread_mutex_lock(&dk_stats.lock);
        unsigned pairs = dk_stats.pairs, waits = dk_stats.waits, gn = dk_stats.gpu_n; double miv = dk_stats.max_iv, gs = dk_stats.gpu_sum;
        dk_stats.pairs = dk_stats.waits = dk_stats.gpu_n = 0; dk_stats.max_iv = dk_stats.gpu_sum = 0;
        pthread_mutex_unlock(&dk_stats.lock);
        slot ^= 1; hp->pairs[slot] = pairs; hp->waits[slot] = waits; hp->max[slot] = miv; hp->gpu[slot] = gs; hp->gn[slot] = gn; hp->dt[slot] = t - prev_t; prev_t = t;
        double dt = hp->dt[0] + hp->dt[1]; unsigned P = hp->pairs[0] + hp->pairs[1], W = hp->waits[0] + hp->waits[1], G = hp->gn[0] + hp->gn[1];
        if (dt <= 0) return;
        double ivn = P ? dt / P : 0;   /* mean interval between fresh pairs */
        double mx = hp->max[0] > hp->max[1] ? hp->max[0] : hp->max[1];
        NSMutableString *title = [NSMutableString stringWithFormat:@"VXRuntime dev keyboard (click here for keys) | game %.0f fresh pairs/s | host %.0f Hz",
                                  P / dt, W / dt];
        if (P) [title appendFormat:@" | frame avg %.1f ms worst %.1f ms", ivn * 1000, mx * 1000]; else [title appendString:@" | no fresh pair"];
        if (G) [title appendFormat:@" | copy+mirror GPU %.2f ms", (hp->gpu[0] + hp->gpu[1]) / G * 1000];
        dk_window.title = title;
        static unsigned shown; if (!(++shown % 20)) vx_log("xrizer dev keyboard: title: %s", title.UTF8String);
    });
    dispatch_resume(timer);
}

/* The key-map help panel, drawn by the window system over the mirror's layer (never into the game's image). It is built
 * from dk.map, the table the keys really use, so VXRT_XRIZER_DEV_KEYMAP overrides show. F1 or ? toggles it; it is
 * shown for the first 20 s. docs/dev-keyboard.md has the default table (tests/dev_keyboard_doc_check.py keeps them equal). */
static CATextLayer *dk_help_left, *dk_help_right;
static NSString *dk_key_label(unsigned code) {
    static const struct { const char *name, *label; } nice[] = {{"lshift","Left Shift"},{"rshift","Right Shift"},{"lctrl","Left Ctrl"},{"rctrl","Right Ctrl"},
        {"lalt","Left Alt"},{"ralt","Right Alt"},{"lbracket","["},{"rbracket","]"},{"comma",","},{"period","."},{"semicolon",";"},{"slash","/"},
        {"quote","'"},{"backslash","\\"},{"minus","-"},{"equal","="},{"grave","`"},{"pageup","Page Up"},{"pagedown","Page Down"},{"return","Return"},
        {"enter","Return"},{"backspace","Backspace"},{"escape","Esc"},{"space","Space"},{"tab","Tab"},{"home","Home"},{"end","End"},
        {"up","Up arrow"},{"down","Down arrow"},{"left","Left arrow"},{"right","Right arrow"}};
    for (size_t i = 0; i < sizeof dk_key_names / sizeof dk_key_names[0]; i++) {
        if (dk_key_names[i].code != code) continue;
        for (size_t k = 0; k < sizeof nice / sizeof nice[0]; k++) if (!strcmp(nice[k].name, dk_key_names[i].name)) return @(nice[k].label);
        return strlen(dk_key_names[i].name) == 1 ? [@(dk_key_names[i].name) uppercaseString] : [@(dk_key_names[i].name) uppercaseString];
    }
    return [NSString stringWithFormat:@"key %u", code];
}
static NSString *dk_keys_for(unsigned hand, unsigned control) {
    NSMutableArray *k = [NSMutableArray array];
    for (unsigned code = 0; code < 128; code++) if (dk.map[code].control == control && dk.map[code].hand == hand && (control || hand)) {
        NSString *l = dk_key_label(code); if (![k containsObject:l]) [k addObject:l];
    }
    return [k componentsJoinedByString:@" / "];
}
static NSString *dk_hand_help(unsigned hand) {
    static const struct { unsigned control; const char *label[2]; const char *use[2]; } rows[] = {
        {DK_STICK_UP,{"stick up","stick up"},{"move forward; menus: up","look up; menus: up"}},
        {DK_STICK_DOWN,{"stick down","stick down"},{"move back; menus: down","look down; menus: down"}},
        {DK_STICK_LEFT,{"stick left","stick left"},{"strafe left","turn left"}},
        {DK_STICK_RIGHT,{"stick right","stick right"},{"strafe right","turn right"}},
        {DK_STICK_CLICK,{"stick click","stick click"},{"sprint","item zoom (inventory)"}},
        {DK_TRIGGER,{"trigger","trigger"},{"left hand attack/block/cast","right hand attack; menus: accept"}},
        {DK_GRIP,{"grip","grip"},{"ready/sheathe weapon; menus: cancel","shout; menus: cancel"}},
        {DK_PRIMARY,{"X","A"},{"tween (system) menu","activate; menus: accept"}},
        {DK_SECONDARY,{"Y","B"},{"journal / wait; menus: tab left","favorites; menus: tab right"}},
        {DK_MENU,{"menu","menu"},{"(xrizer does not bind it)","(xrizer does not bind it)"}}};
    NSMutableString *t = [NSMutableString stringWithString:hand ? @"RIGHT HAND\n" : @"LEFT HAND\n"];
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        NSString *keys = dk_keys_for(hand, rows[i].control); if (!keys.length) continue;
        [t appendFormat:@"%-22s %s\n  %@\n", rows[i].label[hand], rows[i].use[hand], keys];
    }
    return t;
}
static NSString *dk_head_help(void) {
    static const char *const use[] = {NULL,"head turn left","head turn right","head pitch up","head pitch down","reset head and aim",
        "hands aim left","hands aim right","hands aim up","hands aim down"};
    NSMutableString *t = [NSMutableString stringWithString:@"HEAD AND AIM (relative to the head)\n"];
    for (unsigned c = 1; c <= DK_AIM_DOWN; c++) { NSString *k = dk_keys_for(DK_HEAD, c); if (k.length) [t appendFormat:@"%@: %s\n", k, use[c]]; }
    [t appendString:@"mouse drag: turn head   right-button drag: aim hands\n"];
    return t;
}
static void dk_help_update(void) {
    NSString *left = dk_hand_help(DK_LEFT), *right = dk_hand_help(DK_RIGHT);
    dk_help_left.string = left;
    dk_help_right.string = [right stringByAppendingFormat:@"\n%@\nQUIT: Ctrl-C in the terminal, or close the Skyrim window\nF1 or ? shows/hides this help", dk_head_help()];
    for (CATextLayer *t in @[dk_help_left, dk_help_right]) { CGSize z = t.preferredFrameSize; t.bounds = CGRectMake(0, 0, z.width + 10, z.height + 8); }
}
static void dk_help_toggle(void) {
    dk_help_left.hidden = !dk_help_left.hidden; dk_help_right.hidden = dk_help_left.hidden;
}
static CATextLayer *dk_help_layer(CALayer *parent, BOOL rightColumn) {
    CATextLayer *t = [CATextLayer layer];
    t.font = (__bridge CFTypeRef)[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular]; t.fontSize = 10;
    t.foregroundColor = CGColorGetConstantColor(kCGColorWhite); t.contentsScale = 2; t.wrapped = NO; t.alignmentMode = kCAAlignmentLeft;
    t.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 0.72);
    t.bounds = CGRectMake(0, 0, 500, 500); t.anchorPoint = CGPointMake(rightColumn ? 1 : 0, 1);
    t.autoresizingMask = (rightColumn ? kCALayerMinXMargin : kCALayerMaxXMargin) | kCALayerMinYMargin;
    t.position = CGPointMake(rightColumn ? parent.bounds.size.width - 4 : 4, parent.bounds.size.height - 4);
    [parent addSublayer:t];
    return t;
}

/* The mirror window: the two eyes side by side, the keyboard and the mouse. */
@interface VXDevKeyView : NSView <NSWindowDelegate>
@end
@implementation VXDevKeyView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 122 || [e.charactersIgnoringModifiers isEqualToString:@"?"] || [e.characters isEqualToString:@"?"]) { if (!e.isARepeat) dk_help_toggle(); return; }   /* F1, ? */
    if (!(e.modifierFlags & NSEventModifierFlagCommand)) dk_key(e.keyCode, 1);
}
- (void)keyUp:(NSEvent *)e { dk_key(e.keyCode, 0); }
- (void)flagsChanged:(NSEvent *)e {
    /* Which side's modifier: the device-dependent bits (NX_DEVICE*KEYMASK). */
    static const struct { unsigned short code; NSUInteger mask; } m[] = {{56,0x2},{60,0x4},{59,0x1},{62,0x2000},{58,0x20},{61,0x40}};
    for (unsigned i = 0; i < sizeof m / sizeof m[0]; i++) if (m[i].code == e.keyCode) dk_key(e.keyCode, (e.modifierFlags & m[i].mask) != 0);
}
- (void)mouseDown:(NSEvent *)e {
    if (!NSApp.isActive) [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:self];
}
- (void)mouseDragged:(NSEvent *)e {
    atomic_fetch_add(&dk.drag_dx_milli, (int)(e.deltaX * 1000)); atomic_fetch_add(&dk.drag_dy_milli, (int)(e.deltaY * 1000));
}
- (void)rightMouseDown:(NSEvent *)e { [self mouseDown:e]; }
- (void)rightMouseDragged:(NSEvent *)e {
    atomic_fetch_add(&dk.aim_dx_milli, (int)(e.deltaX * 1000)); atomic_fetch_add(&dk.aim_dy_milli, (int)(e.deltaY * 1000));
}
- (void)windowDidResignKey:(NSNotification *)n { atomic_store(&dk.keys[0], 0); atomic_store(&dk.keys[1], 0); }
- (void)windowDidChangeOcclusionState:(NSNotification *)n {
    atomic_store(&dk.mirror, (((NSWindow *)n.object).occlusionState & NSWindowOcclusionStateVisible) != 0);
}
- (void)windowWillClose:(NSNotification *)n { atomic_store(&dk.mirror, 0); atomic_store(&dk.keys[0], 0); atomic_store(&dk.keys[1], 0); }
@end
static void dk_open_window(id<MTLDevice> device, unsigned width, unsigned height) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        vx_cocoa_ensure();
        dispatch_async(dispatch_get_main_queue(), ^{
            dk_layer = [CAMetalLayer layer];
            dk_layer.device = device; dk_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; dk_layer.framebufferOnly = YES;
            dk_layer.displaySyncEnabled = NO; dk_layer.drawableSize = CGSizeMake(width, height / 2);
            dk_layer.contentsGravity = kCAGravityResizeAspect; dk_layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
            NSRect r = NSMakeRect(0, 0, 1024, 512);
            NSWindow *w = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
            w.releasedWhenClosed = NO;
            w.title = @"VXRuntime dev keyboard: click here, then keys drive the synthetic controllers (diagnostic, not physical input)";
            VXDevKeyView *v = [[VXDevKeyView alloc] initWithFrame:r]; v.layer = dk_layer; v.wantsLayer = YES;   /* layer-hosting */
            w.contentView = v; w.delegate = v; [w makeFirstResponder:v]; [w center];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            const char *na = getenv("VXRT_NO_ACTIVATE");
            if (na && *na == '1') [w orderFront:nil]; else { [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
            dk_window = w; dk_start_title_timer();
            dk_help_left = dk_help_layer(dk_layer, NO); dk_help_right = dk_help_layer(dk_layer, YES); dk_help_update();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (!dk_help_left.hidden) dk_help_toggle(); });
            atomic_store(&dk.mirror, 1);
            vx_log("xrizer dev keyboard: mirror window open; click it to give it the keyboard");
        });
    });
}
/* Encode the two eyes into the window's next drawable on the frame's command buffer; any failure only disables it. */
static atomic_int dk_drawables_held;   /* drawables taken by the mirror and not yet shown (non-blocking mode) */
static void dk_mirror(id<MTLDevice> device, id<MTLCommandBuffer> cb, id<MTLTexture> const eyes[2], BOOL best_effort) {
    if (!atomic_load(&dk.mirror)) return;
    /* Best effort in the non-blocking submit: the window shows at the display's rate, and nextDrawable waits for a free
     * drawable, which would pace the game's render thread at that rate (60 pairs/s on a 60 Hz display). Skip the
     * mirror for this pair when two drawables are still waiting to be shown. */
    if (best_effort && atomic_load(&dk_drawables_held) >= 2) return;
    if (!dk_pipeline) {
        static int failed; if (failed) return;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V vs(uint i [[vertex_id]]) { float2 u = float2((i << 1) & 2, i & 2); V v; v.p = float4(u * float2(2, -2) + float2(-1, 1), 0, 1); v.uv = u; return v; }\n"
            "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::linear); return float4(t.sample(s, v.uv).rgb, 1); }\n";
        NSError *err = nil; id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        dk_pipeline = lib ? [device newRenderPipelineStateWithDescriptor:d error:&err] : nil;
        if (!dk_pipeline) { failed = 1; vx_log("xrizer dev keyboard: mirror disabled: %s", err.localizedDescription.UTF8String); return; }
    }
    id<CAMetalDrawable> drawable = [dk_layer nextDrawable]; if (!drawable) return;
    if (best_effort) { atomic_fetch_add(&dk_drawables_held, 1); [drawable addPresentedHandler:^(id<MTLDrawable> d) { (void)d; atomic_fetch_sub(&dk_drawables_held, 1); }]; }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass]; if (!enc) { if (best_effort) atomic_fetch_sub(&dk_drawables_held, 1); return; }
    [enc setRenderPipelineState:dk_pipeline];
    double w = (double)drawable.texture.width / 2, hgt = (double)drawable.texture.height;
    for (unsigned i = 0; i < 2; i++) {
        [enc setViewport:(MTLViewport){w * i, 0, w, hgt, 0, 1}];
        [enc setFragmentTexture:eyes[i] atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding]; [cb presentDrawable:drawable];
    static unsigned presented; if (++presented <= 3 || !(presented % 600))
        vx_log("xrizer dev keyboard: mirror drew eyes %lux%lu into %lux%lu (%u frames)", (unsigned long)eyes[0].width, (unsigned long)eyes[0].height,
               (unsigned long)drawable.texture.width, (unsigned long)drawable.texture.height, presented);
}

static VXDevXRHost *host(void *p) { return (__bridge VXDevXRHost *)p; }
static void keep(void *p) { if (p) { CFRetain(p); if (dev_host) (void)vx_eye_ring_reader(dev_host.ring,p,1); } }
static void drop(void *p) { if (p) { if (dev_host) (void)vx_eye_ring_reader(dev_host.ring,p,-1); CFRelease(p); } }
static void ring_log(const char *m) { vx_log("%s",m); }
static XrResult available(void *p) { return p ? XR_SUCCESS : XR_ERROR_RUNTIME_FAILURE; }
static XrResult views(void *p, KlNativeViewConfiguration *out) {
    VXDevXRHost *h=host(p); if (!h || !out) return XR_ERROR_VALIDATION_FAILURE;
    *out=(KlNativeViewConfiguration){.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE,.fov_mutable=XR_FALSE};
    for (unsigned i=0;i<2;i++) out->view[i]=(XrViewConfigurationView){.type=XR_TYPE_VIEW_CONFIGURATION_VIEW,
        .recommendedImageRectWidth=h.width,.maxImageRectWidth=h.width,.recommendedImageRectHeight=h.height,
        .maxImageRectHeight=h.height,.recommendedSwapchainSampleCount=1,.maxSwapchainSampleCount=1};
    return XR_SUCCESS;
}
/* Static synthetic optics for the explicit development host, independent of
 * a tracked head sample, predicted time, floor, or frame ticket. */
static XrResult view_geometry(void *p, KlNativeViewGeometry *out) {
    if (!p || !out) return XR_ERROR_VALIDATION_FAILURE;
    *out=(KlNativeViewGeometry){.version=KL_NATIVE_VIEW_GEOMETRY_VERSION,.struct_size=sizeof(*out),.geometry_id=1,
        .head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},
        .fov={{-.785398f,.785398f,.785398f,-.785398f},{-.785398f,.785398f,.785398f,-.785398f}}};
    return XR_SUCCESS;
}
static XrResult poll_event(void *p,KlNativeSessionEvent *out) {
    VXDevXRHost *h=host(p); if (!h || !out) return XR_ERROR_VALIDATION_FAILURE;
    if (!h.event.type) return XR_EVENT_UNAVAILABLE;
    *out=h.event; h.event=(KlNativeSessionEvent){0};
    if (out->type==KL_NATIVE_SESSION_VISIBLE) h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_FOCUSED,now_ns()};
    return XR_SUCCESS;
}
static XrResult begin_session(void *p,XrTime *out) {
    VXDevXRHost *h=host(p); if (!h || !out || h.event.type || !(*out=now_ns())) return XR_ERROR_RUNTIME_FAILURE;
    h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_VISIBLE,*out};
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) ++h.begins;
#endif
    vx_log("xrizer dev host: synthetic session begun"); return XR_SUCCESS;
}
static XrResult request_exit(void *p) {
    VXDevXRHost *h=host(p); XrTime t=now_ns();
    if (!h || !t || h.outstanding) return XR_ERROR_RUNTIME_FAILURE;
    /* An immediate shutdown may supersede an unconsumed synthetic focus event. */
    h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_STOPPING,t};
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) ++h.exits;
#endif
    vx_log("xrizer dev host: synthetic session exit requested"); return XR_SUCCESS;
}
static XrResult end_session(void *p,XrTime *out) {
    VXDevXRHost *h=host(p); XrTime t=now_ns();
    if (!h || !out || !t || h.outstanding || h.event.type || !h.frames) return XR_ERROR_RUNTIME_FAILURE;
    vx_eye_ring_drain(h.ring); vx_eye_ring_log_stats(h.ring);   /* pending copies publish from completion handlers: they finish before the queue goes */
    vx_native_vr_reset(h.frames);
    if (vx_native_vr_destroy(h.frames)) return XR_ERROR_RUNTIME_FAILURE;
    h.frames=NULL; *out=t; h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_EXITING,t};
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) ++h.ends;
#endif
    vx_log("xrizer dev host: session ended with frame queue drained"); return XR_SUCCESS;
}
static XrResult input(void *p,KlNativeInputSample *out) {
    VXDevXRHost *h=host(p); if (!h || !out || !h.inputTime) return XR_ERROR_RUNTIME_FAILURE;
    *out=(KlNativeInputSample){.sample_id=1,.sample_time=h.inputTime,.hand_connected={XR_FALSE,XR_FALSE}}; return XR_SUCCESS;
}
/* Diagnostic: two connected controllers in front of the synthetic head (dk_hands), valid but untracked poses. Without
 * the development keyboard they never change: one observation (same id and time on every poll), no button pressed,
 * trigger and stick at rest. With it each change of keys or head is a new observation (id and time). Not physical input. */
/* Haptic output on the Mac: nothing vibrates; each request the provider forwards is logged (the path is observable). */
static XrResult dev_haptic_apply(void *p,uint32_t hand,const KlNativeHapticVibration *v) {
    (void)p; vx_log("xrizer dev host: haptic (logged, no actuator) %s hand amplitude %.2f duration %lld ns frequency %.0f Hz",
        hand ? "right" : "left",v->amplitude,(long long)v->duration,v->frequency); return XR_SUCCESS;
}
static XrResult dev_haptic_stop(void *p,uint32_t hand) {
    (void)p; vx_log("xrizer dev host: haptic stop (logged, no actuator) %s hand",hand ? "right" : "left"); return XR_SUCCESS;
}
static XrResult synthetic_controllers(void *p,KlNativeInputSample3 *out) {
    VXDevXRHost *h=host(p); if (!h || !out || !h.inputTime || !h.syntheticControllers) return XR_ERROR_RUNTIME_FAILURE;
    KlNativeInputHand3 hands[2]; dk_hands(h.syntheticControllers,hands);
    pthread_mutex_lock(&dk.lock);
    if (!dk.sample_id) { dk.sample_id=1; dk.sample_time=h.inputTime; memcpy(dk.hands,hands,sizeof hands); }
    else if (memcmp(dk.hands,hands,sizeof hands)) {
        XrTime t=now_ns(); if (t<=dk.sample_time) t=dk.sample_time+1;
        ++dk.sample_id; dk.sample_time=t; memcpy(dk.hands,hands,sizeof hands); dk_log_sample(dk.sample_id,hands);
    }
    *out=(KlNativeInputSample3){.sample_id=dk.sample_id,.sample_time=dk.sample_time};
    memcpy(out->hand,dk.hands,sizeof dk.hands);
    pthread_mutex_unlock(&dk.lock);
    return XR_SUCCESS;
}
static XrResult wait_frame(void *p,KlNativeFrameSample *out) {
    VXDevXRHost *h=host(p); if (!h || !out || h.outstanding) return XR_ERROR_RUNTIME_FAILURE;
    // Paced like a 90 Hz display: a frame is due one period after the previous one was, so the program's own frame
    // time counts toward it (a fixed sleep after each frame added a whole period to every frame).
    // A late frame is not made up for: the next one is due a period after now.
    XrTime t=now_ns(); if (!t) return XR_ERROR_RUNTIME_FAILURE;
    if (h.deadline>t) {
        struct timespec delay={(time_t)((h.deadline-t)/1000000000),(long)((h.deadline-t)%1000000000)};
        while (nanosleep(&delay,&delay)) if (errno!=EINTR) return XR_ERROR_RUNTIME_FAILURE;
        t=now_ns(); if (!t) return XR_ERROR_RUNTIME_FAILURE;
    }
    h.deadline=(h.deadline>t ? h.deadline : t)+INT64_C(11111111);
    if (h.nextFrame==UINT64_MAX) return XR_ERROR_RUNTIME_FAILURE;
    dk_stats_wait();
    uint64_t id=++h.nextFrame;
    dk_frame(id,t);
    *out=(KlNativeFrameSample){.ticket=(__bridge void *)h,.frame_id=id,.pose_id=id,.predicted_display_time=t+INT64_C(11111111),
        .predicted_display_period=INT64_C(11111111),.should_render=XR_TRUE,
        .head_location_flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT,
        .local_from_head={.orientation=dk_head_orientation(),.position={0,1.6f,0}},
        .stage_valid=h.syntheticStage ? XR_TRUE : XR_FALSE,
        .local_from_stage={.orientation={0,0,0,1},.position={0,0,0}},
        .head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},
        .fov={{-.785398f,.785398f,.785398f,-.785398f},{-.785398f,.785398f,.785398f,-.785398f}}};
    h.sample=*out; h.outstanding=YES;
    if (id<=10 || id%120==0) vx_log("xrizer dev host: synthetic sample frame %llu pose %llu predicted_ns %lld",(unsigned long long)id,(unsigned long long)id,(long long)out->predicted_display_time);
    return XR_SUCCESS;
}
static XrResult cancel_frame(void *p,void *ticket) {
    VXDevXRHost *h=host(p); if (!h || !h.outstanding || ticket!=(__bridge void *)h) return XR_ERROR_RUNTIME_FAILURE;
    vx_log("xrizer dev host: cancelled frame %llu pose %llu",(unsigned long long)h.sample.frame_id,(unsigned long long)h.sample.pose_id);
    h.outstanding=NO; return XR_SUCCESS;
}
static int record_destination(void *p,void *texture,void *cb) {
    VXDevXRHost *h=host(p); KlNativeMetalHost metal=h.metal;
    return kl_apple_metal_record_texture_writes(&metal,texture,cb)==XR_SUCCESS ? 0 : -1;
}
static void *factory(void *p,int *error) {
    VXDevXRHost *h=host(p); void *(*fn)(const char *,int *)=h.library ? dlsym(h.library,"VRClientCoreFactory") : NULL;
    if (!fn) { if (error) *error=100; return NULL; }
    return fn("IVRClientCore_003",error);
}
static void pose_matrix(XrPosef p,float m[16]) {
    float x=p.orientation.x,y=p.orientation.y,z=p.orientation.z,w=p.orientation.w;
    const float v[16]={1-2*y*y-2*z*z,2*x*y+2*w*z,2*x*z-2*w*y,0,2*x*y-2*w*z,1-2*x*x-2*z*z,2*y*z+2*w*x,0,
        2*x*z+2*w*y,2*y*z-2*w*x,1-2*x*x-2*y*y,0,p.position.x,p.position.y,p.position.z,1};
    memcpy(m,v,sizeof v);
}
#include "pose_math.h"
/* Everything after the copy finished on the GPU: statistics, optional dumps, then the pair to native_vr. `settle`: the
 * blocking path clears the outstanding ticket here; the non-blocking path already did when it committed. */
static XrResult finish_pair(VXDevXRHost *h,const KlNativeFramePair *pair,id<MTLTexture> const copies[2],id<MTLBuffer> const dumps[2],
                            BOOL keep_files,double gpu_s,BOOL settle) {
    uint64_t fid=pair->sample.frame_id;
    dk_stats_pair(gpu_s);
    for (unsigned i=0;i<2;i++) if (dumps[i]) {
        const uint8_t *px=dumps[i].contents; NSUInteger n=dumps[i].length/4, w=(NSUInteger)pair->eye[i].rect.extent.width;
        uint64_t sum[3]={0,0,0}, differ=0, nonzero=0; for (NSUInteger k=0;k<n;k++) {
            sum[0]+=px[k*4]; sum[1]+=px[k*4+1]; sum[2]+=px[k*4+2];
            if (memcmp(px+k*4,px,4)) ++differ; if (px[k*4]|px[k*4+1]|px[k*4+2]) ++nonzero;
        }
        char path[1024]; snprintf(path,sizeof path,"%s/frame%llu_eye%u_%lux%lu.rgba",h.dumpDir.UTF8String,(unsigned long long)fid,i,(unsigned long)w,(unsigned long)(n/w));
        FILE *f=keep_files ? fopen(path,"wb") : NULL; if (f) { fwrite(px,1,dumps[i].length,f); fclose(f); }
        vx_log("xrizer dev host: dump frame %llu eye %u %lux%lu mean rgb %.1f %.1f %.1f, %.1f%% pixels differ from pixel 0, %.1f%% non-black%s%s",(unsigned long long)fid,i,
            (unsigned long)w,(unsigned long)(n/w),(double)sum[0]/n,(double)sum[1]/n,(double)sum[2]/n,100.0*differ/n,100.0*nonzero/n,f?" -> ":"",f?path:"");
    }
    vx_native_vr_pose pose={.frame_id=pair->sample.frame_id,.pose_id=pair->sample.pose_id,
        .pose_time=(double)pair->sample.predicted_display_time/1e9,
        .tracking_valid=(pair->sample.head_location_flags & (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)) ==
                        (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)};
    pose_matrix(pair->sample.local_from_head,pose.origin_from_head);
    for (unsigned i=0;i<2;i++) {
        pose_matrix(kl_native_pose_relative(pair->sample.local_from_head,pair->eye[i].local_from_render_eye),pose.head_from_eye[i]);
        XrFovf f=pair->eye[i].fov; pose.frustum[i][0]=tanf(f.angleLeft); pose.frustum[i][1]=tanf(f.angleRight);
        pose.frustum[i][2]=-tanf(f.angleUp); pose.frustum[i][3]=-tanf(f.angleDown);
    }
    vx_native_vr_handle frame=0; unsigned submitted=0, completed=0;
    if (vx_native_vr_begin(h.frames,&pose,&frame)) return XR_ERROR_RUNTIME_FAILURE;
    for (unsigned i=0;i<2;i++) {
        vx_native_vr_eye eye={.resource=(__bridge void *)copies[i],.width=(uint32_t)copies[i].width,
            .height=(uint32_t)copies[i].height,.format=(uint32_t)copies[i].pixelFormat,.sample_count=1,
            .color_space=VX_NATIVE_VR_COLOR_LINEAR,.u_max=1,.v_max=1};
        if (vx_native_vr_submit(h.frames,frame,i,pose.frame_id,pose.pose_id,&eye)) goto failed;
        submitted|=1u<<i;
    }
    for (unsigned i=0;i<2;i++) { if (vx_native_vr_complete(h.frames,frame,i)) goto failed; completed|=1u<<i; }
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) {
        ++h.published;
        vx_log("xrizer dev audit: published frame %llu pose %llu",(unsigned long long)pose.frame_id,(unsigned long long)pose.pose_id);
        (void)vx_xrizer_dev_audit_observe(h.published-1);
    }
#endif
    vx_native_vr_frame read;
    if (vx_native_vr_acquire(h.frames,&read)) { vx_native_vr_reset(h.frames); if (settle) h.outstanding=NO; return XR_SUCCESS; }
    vx_log("xrizer dev host: offscreen fresh pair frame %llu pose %llu (%ux%u, %ux%u), no display",(unsigned long long)pose.frame_id,
        (unsigned long long)pose.pose_id,read.eye[0].width,read.eye[0].height,read.eye[1].width,read.eye[1].height);
    if (vx_native_vr_release(h.frames,read.lease)) return XR_ERROR_RUNTIME_FAILURE;
    vx_native_vr_reset(h.frames); if (settle) h.outstanding=NO; return XR_SUCCESS;
failed:
    (void)vx_native_vr_cancel(h.frames,frame);
    for (unsigned i=0;i<2;i++) if ((submitted & (1u<<i)) && !(completed & (1u<<i))) (void)vx_native_vr_complete(h.frames,frame,i);
    return XR_ERROR_RUNTIME_FAILURE;
}

static XrResult publish(void *p,const KlNativeFramePair *pair) {
    VXDevXRHost *h=host(p);
    KlNativeFrameSample sample=h ? h.sample : (KlNativeFrameSample){0};
    if (!h || !pair || !h.frames || !h.outstanding || pair->sample.ticket!=(__bridge void *)h ||
        pair->sample.frame_id!=h.sample.frame_id || pair->sample.pose_id!=h.sample.pose_id ||
        pair->sample.predicted_display_time!=h.sample.predicted_display_time ||
        pair->sample.head_location_flags!=h.sample.head_location_flags ||
        memcmp(&pair->sample.local_from_head,&sample.local_from_head,sizeof sample.local_from_head) ||
        memcmp(pair->sample.head_from_eye,sample.head_from_eye,sizeof sample.head_from_eye) ||
        memcmp(pair->sample.fov,sample.fov,sizeof sample.fov)) return XR_ERROR_RUNTIME_FAILURE;
    id<MTLTexture> copies[2]={nil,nil};
    id<MTLBuffer> dumps[2]={nil,nil};
    vx_eye_slot *slot=NULL; vx_eye_ring *ring=h.ring;
    uint64_t fid=pair->sample.frame_id;
    if (d3d11_capture_on) d3d11_capture_eye_frame(fid);   /* VXRT_D3D11_CAPTURE: the eye pair of this frame is complete */
    static unsigned long every; if (!every) { const char *e=getenv("VXRT_XRIZER_DEV_DUMP_EVERY"); every=e ? strtoul(e,NULL,10) : 600; if (every<30) every=600; }
    BOOL keep_files=fid==1 || fid==2 || fid==60 || fid%every==0;   /* VXRT_XRIZER_DEV_DUMP_EVERY=N: a file every N frames (default 600, at least 30) */
    BOOL dump=h.dumpDir && (keep_files || fid%30==0); /* statistics every 30th frame; files for the selected few */
    if (ring) {   /* non-blocking path: validate both eyes, then take a pooled slot (blocks at the in-flight bound) */
        uint32_t w[2],ht[2],fmt[2];
        for (unsigned i=0;i<2;i++) {
            const KlNativeFrameEye *e=&pair->eye[i]; id<MTLTexture> src=(__bridge id<MTLTexture>)e->texture;
            if (!src || src.device!=h.device || src.pixelFormat!=MTLPixelFormatRGBA8Unorm || e->format!=(int64_t)src.pixelFormat || !e->image_lease || e->rect.offset.x<0 || e->rect.offset.y<0 ||
                e->rect.extent.width<=0 || e->rect.extent.height<=0 || e->array_layer>=src.arrayLength ||
                (NSUInteger)e->rect.offset.x+(NSUInteger)e->rect.extent.width>src.width ||
                (NSUInteger)e->rect.offset.y+(NSUInteger)e->rect.extent.height>src.height || src.sampleCount!=1) return XR_ERROR_RUNTIME_FAILURE;
            w[i]=(uint32_t)e->rect.extent.width; ht[i]=(uint32_t)e->rect.extent.height; fmt[i]=(uint32_t)src.pixelFormat;
        }
        if (vx_eye_ring_reserve(ring,w,ht,fmt,&slot)) return XR_ERROR_OUT_OF_MEMORY;
        copies[0]=(__bridge id<MTLTexture>)slot->tex[0]; copies[1]=(__bridge id<MTLTexture>)slot->tex[1];
    }
    id<MTLCommandBuffer> cb=[h.queue commandBuffer]; if (!cb) { if (slot) vx_eye_ring_abort(ring,slot); return XR_ERROR_RUNTIME_FAILURE; }
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; if (!blit) { if (slot) vx_eye_ring_abort(ring,slot); return XR_ERROR_RUNTIME_FAILURE; }
    for (unsigned i=0;i<2;i++) {
        const KlNativeFrameEye *e=&pair->eye[i]; id<MTLTexture> src=(__bridge id<MTLTexture>)e->texture;
        if (!src || src.device!=h.device || src.pixelFormat!=MTLPixelFormatRGBA8Unorm || e->format!=(int64_t)src.pixelFormat || !e->image_lease || e->rect.offset.x<0 || e->rect.offset.y<0 ||
            e->rect.extent.width<=0 || e->rect.extent.height<=0 || e->array_layer>=src.arrayLength ||
            (NSUInteger)e->rect.offset.x+(NSUInteger)e->rect.extent.width>src.width ||
            (NSUInteger)e->rect.offset.y+(NSUInteger)e->rect.extent.height>src.height || src.sampleCount!=1) {
            [blit endEncoding]; if (slot) vx_eye_ring_abort(ring,slot); return XR_ERROR_RUNTIME_FAILURE;
        }
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
            width:(NSUInteger)e->rect.extent.width height:(NSUInteger)e->rect.extent.height mipmapped:NO];
        d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageShaderRead;
        if (!slot) { copies[i]=[h.device newTextureWithDescriptor:d]; if (!copies[i]) { [blit endEncoding]; return XR_ERROR_OUT_OF_MEMORY; } }
        [blit copyFromTexture:src sourceSlice:e->array_layer sourceLevel:0 sourceOrigin:MTLOriginMake(e->rect.offset.x,e->rect.offset.y,0)
            sourceSize:MTLSizeMake(e->rect.extent.width,e->rect.extent.height,1) toTexture:copies[i]
            destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        if (dump) {
            NSUInteger bpr=(NSUInteger)e->rect.extent.width*4;
            dumps[i]=[h.device newBufferWithLength:bpr*(NSUInteger)e->rect.extent.height options:MTLResourceStorageModeShared];
            if (dumps[i]) [blit copyFromTexture:src sourceSlice:e->array_layer sourceLevel:0 sourceOrigin:MTLOriginMake(e->rect.offset.x,e->rect.offset.y,0)
                sourceSize:MTLSizeMake(e->rect.extent.width,e->rect.extent.height,1) toBuffer:dumps[i]
                destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bpr*(NSUInteger)e->rect.extent.height];
        }
    }
    [blit endEncoding];
    if (dk.window) dk_mirror(h.device,cb,copies,slot!=NULL);
    if (slot) {
        /* Non-blocking: the game's ticket is consumed once the copy is committed. Dumps, statistics and the hand-off to
         * native_vr run in the completion handler, from a by-value copy of the pair: nothing borrowed outlives this call.
         * A failed command buffer publishes nothing. Frames publish in order; a stale one is dropped. */
        KlNativeFramePair pc=*pair; id<MTLTexture> c0=copies[0], c1=copies[1]; id<MTLBuffer> d0=dumps[0], d1=dumps[1];
        h.outstanding=NO;
        KlNativeMetalHost metal=h.metal;   /* the swapchain images' own write buffers: checked when this copy completes */
        id<MTLCommandBuffer> w0=(__bridge id<MTLCommandBuffer>)kl_apple_metal_image_pending_writes(&metal,pair->eye[0].image_lease);
        id<MTLCommandBuffer> w1=(__bridge id<MTLCommandBuffer>)kl_apple_metal_image_pending_writes(&metal,pair->eye[1].image_lease);
        vx_eye_ring_commit(ring,cb,slot,^(int ok,double gpu_s) {
            static pthread_mutex_t order=PTHREAD_MUTEX_INITIALIZER; static uint64_t last;
            if (ok && (!vx_eye_ring_writes_ok(w0) || !vx_eye_ring_writes_ok(w1))) ok=0;
            if (!ok) return;
            id<MTLTexture> cs[2]={c0,c1}; id<MTLBuffer> ds[2]={d0,d1};
            pthread_mutex_lock(&order);
            if (pc.sample.frame_id>last) { last=pc.sample.frame_id; (void)finish_pair(h,&pc,cs,ds,keep_files,gpu_s,NO); }
            pthread_mutex_unlock(&order);
        });
        return XR_SUCCESS;
    }
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted || cb.error) return XR_ERROR_RUNTIME_FAILURE;
    return finish_pair(h,pair,copies,dumps,keep_files,cb.GPUEndTime>cb.GPUStartTime ? cb.GPUEndTime-cb.GPUStartTime : 0,YES);
}
int vx_xrizer_dev_host_start(const char *path,unsigned width,unsigned height) {
    if (dev_host || !path || path[0]!='/' || !width || !height || width>4096 || height>4096 ||
        !getenv("XDG_STATE_HOME") || !getenv("XDG_CONFIG_HOME") || !getenv("XDG_CACHE_HOME") || !getenv("XDG_DATA_HOME")) return -1;
    @autoreleasepool {
        VXDevXRHost *h=[VXDevXRHost new]; dev_host=h; /* Keep any installed contexts alive on failure. */
#ifdef VXRT_XRIZER_DEV_AUDIT
        h.audit=getenv("VXRT_XRIZER_DEV_AUDIT") && !strcmp(getenv("VXRT_XRIZER_DEV_AUDIT"),"1");
#endif
        h.syntheticStage=getenv("VXRT_XRIZER_DEV_STAGE") && !strcmp(getenv("VXRT_XRIZER_DEV_STAGE"),"1");
        { const char *dd=getenv("VXRT_XRIZER_DEV_DUMP"); if (dd && dd[0]=='/') h.dumpDir=[NSString stringWithUTF8String:dd]; }
        if (h.syntheticStage) vx_log("xrizer dev host: synthetic stage declared valid (local origin is the floor); development only");
        { const char *k=getenv("VXRT_XRIZER_DEV_KEYBOARD"), *map=getenv("VXRT_XRIZER_DEV_KEYMAP"), *script=getenv("VXRT_XRIZER_DEV_KEY_SCRIPT");
          if (k && *k && strcmp(k,"0")) {
              if (strcmp(k,"1") && strcmp(k,"script")) { vx_log("xrizer dev host: VXRT_XRIZER_DEV_KEYBOARD=%s: expected 1 or script",k); return -1; }
              dk.enabled=1; dk.window=!strcmp(k,"1"); dk.start=now_ns();
              if (dk_parse_map(dk_default_map)) return -1;
              if (map && map[0]=='/') {
                  NSString *text=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:map] encoding:NSUTF8StringEncoding error:NULL];
                  if (!text || dk_parse_map(text.UTF8String)) { vx_log("xrizer dev keyboard: key map file %s unreadable or invalid",map); return -1; }
              } else if (map && dk_parse_map(map)) return -1;
              if (script && dk_parse_script(script)) return -1;
              unsigned bound=0; for (unsigned i=0;i<128;i++) bound+=dk.map[i].control!=0;
              vx_log("xrizer dev keyboard: %s, %u keys bound%s%s, %u scripted key events; diagnostic, not physical input",
                     dk.window ? "mirror window" : "scripted only (no window)",bound,map ? ", key map override " : "",map ? map : "",dk.script_count);
          } else if (script || map) { vx_log("xrizer dev host: VXRT_XRIZER_DEV_KEY_SCRIPT/KEYMAP need VXRT_XRIZER_DEV_KEYBOARD"); return -1; } }
        { const char *c=getenv("VXRT_XRIZER_DEV_CONTROLLERS");
          if ((!c || !*c) && dk.enabled) c="touch";
          if (c && *c && strcmp(c,"0")) {
              if (!strcmp(c,"1") || !strcmp(c,"touch")) h.syntheticControllers=KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH;
              else if (!strcmp(c,"index")) h.syntheticControllers=KL_NATIVE_INPUT_PROFILE_VALVE_INDEX;
              else if (!strcmp(c,"vive")) h.syntheticControllers=KL_NATIVE_INPUT_PROFILE_HTC_VIVE;
              else { vx_log("xrizer dev host: VXRT_XRIZER_DEV_CONTROLLERS=%s: expected 1, touch, index or vive",c); return -1; }
              vx_log("xrizer dev host: synthetic stationary controllers (%s profile), diagnostic, not physical input",
                     h.syntheticControllers==KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH ? "oculus/touch_controller" :
                     h.syntheticControllers==KL_NATIVE_INPUT_PROFILE_VALVE_INDEX ? "valve/index_controller" : "htc/vive_controller");
          } else if (dk.enabled) { vx_log("xrizer dev host: VXRT_XRIZER_DEV_KEYBOARD needs controllers (VXRT_XRIZER_DEV_CONTROLLERS=0 given)"); return -1; } }
        h.width=width; h.height=height; h.device=MTLCreateSystemDefaultDevice(); h.queue=[h.device newCommandQueue];
        h.inputTime=now_ns();
#ifdef VXRT_XRIZER_DEV_AUDIT
        if (!h.audit)
#endif
        if (!vx_eye_ring_sync_requested() && h.device) h.ring=vx_eye_ring_create((__bridge void *)h.device,2,ring_log);
        h.frames=vx_native_vr_create(keep,drop);
        if (!h.device || !h.queue || !h.inputTime || !h.frames) return -1;
        KlNativeMetalHost metal;
        if (kl_apple_metal_host_create((__bridge void *)h.device,(__bridge void *)h.queue,&metal)!=XR_SUCCESS) return -1;
        h.metal=metal; KlNativeImageSyncHost sync;
        if ((h.ring ? kl_apple_metal_image_sync_ordered(&metal,&sync) : kl_apple_metal_image_sync(&metal,&sync))!=XR_SUCCESS) return -1;
        void *ctx=(__bridge void *)h;
        KlNativeHost system={.version=1,.size=sizeof(system),.context=ctx,.hmd_available=available};
        KlNativeViewHost view={KL_NATIVE_VIEW_HOST_VERSION,sizeof(view),ctx,views};
        KlNativeViewGeometryHost geometry={KL_NATIVE_VIEW_GEOMETRY_VERSION,sizeof(geometry),ctx,view_geometry};
        KlNativeSessionHost session={KL_NATIVE_SESSION_HOST_VERSION,sizeof(session),ctx,poll_event,begin_session,end_session,request_exit};
        KlNativeFrameHost frame={KL_NATIVE_FRAME_HOST_VERSION,sizeof(frame),ctx,wait_frame,publish,cancel_frame};
        KlNativeInputHost inputHost={KL_NATIVE_INPUT_HOST_VERSION,sizeof(inputHost),ctx,input};
        KlNativeInputHost3 controllerHost={KL_NATIVE_INPUT_HOST_VERSION_3,sizeof(controllerHost),ctx,synthetic_controllers};
        KlNativeHapticHost hapticHost={KL_NATIVE_HAPTIC_HOST_VERSION,sizeof(hapticHost),ctx,dev_haptic_apply,dev_haptic_stop};
        if (kl_native_configure(&system)!=XR_SUCCESS || kl_native_configure_views(&view)!=XR_SUCCESS ||
            kl_native_configure_view_geometry(&geometry)!=XR_SUCCESS ||
            kl_native_configure_metal(&metal)!=XR_SUCCESS || kl_native_configure_image_sync(&sync)!=XR_SUCCESS ||
            kl_native_configure_session(&session)!=XR_SUCCESS || kl_native_configure_frame(&frame)!=XR_SUCCESS ||
            (h.syntheticControllers ? kl_native_configure_input3(&controllerHost) : kl_native_configure_input(&inputHost))!=XR_SUCCESS ||
            kl_native_configure_haptics(&hapticHost)!=XR_SUCCESS) return -1;
        XrizerMetalHost source;
        if (vx_xrizer_guest_d3d_create((__bridge void *)h.device,(__bridge void *)h.queue,record_destination,ctx,&source)) return -1;
        h.source=source; h.library=dlopen(path,RTLD_NOW|RTLD_LOCAL); if (!h.library) return -1;
        int32_t (*provider)(PFN_xrGetInstanceProcAddr)=dlsym(h.library,"xrizer_configure_openxr_provider");
        int32_t (*graphics)(const XrizerMetalHost *)=dlsym(h.library,"xrizer_configure_metal_host");
        if (!provider || !graphics || !dlsym(h.library,"VRClientCoreFactory") ||
            provider(kl_native_get_instance_proc_addr) || graphics(&source)) return -1;
        h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_READY,now_ns()};
        if (!h.event.time || vx_xrizer_openvr_configure(factory,ctx)) return -1;
        if (dk.window) dk_open_window(h.device,width,height);
        vx_log("xrizer dev host: offscreen synthetic stationary head, %s controllers, %ux%u, CLOCK_MONOTONIC; no physical tracking or display",
               h.syntheticControllers ? "synthetic stationary (diagnostic)" : "disconnected",width,height);
        return 0;
    }
}
#ifdef VXRT_XRIZER_DEV_AUDIT
int vx_xrizer_dev_audit_preframe(void) {
    VXDevXRHost *h=dev_host;
    if (!h || !h.audit || !h.frames || h.nextFrame || h.outstanding || h.published || h.acquired || h.released) return -1;
    vx_log("xrizer dev audit: pre-frame geometry with zero waits/publishes/cancels");
    return 0;
}
int vx_xrizer_dev_audit_acquire(vx_native_vr_frame *out) {
    VXDevXRHost *h=dev_host;
    if (!h || !h.audit || !h.frames || !out || h.acquired!=h.released || h.published!=h.acquired+1) return -1;
    if (vx_native_vr_acquire(h.frames,out)) return -1;
    ++h.acquired;
    int valid=out->pose.frame_id==h.sample.frame_id && out->pose.pose_id==h.sample.pose_id &&
        out->pose.frame_id>h.auditFrame && out->pose.pose_id>h.auditPose;
    if (!valid) { (void)vx_native_vr_release(h.frames,out->lease); ++h.released; return -1; }
    h.auditFrame=out->pose.frame_id; h.auditPose=out->pose.pose_id;
    return 0;
}
int vx_xrizer_dev_audit_release(uint64_t lease) {
    VXDevXRHost *h=dev_host;
    if (!h || !h.audit || !h.frames || h.acquired!=h.released+1 || vx_native_vr_release(h.frames,lease)) return -1;
    ++h.released; return 0;
}
int vx_xrizer_dev_audit_finish(void) {
    VXDevXRHost *h=dev_host; uint64_t acquired=0,released=0,copied=0;
    XrizerMetalHost source=h ? h.source : (XrizerMetalHost){0};
    if (!h || !h.audit || h.frames || h.outstanding || h.published!=2 || h.acquired!=2 || h.released!=2 ||
        h.begins!=1 || h.exits!=1 || h.ends!=1 || vx_xrizer_guest_d3d_counts(&source,&acquired,&released,&copied) ||
        acquired!=released || copied!=4) return -1;
    vx_log("xrizer dev audit: drained pairs %u reader leases %u/%u source leases %llu/%llu copies %llu lifecycle %u/%u/%u",
        h.published,h.acquired,h.released,(unsigned long long)acquired,(unsigned long long)released,(unsigned long long)copied,h.begins,h.exits,h.ends);
    return 0;
}
#endif
