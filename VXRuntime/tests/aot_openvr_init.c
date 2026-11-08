// Exercise direct imports and dynamic lookup of the same owned API exports.
#include <windows.h>
#include <stdint.h>

__declspec(dllimport) uint32_t VR_InitInternal(int *, int);
__declspec(dllimport) uint32_t VR_InitInternal2(int *, int, const char *);
__declspec(dllimport) uint32_t VR_GetInitToken(void);
__declspec(dllimport) uint8_t VR_IsInterfaceVersionValid(const char *);
__declspec(dllimport) void *VR_GetGenericInterface(const char *, int *);
__declspec(dllimport) void VR_ShutdownInternal(void);
__declspec(dllimport) void *OwnedMarker(void);

void mainCRTStartup(void) {
    int error = -1;
    if (VR_InitInternal(&error, 1) != 0x101 || error != 11 || GetLastError() != 0x601) ExitProcess(1);
    if (VR_InitInternal2(&error, 2, "owned") != 0x202 || error != 23 || GetLastError() != 0x602) ExitProcess(2);
    if (VR_GetInitToken() != 0x202 || GetLastError() != 0x603) ExitProcess(3);
    if (VR_IsInterfaceVersionValid("IVRSystem_019") != 1 || GetLastError() != 0x604) ExitProcess(4);
    if (VR_IsInterfaceVersionValid("bad") != 0 || GetLastError() != 0x604) ExitProcess(5);
    void *expected = OwnedMarker();
    if (VR_GetGenericInterface("IVRSystem_019", &error) != expected || error != 31 || GetLastError() != 0x605) ExitProcess(6);
    HMODULE module = GetModuleHandleW(L"openvr_api.dll");
    typedef void *(*interface_fn)(const char *, int *);
    interface_fn dynamic = (interface_fn)GetProcAddress(module, "VR_GetGenericInterface");
    if (!dynamic || (void *)dynamic != (void *)VR_GetGenericInterface) ExitProcess(7);
    if (dynamic("IVRSystem_019", &error) != expected || error != 31 || GetLastError() != 0x605) ExitProcess(8);
    if (dynamic("bad", &error) != NULL || error != 31 || GetLastError() != 0x605) ExitProcess(9);
    VR_ShutdownInternal();
    if (GetLastError() != 0x606 || VR_GetInitToken() != 0) ExitProcess(10);
    const char message[] = "aot_openvr_init: ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof message - 1, &written, NULL) ||
        written != sizeof message - 1) ExitProcess(11);
    ExitProcess(0);
}
