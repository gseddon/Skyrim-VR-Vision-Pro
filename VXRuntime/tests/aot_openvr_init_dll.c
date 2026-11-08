// Owned passthrough control only; never a game runtime or game search input.
#include <windows.h>
#include <stdint.h>

static uint32_t token;
static uint64_t marker = UINT64_C(0x123456789abcdef0);
__declspec(dllexport) uint32_t VR_InitInternal(int *error, int type) {
    if (error) *error = 11;
    SetLastError(0x601);
    return token = 0x100 + (uint32_t)type;
}
__declspec(dllexport) uint32_t VR_InitInternal2(int *error, int type, const char *startup) {
    if (error) *error = startup && startup[0] == 'o' ? 23 : 24;
    SetLastError(0x602);
    return token = 0x200 + (uint32_t)type;
}
__declspec(dllexport) uint32_t VR_GetInitToken(void) { SetLastError(0x603); return token; }
__declspec(dllexport) uint8_t VR_IsInterfaceVersionValid(const char *version) {
    SetLastError(0x604);
    return version && version[0] == 'I';
}
__declspec(dllexport) void *VR_GetGenericInterface(const char *version, int *error) {
    if (error) *error = 31;
    SetLastError(0x605);
    return version && version[0] == 'I' ? &marker : NULL;
}
__declspec(dllexport) void VR_ShutdownInternal(void) { token = 0; SetLastError(0x606); }
__declspec(dllexport) void *OwnedMarker(void) { return &marker; }
BOOL WINAPI fixtureDllMain(HINSTANCE instance, DWORD reason, void *reserved) { return TRUE; }
