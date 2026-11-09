// XInput on the Game Controller framework: the first four controllers with an extended gamepad profile (Xbox,
// PlayStation, Switch Pro, a pair of Joy-Cons and others macOS knows) are XInput users 0..3.
#import <GameController/GameController.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include "vx.h"
#include "ui.h"

#define ERROR_DEVICE_NOT_CONNECTED 1167
typedef struct { uint16_t buttons; uint8_t left_trigger, right_trigger; int16_t lx, ly, rx, ry; } GAMEPAD;
typedef struct { DWORD packet; GAMEPAD pad; } STATE;

static uint32_t g_packets[4];
static GAMEPAD g_last[4];

static GCExtendedGamepad *gamepad(DWORD user) {
    // macOS gives controller input only to the frontmost app unless asked: a game played in a headset is seldom
    // the Mac's frontmost window.
    // The framework finds the controllers a moment after it is first used, and a game that is told no pad is there
    // when it first asks may never ask again (Elite Dangerous): the first call waits up to 1.5 s for them, and a
    // controller connected later is announced as Windows does, with WM_DEVICECHANGE (DBT_DEVNODES_CHANGED).
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(macOS 11.3, *)) GCController.shouldMonitorBackgroundEvents = YES;
        if (!NSThread.isMainThread) for (int i = 0; i < 30 && !GCController.controllers.count; i++) usleep(50000);
    });
    DWORD n = 0;
    for (GCController *c in GCController.controllers) {
        if (!c.extendedGamepad) continue;
        if (n++ == user) return c.extendedGamepad;
    }
    return nil;
}

// VXRT_XINPUT_SCRIPT="<start s>:<buttons>:<hold s>[,...]": a scripted gamepad for testing (a game that waits for a button
// press with no controller attached). Buttons are names joined by '+' (A B X Y START BACK LB RB UP DOWN LEFT RIGHT LS RS) or a
// number; times count from the start of the process. With no real controller the script is XInput user 0, connected all along,
// with nothing pressed between its entries; with a real one its presses are added to the real state.
typedef struct { double start, hold; uint16_t buttons; } script_entry;
static script_entry g_script[64]; static int g_nscript; static struct timespec g_t0; static int g_script_on;
static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)(t.tv_sec - g_t0.tv_sec) + (double)(t.tv_nsec - g_t0.tv_nsec) / 1e9; }
static uint16_t script_button(const char *name, size_t n) {
    static const struct { const char *name; uint16_t bit; } names[] = { {"UP",1}, {"DOWN",2}, {"LEFT",4}, {"RIGHT",8}, {"START",0x10}, {"BACK",0x20}, {"LS",0x40}, {"RS",0x80},
                                                                        {"LB",0x100}, {"RB",0x200}, {"A",0x1000}, {"B",0x2000}, {"X",0x4000}, {"Y",0x8000} };
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) if (strlen(names[i].name) == n && !strncasecmp(names[i].name, name, n)) return names[i].bit;
    return 0;
}
__attribute__((constructor)) static void script_init(void) {
    clock_gettime(CLOCK_MONOTONIC, &g_t0);
    const char *spec = getenv("VXRT_XINPUT_SCRIPT");
    if (!spec) return;
    while (*spec && g_nscript < 64) {
        char *e; double start = strtod(spec, &e);
        if (e == spec || *e != ':') break;
        const char *b = e + 1; uint16_t mask = 0;
        if (*b >= '0' && *b <= '9') mask = (uint16_t)strtoul(b, &e, 0);
        else { for (e = (char *)b; ; ) { const char *s = e; while (*e && *e != '+' && *e != ':') e++; mask |= script_button(s, (size_t)(e - s)); if (*e != '+') break; e++; } }
        if (*e != ':') break;
        double hold = strtod(e + 1, &e);
        g_script[g_nscript++] = (script_entry){ start, hold, mask };
        if (*e == ',') e++;
        spec = e;
    }
    g_script_on = g_nscript > 0;
    if (g_script_on) vx_log("XInput script: %d entr%s (first %.2f s, buttons %#x, hold %.2f s)", g_nscript, g_nscript == 1 ? "y" : "ies", g_script[0].start, g_script[0].buttons, g_script[0].hold);
}
static uint16_t script_buttons(void) {
    if (!g_script_on) return 0;
    double t = now_s(); uint16_t m = 0; static int announced = -1;
    int active = -1;
    for (int i = 0; i < g_nscript; i++) if (t >= g_script[i].start && t < g_script[i].start + g_script[i].hold) { m |= g_script[i].buttons; active = i; }
    if (active != announced) { announced = active; vx_log("XInput script: %s at %.1f s (buttons %#x)", active >= 0 ? "pressed" : "released", t, m); }
    return m;
}
static int16_t axis(float v) { return (int16_t)(v < -1 ? -32768 : v > 1 ? 32767 : v < 0 ? v * 32768 : v * 32767); }

static void trace_calls(DWORD user) {
    static int on = -1; static unsigned calls;
    if (on < 0) on = getenv("VXRT_TRACE_INPUT") != NULL;
    if (!on || __sync_add_and_fetch(&calls, 1) % 600 != 1) return;
    NSMutableString *names = [NSMutableString string];
    for (GCController *c in GCController.controllers)
        [names appendFormat:@" [%@%s]", c.vendorName ?: @"?", c.extendedGamepad ? "" : ", no extended profile"];
    vx_log("XInput: %u calls (user %u now); macOS shows %lu controller(s):%s", calls, (unsigned)user,
           (unsigned long)GCController.controllers.count, names.length ? names.UTF8String : " none");
}
static WINAPI DWORD XInputGetState(DWORD user, STATE *state) {
    trace_calls(user);
    if (user > 3) return 87;
    GCExtendedGamepad *g = gamepad(user);
    if (!g && !(user == 0 && g_script_on)) return ERROR_DEVICE_NOT_CONNECTED;
    GAMEPAD p = { 0 };
    if (!g) {                                                           // the scripted pad
        p.buttons = script_buttons();
        if (memcmp(&p, &g_last[0], sizeof p)) { g_last[0] = p; g_packets[0]++; }
        state->packet = g_packets[0]; state->pad = p;
        return 0;
    }
    if (g.dpad.up.pressed) p.buttons |= 0x0001;
    if (g.dpad.down.pressed) p.buttons |= 0x0002;
    if (g.dpad.left.pressed) p.buttons |= 0x0004;
    if (g.dpad.right.pressed) p.buttons |= 0x0008;
    if (g.buttonMenu.pressed) p.buttons |= 0x0010;                      // START
    if (g.buttonOptions.pressed) p.buttons |= 0x0020;                   // BACK
    if (g.leftThumbstickButton.pressed) p.buttons |= 0x0040;
    if (g.rightThumbstickButton.pressed) p.buttons |= 0x0080;
    if (g.leftShoulder.pressed) p.buttons |= 0x0100;
    if (g.rightShoulder.pressed) p.buttons |= 0x0200;
    if (g.buttonA.pressed) p.buttons |= 0x1000;
    if (g.buttonB.pressed) p.buttons |= 0x2000;
    if (g.buttonX.pressed) p.buttons |= 0x4000;
    if (g.buttonY.pressed) p.buttons |= 0x8000;
    p.left_trigger = (uint8_t)(g.leftTrigger.value * 255.0f + 0.5f);
    p.right_trigger = (uint8_t)(g.rightTrigger.value * 255.0f + 0.5f);
    p.lx = axis(g.leftThumbstick.xAxis.value); p.ly = axis(g.leftThumbstick.yAxis.value);   // both y axes point up, as in XInput
    p.rx = axis(g.rightThumbstick.xAxis.value); p.ry = axis(g.rightThumbstick.yAxis.value);
    if (memcmp(&p, &g_last[user], sizeof p)) {
        if (!g_packets[user]) vx_log("XInput user %u: %s", (unsigned)user, g.controller.vendorName.UTF8String ?: "a controller");
        if (getenv("VXRT_TRACE_INPUT")) vx_log("XInput user %u: buttons %#x triggers %u %u sticks %d %d %d %d", (unsigned)user, p.buttons,
                                               p.left_trigger, p.right_trigger, p.lx, p.ly, p.rx, p.ry);
        g_last[user] = p; g_packets[user]++;
    }
    if (user == 0) p.buttons |= script_buttons();
    state->packet = g_packets[user];
    state->pad = p;
    return 0;
}
// Rumble needs the controller's haptics engine; accepted without effect for now.
static WINAPI DWORD XInputSetState(DWORD user, void *vibration) { (void)vibration; return gamepad(user) || (user == 0 && g_script_on) ? 0 : ERROR_DEVICE_NOT_CONNECTED; }
// XINPUT_CAPABILITIES: type, subtype, flags, the gamepad's ranges, vibration.
static WINAPI DWORD XInputGetCapabilities(DWORD user, DWORD flags, uint8_t *caps) {
    (void)flags;
    GCExtendedGamepad *pad = gamepad(user);
    if (getenv("VXRT_TRACE_INPUT")) { static volatile int calls; if (__sync_add_and_fetch(&calls, 1) <= 20) vx_log("XInputGetCapabilities(%u): %s", (unsigned)user, pad ? "a pad" : "none"); }
    if (!pad && !(user == 0 && g_script_on)) return ERROR_DEVICE_NOT_CONNECTED;
    memset(caps, 0, 20);
    caps[0] = 1; caps[1] = 1;                                           // XINPUT_DEVTYPE_GAMEPAD, XINPUT_DEVSUBTYPE_GAMEPAD
    GAMEPAD *g = (GAMEPAD *)(caps + 4);
    g->buttons = 0xf3ff; g->left_trigger = g->right_trigger = 255;
    g->lx = g->ly = g->rx = g->ry = (int16_t)0xffc0;
    return 0;
}
static WINAPI void XInputEnable(int enable) { (void)enable; }
// XINPUT_BATTERY_INFORMATION: type, level.
static WINAPI DWORD XInputGetBatteryInformation(DWORD user, uint8_t type, uint8_t *info) {
    (void)type;
    GCExtendedGamepad *g = gamepad(user);
    if (!g && user == 0 && g_script_on) { info[0] = 1; info[1] = 3; return 0; }
    if (!g) return ERROR_DEVICE_NOT_CONNECTED;
    GCDeviceBattery *b = g.controller.battery;
    info[0] = b ? 2 : 1;                                                // BATTERY_TYPE_ALKALINE-like / wired
    info[1] = !b ? 3 : b.batteryLevel > 0.7 ? 3 : b.batteryLevel > 0.3 ? 2 : b.batteryLevel > 0.05 ? 1 : 0;
    return 0;
}
static WINAPI DWORD XInputGetKeystroke(DWORD user, DWORD reserved, void *keystroke) { (void)reserved; (void)keystroke; return gamepad(user) || (user == 0 && g_script_on) ? 4306 /* ERROR_EMPTY */ : ERROR_DEVICE_NOT_CONNECTED; }

static const vx_export xinput[] = {
    VX_EXPORT(XInputGetState), VX_EXPORT(XInputSetState), VX_EXPORT(XInputGetCapabilities), VX_EXPORT(XInputEnable),
    VX_EXPORT(XInputGetBatteryInformation), VX_EXPORT(XInputGetKeystroke),
    { "#100", (void *)XInputGetState },                                // XInputGetStateEx (adds the guide button)
};
// Ordinals belong to a particular DLL version, unlike the shared name table.
static const vx_export xinput13_ordinals[] = {
    { "#2", (void *)XInputGetState },
    { "#3", (void *)XInputSetState },
    { "#4", (void *)XInputGetCapabilities },
};
void vx_input_init(void) {
    // the framework starts looking for controllers now, and one connected later is announced to the windows
    if (@available(macOS 11.3, *)) GCController.shouldMonitorBackgroundEvents = YES;
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) {
        GCController *c = n.object;
        vx_log("XInput: %s connected; telling the windows (WM_DEVICECHANGE)", c.vendorName.UTF8String ?: "a controller");
        vx_window_post_all(0x0219, 0x0007, 0);                         // DBT_DEVNODES_CHANGED
    }];
    (void)GCController.controllers;
    vx_register_module("xinput1_4.dll", xinput, sizeof xinput / sizeof xinput[0]);
    vx_register_module("xinput1_3.dll", xinput, sizeof xinput / sizeof xinput[0]);
    vx_register_module("xinput1_3.dll", xinput13_ordinals, sizeof xinput13_ordinals / sizeof xinput13_ordinals[0]);
    vx_register_module("xinput9_1_0.dll", xinput, sizeof xinput / sizeof xinput[0]);
    vx_register_module("xinput1_2.dll", xinput, sizeof xinput / sizeof xinput[0]);
    vx_register_module("xinput1_1.dll", xinput, sizeof xinput / sizeof xinput[0]);
}

#ifdef __aarch64__
#include "thunks/input.m.inc"
#endif
