// Resolve the observed XInput 1.3 vibration ordinal without inventing hardware.
#include <windows.h>
#include <xinput.h>
#include <stdint.h>

typedef DWORD (WINAPI *vibration_fn)(DWORD, XINPUT_VIBRATION *);

void mainCRTStartup(void) {
    HMODULE module = GetModuleHandleW(L"xinput1_3.dll");
    FARPROC named = GetProcAddress(module, "XInputSetState");
    FARPROC ordinal = GetProcAddress(module, (const char *)(uintptr_t)3);
    if (!module || !named || ordinal != named) ExitProcess(1);
    struct {
        DWORD before;
        XINPUT_VIBRATION vibration;
        DWORD after;
    } request = { 0x12345678, { 0, 0 }, 0x87654321 };
    SetLastError(0x1234);
    DWORD result = ((vibration_fn)ordinal)(0, &request.vibration);
    if (result != ERROR_SUCCESS && result != ERROR_DEVICE_NOT_CONNECTED) ExitProcess(2);
    if (GetLastError() != 0x1234) ExitProcess(3);
    if (request.before != 0x12345678 || request.after != 0x87654321) ExitProcess(4);
    const char message[] = "aot_xinput_ordinal3: ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof message - 1, &written, NULL) ||
        written != sizeof message - 1) ExitProcess(5);
    ExitProcess(0);
}
