// A version-specific ordinal must invoke the same Windows ABI as its name.
#include <windows.h>
#include <xinput.h>
#include <stdint.h>

typedef DWORD (WINAPI *capabilities_fn)(DWORD, DWORD, XINPUT_CAPABILITIES *);

void mainCRTStartup(void) {
    HMODULE module = GetModuleHandleW(L"xinput1_3.dll");
    FARPROC named = GetProcAddress(module, "XInputGetCapabilities");
    FARPROC ordinal = GetProcAddress(module, (const char *)(uintptr_t)4);
    if (!module || !named || ordinal != named) ExitProcess(1);
    struct {
        uint64_t before;
        XINPUT_CAPABILITIES caps;
        uint64_t after;
    } output;
    output.before = UINT64_C(0x123456789abcdef0);
    output.after = UINT64_C(0xfedcba9876543210);
    SetLastError(0x1234);
    DWORD result = ((capabilities_fn)ordinal)(0, XINPUT_FLAG_GAMEPAD, &output.caps);
    if (result != ERROR_SUCCESS && result != ERROR_DEVICE_NOT_CONNECTED) ExitProcess(2);
    if (GetLastError() != 0x1234) ExitProcess(3);
    if (output.before != UINT64_C(0x123456789abcdef0) || output.after != UINT64_C(0xfedcba9876543210)) ExitProcess(4);
    const char message[] = "aot_xinput_ordinal: ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof message - 1, &written, NULL) ||
        written != sizeof message - 1) ExitProcess(5);
    ExitProcess(0);
}
