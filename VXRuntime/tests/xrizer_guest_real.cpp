// Actual MSVC guest calls to real xrizer's native ClientCore through static thunks.
#include "openvr-guest-abi.h"
#include "ivrclientcore_003.h"
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, unsigned int, unsigned int *, void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
__declspec(dllimport) void __stdcall SetLastError(unsigned int);
__declspec(dllimport) unsigned int __stdcall GetLastError(void);
}
typedef void *(*factory_fn)(int *);
static void check(bool ok, unsigned int code) { if (!ok) ExitProcess(code); }
extern "C" void mainCRTStartup() {
    void *module = LoadLibraryA("vxrt_guest_real_fixture.dll");
    auto factory = (factory_fn)GetProcAddress(module, "FixtureGetClientCore");
    check(module && factory, 1);
    int error = -1;
    auto core = (vr::IVRClientCore *)factory(&error);
    check(core && error == 0, 2);
    SetLastError(0x6a19);
    check(core->IsInterfaceVersionValid(vr::IVRSystem_Version) == vr::VRInitError_None, 3);
    check(core->IsInterfaceVersionValid(vr::IVRCompositor_Version) == vr::VRInitError_None, 4);
    check(core->IsInterfaceVersionValid("IVRSystem_999") == vr::VRInitError_Init_InvalidInterface, 5);
    check(!core->BIsHmdPresent(), 6);
    check(core->Init((vr::EVRApplicationType)99, nullptr) == vr::VRInitError_Init_InvalidApplicationType, 11);
    // xrizer's current header names 150 VRServiceStartupFailed; this older
    // System019-era header predates that enum value. Preserve the actual code.
    check((int)core->Init(vr::VRApplication_Scene, nullptr) == 150, 7);
    check(!core->BIsHmdPresent(), 8);
    check(GetLastError() == 0x6a19, 9);
    // Failed init has no session to clean up. The real backend's error is kept.
    const char message[] = "xrizer_guest_real: real factory/version/bool/Init150 through MSVC guest thunks -> ok\n";
    unsigned int written = 0;
    check(WriteFile(GetStdHandle((unsigned int)-11), message, sizeof message - 1, &written, nullptr) && written == sizeof message - 1, 10);
    ExitProcess(0);
}
