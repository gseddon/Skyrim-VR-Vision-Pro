// Freestanding MSVC guest: what the IVRSystem_019 controller slots return through the actual Windows guest ABI
// bridge and real xrizer, when the offscreen development host reports two stationary synthetic controllers
// (VXRT_XRIZER_DEV_CONTROLLERS=touch; synthetic stage, so Standing is valid, as in the game probes). Fixture only: no game, headset or physical input.
#include "openvr-guest-abi.h"
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, unsigned int, unsigned int *, void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
}
// Freestanding: the compiler's struct zeroing and copies call these.
extern "C" void *memset(void *d, int c, unsigned long long n) { volatile unsigned char *p = (unsigned char *)d; while (n--) *p++ = (unsigned char)c; return d; }
extern "C" void *memcpy(void *d, const void *s, unsigned long long n) { volatile unsigned char *p = (unsigned char *)d; const unsigned char *q = (const unsigned char *)s; while (n--) *p++ = *q++; return d; }
static void check(bool ok, unsigned code) { if (!ok) ExitProcess(code); }
static_assert(sizeof(vr::VRControllerState_t) == 64 && __builtin_offsetof(vr::VRControllerState_t, ulButtonPressed) == 8 &&
              __builtin_offsetof(vr::VRControllerState_t, rAxis) == 24, "Windows VRControllerState001_t");
static_assert(sizeof(vr::TrackedDevicePose_t) == 80, "Windows TrackedDevicePose_t");
static_assert(sizeof(vr::VREvent_t) == 64 && __builtin_offsetof(vr::VREvent_t, data) == 16, "System019 Windows event layout");
static const unsigned long long before_mark = 0x123456789abcdef0ull, after_mark = 0xfedcba9876543210ull;
extern "C" void mainCRTStartup() {
    void *module = LoadLibraryA("openvr_api.dll");
    auto init = (unsigned (*)(int *, int, const char *))GetProcAddress(module, "VR_InitInternal2");
    auto get = (void *(*)(const char *, int *))GetProcAddress(module, "VR_GetGenericInterface");
    auto shutdown = (void (*)())GetProcAddress(module, "VR_ShutdownInternal");
    check(module && init && get && shutdown, 1);
    int error = -1; check(init(&error, 1, nullptr) != 0 && !error, 2);
    auto system = (vr::IVRSystem *)get(vr::IVRSystem_Version, &error); check(system && !error, 3);
    auto comp = (vr::IVRCompositor *)get(vr::IVRCompositor_Version, &error); check(comp && !error, 4);
    // Before the first frame xrizer has not synced input: no controller yet.
    check(!system->IsTrackedDeviceConnected(1) && system->GetTrackedDeviceClass(1) == vr::TrackedDeviceClass_Invalid, 5);
    check(system->IsTrackedDeviceConnected(0) && system->GetTrackedDeviceClass(0) == vr::TrackedDeviceClass_HMD, 6);
    // Frames without a submission (xrizer cancels each): the profile change arrives after an input sync.
    struct { unsigned long long before; vr::TrackedDevicePose_t values[4]; unsigned long long after; } poses = {before_mark, {}, after_mark};
    unsigned activated = 0, frames = 0;
    for (; frames < 12 && activated != 7; ++frames) {
        check(comp->WaitGetPoses(poses.values, 4, nullptr, 0) == 0, 7);
        struct { unsigned long long before; vr::VREvent_t event; unsigned long long after; } e = {before_mark, {}, after_mark};
        while (system->PollNextEvent(&e.event, sizeof e.event)) {
            check(e.before == before_mark && e.after == after_mark, 8);
            if (e.event.eventType == vr::VREvent_TrackedDeviceActivated) { check(e.event.trackedDeviceIndex < 3, 9); activated |= 1u << e.event.trackedDeviceIndex; }
        }
    }
    check(activated == 7, 10);   // HMD, then the two controllers
    check(comp->WaitGetPoses(poses.values, 4, nullptr, 0) == 0 && poses.before == before_mark && poses.after == after_mark, 11);
    unsigned left = system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand);
    unsigned right = system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_RightHand);
    check(left >= 1 && left <= 2 && right >= 1 && right <= 2 && left != right, 12);
    check(system->GetControllerRoleForTrackedDeviceIndex(left) == vr::TrackedControllerRole_LeftHand &&
          system->GetControllerRoleForTrackedDeviceIndex(right) == vr::TrackedControllerRole_RightHand, 13);
    const unsigned hands[2] = {left, right};
    for (unsigned d : hands) {
        check(system->IsTrackedDeviceConnected(d) && system->GetTrackedDeviceClass(d) == vr::TrackedDeviceClass_Controller, 14);
        const vr::TrackedDevicePose_t &p = poses.values[d];
        check(p.bDeviceIsConnected && p.bPoseIsValid && p.eTrackingResult == vr::TrackingResult_Running_OK, 15);
        // Held still below and ahead of the 1.6 m synthetic head, on its side.
        float x = p.mDeviceToAbsoluteTracking.m[0][3], y = p.mDeviceToAbsoluteTracking.m[1][3], z = p.mDeviceToAbsoluteTracking.m[2][3];
        check((d == left ? x < -0.1f : x > 0.1f) && y > 0.9f && y < 1.3f && z < -0.2f && z > -0.6f, 16);
    }
    check(!system->IsTrackedDeviceConnected(3) && !poses.values[3].bDeviceIsConnected, 17);
    // GetControllerState: the guest's 64-byte struct, nothing outside it written; no button pressed or touched, axes at rest.
    struct { unsigned long long before; vr::VRControllerState_t state; unsigned long long after; } s = {before_mark, {}, after_mark};
    unsigned char *raw = (unsigned char *)&s.state;
    for (unsigned i = 0; i < sizeof s.state; ++i) raw[i] = 0x5a;
    check(system->GetControllerState(left, &s.state, sizeof s.state), 18);
    check(s.before == before_mark && s.after == after_mark, 19);
    check(s.state.ulButtonPressed == 0 && s.state.ulButtonTouched == 0, 20);
    for (unsigned a = 0; a < vr::k_unControllerStateAxisCount; ++a) check(s.state.rAxis[a].x == 0 && s.state.rAxis[a].y == 0, 21);
    for (unsigned i = 4; i < 8; ++i) check(raw[i] == 0, 22);   // padding the bridge writes as zero
    // A size the bridge does not know (the Apple struct's 60) is refused with nothing written.
    for (unsigned i = 0; i < sizeof s.state; ++i) raw[i] = 0x5a;
    check(!system->GetControllerState(left, &s.state, 60), 23);
    for (unsigned i = 0; i < sizeof s.state; ++i) check(raw[i] == 0x5a, 24);
    check(!system->GetControllerState(7, &s.state, sizeof s.state), 25);   // not a controller
    struct { unsigned long long before; vr::TrackedDevicePose_t pose; unsigned long long after; } wp = {before_mark, {}, after_mark};
    check(system->GetControllerStateWithPose(vr::TrackingUniverseStanding, right, &s.state, sizeof s.state, &wp.pose), 26);
    check(wp.before == before_mark && wp.after == after_mark && s.before == before_mark && s.after == after_mark, 27);
    check(wp.pose.bPoseIsValid && wp.pose.bDeviceIsConnected && wp.pose.mDeviceToAbsoluteTracking.m[0][3] > 0.1f && s.state.ulButtonPressed == 0, 28);
    // Tracked-device properties: values and the caller's error enum through the bridge.
    vr::ETrackedPropertyError pe = (vr::ETrackedPropertyError)-1;
    check(system->GetInt32TrackedDeviceProperty(left, vr::Prop_Axis0Type_Int32, &pe) == vr::k_eControllerAxis_Joystick && pe == vr::TrackedProp_Success, 29);
    pe = (vr::ETrackedPropertyError)-1;
    check(system->GetInt32TrackedDeviceProperty(5, vr::Prop_Axis0Type_Int32, &pe) == 0 && pe == vr::TrackedProp_InvalidDevice, 30);
    pe = (vr::ETrackedPropertyError)-1;
    check(system->GetUint64TrackedDeviceProperty(left, vr::Prop_SupportedButtons_Uint64, &pe) != 0 && pe == vr::TrackedProp_Success, 31);
    pe = (vr::ETrackedPropertyError)-1;
    float ipd = system->GetFloatTrackedDeviceProperty(0, vr::Prop_UserIpdMeters_Float, &pe);
    // the dev host's 64 mm static optics; xrizer leaves the error untouched on this success path (float return through XMM0)
    check(ipd > 0.0639f && ipd < 0.0641f && pe == (vr::ETrackedPropertyError)-1, 32);
    pe = (vr::ETrackedPropertyError)-1;
    check(!system->GetBoolTrackedDeviceProperty(left, vr::Prop_DeviceIsWireless_Bool, &pe) && pe != (vr::ETrackedPropertyError)-1, 33);
    system->TriggerHapticPulse(left, 0, 500);   // the provider has no haptics; xrizer reports that and returns
    char name[64]; for (unsigned i = 0; i < sizeof name; ++i) name[i] = '?';
    check(system->GetStringTrackedDeviceProperty(left, vr::Prop_ControllerType_String, name, sizeof name, &pe) > 1 && pe == vr::TrackedProp_Success, 34);
    shutdown();
    const char message[] = "xrizer_guest_controllers: synthetic controllers through real xrizer and guest ABI -> ok\n"; unsigned written = 0;
    check(WriteFile(GetStdHandle((unsigned)-11), message, sizeof message - 1, &written, nullptr) && written == sizeof message - 1, 35);
    ExitProcess(0);
}
