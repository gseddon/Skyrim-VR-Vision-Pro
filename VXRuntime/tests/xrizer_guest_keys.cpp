// Freestanding MSVC guest: a scripted key sequence of the development keyboard (VXRT_XRIZER_DEV_KEYBOARD=script,
// VXRT_XRIZER_DEV_KEY_SCRIPT in frames, one VXRT_XRIZER_DEV_KEYMAP override) reaches IVRSystem_019 GetControllerState
// as the expected Windows VRControllerState_t bits and axes, through the dev host's synthetic Oculus Touch controllers,
// the provider, real xrizer's legacy input and the Windows guest ABI bridge; head keys turn the HMD pose and the
// controllers with it. Fixture only: no game, headset or physical input. Script and expectations: xrizer_guest_keys_check.py.
#include "openvr-guest-abi.h"
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, unsigned int, unsigned int *, void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
}
extern "C" void *memset(void *d, int c, unsigned long long n) { volatile unsigned char *p = (unsigned char *)d; while (n--) *p++ = (unsigned char)c; return d; }
extern "C" void *memcpy(void *d, const void *s, unsigned long long n) { volatile unsigned char *p = (unsigned char *)d; const unsigned char *q = (const unsigned char *)s; while (n--) *p++ = *q++; return d; }
static void check(bool ok, unsigned code) { if (!ok) ExitProcess(code); }
static_assert(sizeof(vr::VRControllerState_t) == 64, "Windows VRControllerState001_t");
static const unsigned long long before_mark = 0x123456789abcdef0ull, after_mark = 0xfedcba9876543210ull;
static unsigned long long bit(vr::EVRButtonId id) { return 1ull << id; }
static bool near(float a, float b) { float d = a - b; return d < 0.01f && d > -0.01f; }
// One expected (left, right) state: pressed masks and the stick / trigger / squeeze axes.
struct Expect { unsigned long long pressed[2]; float stick[2][2], trigger[2], squeeze[2]; };
static bool matches(const vr::VRControllerState_t s[2], const Expect &e) {
    for (unsigned h = 0; h < 2; ++h)
        if (s[h].ulButtonPressed != e.pressed[h] || s[h].ulButtonTouched != 0 || !near(s[h].rAxis[0].x, e.stick[h][0]) ||
            !near(s[h].rAxis[0].y, e.stick[h][1]) || !near(s[h].rAxis[1].x, e.trigger[h]) || !near(s[h].rAxis[2].x, e.squeeze[h])) return false;
    return true;
}
extern "C" void mainCRTStartup() {
    void *module = LoadLibraryA("openvr_api.dll");
    auto init = (unsigned (*)(int *, int, const char *))GetProcAddress(module, "VR_InitInternal2");
    auto get = (void *(*)(const char *, int *))GetProcAddress(module, "VR_GetGenericInterface");
    auto shutdown = (void (*)())GetProcAddress(module, "VR_ShutdownInternal");
    check(module && init && get && shutdown, 1);
    int error = -1; check(init(&error, 1, nullptr) != 0 && !error, 2);
    auto system = (vr::IVRSystem *)get(vr::IVRSystem_Version, &error); check(system && !error, 3);
    auto comp = (vr::IVRCompositor *)get(vr::IVRCompositor_Version, &error); check(comp && !error, 4);
    const unsigned long long trigger = bit(vr::k_EButton_SteamVR_Trigger), grip = bit(vr::k_EButton_Grip) | bit(vr::k_EButton_Axis2),
        a = bit(vr::k_EButton_A), menu = bit(vr::k_EButton_ApplicationMenu), click = bit(vr::k_EButton_SteamVR_Touchpad);
    const float d = 0.70710678f;
    // In script order (frames, see the check script); each phase's keys are released before the next.
    const Expect phases[] = {
        {{0, 0}, {{0, 0}, {0, 0}}, {0, 0}, {0, 0}},                                   // at rest
        {{trigger, 0}, {{0, 1}, {0, 0}}, {1, 0}, {0, 0}},                             // q+w: left trigger, left stick up
        {{0, trigger | a}, {{0, 0}, {0, 0}}, {0, 1}, {0, 0}},                         // space+e: right trigger, right A
        {{a | menu | grip, 0}, {{0, 0}, {0, 0}}, {0, 0}, {1, 0}},                     // tab+j+r: left X, Y, grip
        {{0, menu | grip}, {{0, 0}, {1, 0}}, {0, 0}, {0, 1}},                         // f+z+right: right B, grip, stick right
        {{click, 0}, {{-d, -d}, {0, 0}}, {0, 0}, {0, 0}},                             // lshift+a+s: left click, stick down-left
        {{0, trigger}, {{0, 0}, {0, 0}}, {0, 1}, {0, 0}},                             // x, mapped by the override to right.trigger
        {{0, 0}, {{0, 0}, {0, 0}}, {0, 0}, {0, 0}},                                   // at rest again
    };
    const unsigned count = sizeof phases / sizeof phases[0];
    unsigned phase = 0, frames = 0, left = 0, right = 0;
    struct { unsigned long long before; vr::TrackedDevicePose_t values[3]; unsigned long long after; } poses = {before_mark, {}, after_mark};
    struct { unsigned long long before; vr::VRControllerState_t s[2]; unsigned long long after; } st = {before_mark, {}, after_mark};
    bool rest_between = true;
    for (; frames < 400 && phase < count; ++frames) {
        check(comp->WaitGetPoses(poses.values, 3, nullptr, 0) == 0 && poses.before == before_mark && poses.after == after_mark, 5);
        vr::VREvent_t e; while (system->PollNextEvent(&e, sizeof e)) {}
        if (!left) {
            left = system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand);
            right = system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_RightHand);
            if (left > 2 || right > 2 || !left || !right) { left = 0; continue; }
        }
        check(system->GetControllerState(left, &st.s[0], sizeof st.s[0]) && system->GetControllerState(right, &st.s[1], sizeof st.s[1]), 6);
        check(st.before == before_mark && st.after == after_mark, 7);
        bool rest = matches(st.s, phases[0]);
        // A phase counts once its exact state is seen after the previous one was released.
        if (rest_between && matches(st.s, phases[phase])) { ++phase; rest_between = phase == 1 || phase == count; }
        else if (rest) rest_between = true;
        else if (phase > 0 && !matches(st.s, phases[phase - 1])) {
            // Something other than the current or previous phase: a wrong mapping (or a transition frame, allowed once).
            static unsigned odd; check(++odd <= 12, 100 + phase);
        }
    }
    check(phase == count, 40 + phase);
    // Head: [ held for f45 at 90 deg/s turns the head ~45 degrees left; its forward (-Z column) points left (x < 0),
    // the controllers turned with it. Then Home resets it, and a few frames more let the script's last release happen.
    float hx = 0, cx = 0; bool turned = false, reset = false;
    for (unsigned f = 0; f < 200 && !(turned && reset); ++f) {
        check(comp->WaitGetPoses(poses.values, 3, nullptr, 0) == 0, 8);
        vr::VREvent_t e; while (system->PollNextEvent(&e, sizeof e)) {}
        hx = -poses.values[0].mDeviceToAbsoluteTracking.m[0][2]; cx = -poses.values[left].mDeviceToAbsoluteTracking.m[0][2];
        if (!turned && hx < -0.5f && cx < -0.4f && poses.values[0].bPoseIsValid) turned = true;
        if (turned && near(hx, 0) && near(cx, 0)) reset = true;
    }
    check(turned, 60); check(reset, 61);
    for (unsigned f = 0; f < 10; ++f) { check(comp->WaitGetPoses(poses.values, 3, nullptr, 0) == 0, 10); vr::VREvent_t e; while (system->PollNextEvent(&e, sizeof e)) {} }
    shutdown();
    const char message[] = "xrizer_guest_keys: scripted dev keyboard through real xrizer and guest ABI -> ok\n"; unsigned written = 0;
    check(WriteFile(GetStdHandle((unsigned)-11), message, sizeof message - 1, &written, nullptr) && written == sizeof message - 1, 9);
    ExitProcess(0);
}
