// Owned negative fixture: unimplemented System019 slot must stop with real AOT counters.
#include "openvr-guest-abi.h"
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall ExitProcess(unsigned int);
}
extern "C" void mainCRTStartup() {
    void *module=LoadLibraryA("openvr_api.dll");
    auto init=(unsigned (*)(int *,int,const char *))GetProcAddress(module,"VR_InitInternal2");
    auto get=(void *(*)(const char *,int *))GetProcAddress(module,"VR_GetGenericInterface");
    if (!module || !init || !get) ExitProcess(1);
    int error=-1; if (!init(&error,1,nullptr) || error) ExitProcess(2);
    auto system=(vr::IVRSystem *)get(vr::IVRSystem_Version,&error);
    if (!system || error) ExitProcess(3);
    (void)system->GetD3D9AdapterIndex(); // Unsupported System019 slot 6.
    ExitProcess(99); // Reaching this is failure; no success sentinel.
}
