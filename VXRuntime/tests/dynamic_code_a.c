// A JIT's sequence (SkyUI VR's LuaJIT mcode area: VirtualAlloc read-write, write code, VirtualProtect PAGE_EXECUTE_READ, call):
// without strict AOT it works; under VXRT_AOT_STRICT both executable requests fail with ERROR_DYNAMIC_CODE_BLOCKED (1655), as under
// a ProhibitDynamicCode policy, while patching the program's own image code (what a script extender does) still works.
// JIT_EXPECT_BLOCKED=1 says which outcome the run must show.
#include <windows.h>

static void say(const char *s) { DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL); }
static int __attribute__((noinline)) hello(void) { return 7; }
void mainCRTStartup(void) {
    char e[8]; int blocked = GetEnvironmentVariableA("JIT_EXPECT_BLOCKED", e, sizeof e) && e[0] == '1';
    DWORD old;
    // (1) the image's own code can be made writable and restored in every mode
    if (!VirtualProtect((void *)hello, 16, PAGE_EXECUTE_READWRITE, &old) || !VirtualProtect((void *)hello, 16, old, &old)) { say("dynamic_code: image protect failed\n"); ExitProcess(1); }
    // (2) read-write memory is not code: always allowed
    unsigned char *p = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!p) { say("dynamic_code: read-write alloc failed\n"); ExitProcess(2); }
    p[0] = 0xB8; p[1] = 42; p[2] = p[3] = p[4] = 0; p[5] = 0xC3;          // mov eax, 42 ; ret
    SetLastError(0);
    BOOL ok = VirtualProtect(p, 4096, PAGE_EXECUTE_READ, &old);
    if (blocked) {
        if (ok || GetLastError() != 1655) { say("dynamic_code: VirtualProtect to executable was not refused with 1655\n"); ExitProcess(3); }
        SetLastError(0);
        void *q = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
        if (q || GetLastError() != 1655) { say("dynamic_code: executable VirtualAlloc was not refused with 1655\n"); ExitProcess(4); }
        if (hello() != 7) ExitProcess(5);
        say("dynamic_code: executable requests refused (1655), image patching allowed -> ok\n");
    } else {
        if (!ok) { say("dynamic_code: VirtualProtect to executable failed without strict\n"); ExitProcess(6); }
        if (((int (*)(void))p)() != 42) { say("dynamic_code: generated code returned the wrong value\n"); ExitProcess(7); }
        say("dynamic_code: executable requests allowed (no strict), generated code ran -> ok\n");
    }
    ExitProcess(0);
}
