// MSVC guest -> static wrappers -> real xrizer -> owned native Metal provider.
#include "openvr-guest-abi.h"
#include "ivrclientcore_003.h"
typedef unsigned long long u64;
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, unsigned int, unsigned int *, void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
}
typedef void *(*factory_fn)(int *);
typedef int (*verify_fn)(int);
typedef int (*finish_fn)();
typedef vr::HmdMatrix44_t (*projection_fn)(vr::EVREye, float, float);
typedef vr::HmdMatrix34_t (*transform_fn)(vr::EVREye);
template<class T> struct guarded { u64 before; T value; u64 after; };
static void check(bool ok, unsigned int code) { if (!ok) ExitProcess(code); }
template<class T> static void check_guard(const guarded<T> &g) { check(g.before == 0x123456789abcdef0ull && g.after == 0xfedcba9876543210ull, 40); }
static void near(float a, float b) { const float d = a - b; check(d > -0.00003f && d < 0.00003f, 41); }
// Independently calculated from the owned host's asymmetric eye-edge angles,
// D3D near .25/far 7.5, parallel eye axes and +/-32 mm eye offsets.
static const float projections[2][16] = {
    {1.068417768f,0,.100084129f,0, 0,1.028650474f,.296262348f,0, 0,0,-1.034482759f,-.258620690f, 0,0,-1,0},
    {1.016967466f,0,.089897988f,0, 0,1.028650474f,.296262348f,0, 0,0,-1.034482759f,-.258620690f, 0,0,-1,0},
};
static void projection(const vr::HmdMatrix44_t &p, int eye) { for (int i = 0; i < 16; ++i) near((&p.m[0][0])[i], projections[eye][i]); }
static void transform(const vr::HmdMatrix34_t &p, int eye) {
    const float expected[12] = {1,0,0,eye ? .032f : -.032f, 0,1,0,0, 0,0,1,0};
    for (int i = 0; i < 12; ++i) near((&p.m[0][0])[i], expected[i]);
}
extern "C" void mainCRTStartup() {
    void *module = LoadLibraryA("vxrt_guest_join_fixture.dll");
    auto factory = (factory_fn)GetProcAddress(module, "FixtureGetClientCore");
    auto verify = (verify_fn)GetProcAddress(module, "FixtureVerify");
    auto finish = (finish_fn)GetProcAddress(module, "FixtureFinish");
    check(module && factory && verify && finish, 1);
    int factory_error = -1;
    auto core = (vr::IVRClientCore *)factory(&factory_error);
    check(core && factory_error == 0, 2);
    check(core->Init(vr::VRApplication_Scene, nullptr) == vr::VRInitError_None, 3);
    check(core->BIsHmdPresent(), 4);
    vr::EVRInitError error = (vr::EVRInitError)-1;
    auto system = (vr::IVRSystem *)core->GetGenericInterface(vr::IVRSystem_Version, &error);
    check(system && error == 0, 5);
    auto compositor = (vr::IVRCompositor *)core->GetGenericInterface(vr::IVRCompositor_Version, &error);
    check(compositor && error == 0, 6);
    unsigned int width = 0, height = 0;
    system->GetRecommendedRenderTargetSize(&width, &height);
    check(width == 8 && height == 8, 7);
    check(!system->IsInputAvailable(), 13);
    guarded<vr::TrackedDevicePose_t> refused = {0x123456789abcdef0ull, {}, 0xfedcba9876543210ull};
    auto bytes = (unsigned char *)&refused.value;
    for (unsigned int i = 0; i < sizeof refused.value; ++i) bytes[i] = 0x5a;
    check(compositor->WaitGetPoses(&refused.value, 1, nullptr, 0) == vr::VRCompositorError_RequestFailed, 14);
    check(compositor->GetLastPoses(&refused.value, 1, nullptr, 0) == vr::VRCompositorError_RequestFailed, 15);
    check(compositor->GetLastPoseForTrackedDeviceIndex(0, &refused.value, nullptr) == vr::VRCompositorError_RequestFailed, 16);
    check_guard(refused);
    for (unsigned int i = 0; i < sizeof refused.value; ++i) check(bytes[i] == 0x5a, 17);
    check(verify(-1) == 0, 18);
    check(compositor->WaitGetPoses(nullptr, 0, nullptr, 0) == vr::VRCompositorError_None, 8);
    auto fns = (void **)core->GetGenericInterface("FnTable:IVRSystem_019", &error);
    check(fns && error == 0, 9);
    for (int e = 0; e < 2; ++e) {
        auto eye = (vr::EVREye)e;
        guarded<vr::HmdMatrix44_t> p = {0x123456789abcdef0ull, {}, 0xfedcba9876543210ull};
        guarded<vr::HmdMatrix34_t> t = {0x123456789abcdef0ull, {}, 0xfedcba9876543210ull};
        p.value = system->GetProjectionMatrix(eye, .25f, 7.5f); check_guard(p); projection(p.value, e);
        t.value = system->GetEyeToHeadTransform(eye); check_guard(t); transform(t.value, e);
        p.value = ((projection_fn)fns[1])(eye, .25f, 7.5f); check_guard(p); projection(p.value, e);
        t.value = ((transform_fn)fns[4])(eye); check_guard(t); transform(t.value, e);
    }
    // Actual empty-layer handoff consumes this frame ticket without a picture.
    compositor->PostPresentHandoff();
    check(verify(0) == 0, 10);
    core->Cleanup();
    check(verify(1) == 0 && finish() == 0, 11);
    const char message[] = "xrizer_guest_join: actual provider Init0/System019 matrices/empty-frame cancellation -> ok\n";
    unsigned int written = 0;
    check(WriteFile(GetStdHandle((unsigned int)-11), message, sizeof message - 1, &written, nullptr) && written == sizeof message - 1, 12);
    ExitProcess(0);
}
