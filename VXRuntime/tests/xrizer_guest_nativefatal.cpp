// Owned guest calls one native fatal control; it must never return.
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
}
extern "C" void mainCRTStartup() {
    void *module=LoadLibraryA("vxrt_guest_nativefatal_fixture.dll");
    auto trigger=(void (*)())GetProcAddress(module,"TriggerNativeFatal");
    if (!module || !trigger) ExitProcess(1);
    trigger(); ExitProcess(99);
}
