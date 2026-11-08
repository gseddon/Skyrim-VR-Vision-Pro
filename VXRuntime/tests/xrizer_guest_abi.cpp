// Actual MSVC-target caller of the pinned classes, not a MinGW C++ approximation.
#include "openvr-guest-abi.h"
typedef unsigned long long u64;
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, unsigned int, unsigned int *, void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
__declspec(dllimport) const char *__stdcall GetCommandLineA(void);
__declspec(dllimport) void __stdcall SetLastError(unsigned int);
__declspec(dllimport) unsigned int __stdcall GetLastError(void);
}
typedef void *(*factory_fn)(const char *, int *);
typedef unsigned int (*init_fn)(int, const char *, int *);
typedef vr::HmdMatrix44_t (*projection_fn)(vr::EVREye, float, float);
typedef vr::HmdMatrix34_t (*transform_fn)(vr::EVREye);
typedef float (*time_fn)();

extern "C" __declspec(noinline) void abi_member_projection(vr::IVRSystem *s, vr::HmdMatrix44_t *out) {
    *out = s->GetProjectionMatrix(vr::Eye_Right, 0.25f, 7.5f);
}
extern "C" __declspec(noinline) void abi_member_transform(vr::IVRSystem *s, vr::HmdMatrix34_t *out) {
    *out = s->GetEyeToHeadTransform(vr::Eye_Left);
}
extern "C" __declspec(noinline) void abi_c_projection(projection_fn f, vr::HmdMatrix44_t *out) {
    *out = f(vr::Eye_Right, 0.25f, 7.5f);
}
extern "C" __declspec(noinline) void abi_c_transform(transform_fn f, vr::HmdMatrix34_t *out) {
    *out = f(vr::Eye_Left);
}
static_assert(sizeof(vr::HmdMatrix44_t) == 64 && sizeof(vr::HmdMatrix34_t) == 48, "matrix layout");
static_assert(alignof(vr::HmdMatrix44_t) == 4 && alignof(vr::HmdMatrix34_t) == 4, "matrix alignment");
template<class T> struct guarded { u64 before; T value; u64 after; };
static const float projection_expected[16] = {
    141.25f, 144.25f, 147.25f, 150.25f, 152.25f, 155.25f, 158.25f, 161.25f,
    163.25f, 166.25f, 169.25f, 172.25f, 174.25f, 177.25f, 180.25f, 183.25f,
};
static const float transform_expected[12] = {-13, -11, -9, -7, -6, -4, -2, 0, 1, 3, 5, 7};
template<class T> static bool intact(const guarded<T> &g) { return g.before == 0x123456789abcdef0ull && g.after == 0xfedcba9876543210ull; }
static void check(bool ok, unsigned int code) { if (!ok) ExitProcess(code); }
static bool equal(const float *a, const float *b, int n) { for (int i = 0; i < n; ++i) if (a[i] != b[i]) return false; return true; }

extern "C" void mainCRTStartup() {
    void *module = LoadLibraryA("vxrt_guest_abi_fixture.dll");
    auto init = (init_fn)GetProcAddress(module, "FixtureInit");
    auto factory = (factory_fn)GetProcAddress(module, "FixtureFactory");
    check(module && init && factory, 1);
    int error = -1;
    SetLastError(0x5a17);
    check(init(9, "owned", &error) == 0 && error == 77, 2);
    check(init(1, "owned", &error) == 0x11223344 && error == 0, 3);
    check(GetLastError() == 0x5a17, 4);
    check(factory("missing", &error) == nullptr && error == 105, 5);
    const char *cmd = GetCommandLineA();
    bool raw = false;
    for (; *cmd; ++cmd) if (*cmd == '@') raw = true;
    auto system = (vr::IVRSystem *)factory(raw ? "Raw:IVRSystem_019" : vr::IVRSystem_Version, &error);
    check(system && error == 0, 6);
    guarded<vr::HmdMatrix44_t> projection = {0x123456789abcdef0ull, {}, 0xfedcba9876543210ull};
    guarded<vr::HmdMatrix34_t> transform = {0x123456789abcdef0ull, {}, 0xfedcba9876543210ull};
    abi_member_projection(system, &projection.value);
    check(!raw, 7); // The unregistered native pointer must stop strict AOT before here.
    check(intact(projection) && equal(&projection.value.m[0][0], projection_expected, 16), 8);
    typedef vr::HmdMatrix44_t *(*explicit_member_fn)(void *, vr::HmdMatrix44_t *, vr::EVREye, float, float);
    auto member = (explicit_member_fn)(*(void ***)system)[1];
    check(member(system, &projection.value, vr::Eye_Right, 0.25f, 7.5f) == &projection.value &&
          intact(projection) && equal(&projection.value.m[0][0], projection_expected, 16), 19);
    abi_member_transform(system, &transform.value);
    check(intact(transform) && equal(&transform.value.m[0][0], transform_expected, 12), 9);
    unsigned int width = 0, height = 0;
    system->GetRecommendedRenderTargetSize(&width, &height);
    check(width == 1920 && height == 1080, 10);
    check(system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand) == 17 &&
          system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_RightHand) == 29, 11);
    auto compositor = (vr::IVRCompositor *)factory(vr::IVRCompositor_Version, &error);
    check(compositor && error == 0 && compositor->GetFrameTimeRemaining() == 13.625f, 12);
    auto system_fns = (void **)factory("FnTable:IVRSystem_019", &error);
    check(system_fns && error == 0, 13);
    abi_c_projection((projection_fn)system_fns[1], &projection.value);
    check(intact(projection) && equal(&projection.value.m[0][0], projection_expected, 16), 14);
    typedef vr::HmdMatrix44_t *(*explicit_c_fn)(vr::HmdMatrix44_t *, vr::EVREye, float, float);
    check(((explicit_c_fn)system_fns[1])(&projection.value, vr::Eye_Right, 0.25f, 7.5f) == &projection.value &&
          intact(projection) && equal(&projection.value.m[0][0], projection_expected, 16), 20);
    abi_c_transform((transform_fn)system_fns[4], &transform.value);
    check(intact(transform) && equal(&transform.value.m[0][0], transform_expected, 12), 15);
    auto compositor_fns = (void **)factory("FnTable:IVRCompositor_022", &error);
    check(compositor_fns && error == 0 && ((time_fn)compositor_fns[10])() == 13.625f, 16);
    check(GetLastError() == 0x5a17, 17);
    const char message[] = "xrizer_guest_abi: MSVC member/C FnTable scalar/float/matrix -> ok\n";
    unsigned int written = 0;
    check(WriteFile(GetStdHandle((unsigned int)-11), message, sizeof message - 1, &written, nullptr) && written == sizeof message - 1, 18);
    ExitProcess(0);
}
