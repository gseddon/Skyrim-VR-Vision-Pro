// The CRT's startup hooks return without changing last error or their argument.
#include <windows.h>
#include <stdint.h>

typedef void (__cdecl *telemetry_fn)(HINSTANCE);

void mainCRTStartup(void) {
    HMODULE module = GetModuleHandleW(L"vcruntime140.dll");
    telemetry_fn invoke = (telemetry_fn)GetProcAddress(module, "__telemetry_main_invoke_trigger");
    telemetry_fn finish = (telemetry_fn)GetProcAddress(module, "__telemetry_main_return_trigger");
    if (!module || !invoke || !finish) ExitProcess(1);
    uint64_t data[2] = { UINT64_C(0x123456789abcdef0), UINT64_C(0xfedcba9876543210) };
    HINSTANCE instances[] = { NULL, (HINSTANCE)(uintptr_t)UINT64_C(0x140000000), (HINSTANCE)data };
    for (unsigned int i = 0; i < sizeof instances / sizeof *instances; i++) {
        SetLastError(0x1234);
        invoke(instances[i]);
        if (GetLastError() != 0x1234) ExitProcess(2);
        finish(instances[i]);
        if (GetLastError() != 0x1234) ExitProcess(3);
    }
    if (data[0] != UINT64_C(0x123456789abcdef0) || data[1] != UINT64_C(0xfedcba9876543210)) ExitProcess(4);
    const char message[] = "aot_telemetry: ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof message - 1, &written, NULL) ||
        written != sizeof message - 1) ExitProcess(5);
    ExitProcess(0);
}
