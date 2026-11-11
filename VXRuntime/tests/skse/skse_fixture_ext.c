// The "script extender" of the fixture: patches the host's two sites from DllMain, like SKSE64_Initialize does.
#include <windows.h>
#include <stdint.h>

static uint8_t *g_gen;
__declspec(dllexport) int ext_hooked(int x) { return x + 100; }
static int write_branch(uint8_t *site, uint8_t op, uint8_t *dst);
// what a plugin does from a messaging handler (kDataLoaded): a second hook, installed long after DllMain
__declspec(dllexport) int ext_late(void) {
    uint8_t *(*s2)(void) = (uint8_t *(*)(void))GetProcAddress(GetModuleHandleA(NULL), "fixture_site2");
    return s2 && write_branch(s2(), 0xe9, g_gen);
}

static void say(const char *s) { DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL); }
// BranchTrampoline::Create: search backwards from the module for free address space, then VirtualAlloc RWX at its end
static uint8_t *create_trampoline(size_t len, void *module) {
    uintptr_t addr = (uintptr_t)module - 1, lowest = (uintptr_t)module - 0x80000000ull + (128u << 20);
    for (;;) {
        MEMORY_BASIC_INFORMATION info;
        if (!VirtualQuery((void *)addr, &info, sizeof info)) return NULL;
        if (info.State == MEM_FREE && info.RegionSize >= len) {
            uintptr_t at = (uintptr_t)info.BaseAddress + info.RegionSize - len;
            uint8_t *p = VirtualAlloc((void *)at, len, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
            if (p) return p;
        }
        addr = (uintptr_t)info.BaseAddress - 1;
        if (addr < lowest) return NULL;
    }
}
static int write_branch(uint8_t *site, uint8_t op, uint8_t *dst) {
    int64_t d = (int64_t)(dst - (site + 5));
    if (d < INT32_MIN || d > INT32_MAX) return 0;
    DWORD old;
    VirtualProtect(site, 5, PAGE_EXECUTE_READWRITE, &old);
    site[0] = op; *(int32_t *)(site + 1) = (int32_t)d;
    VirtualProtect(site, 5, old, &old);
    return 1;
}
BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, void *r) {
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    HMODULE exe = GetModuleHandleA(NULL);
    uint8_t *(*s1)(void) = (uint8_t *(*)(void))GetProcAddress(exe, "fixture_site1");
    uint8_t *(*s2)(void) = (uint8_t *(*)(void))GetProcAddress(exe, "fixture_site2");
    if (!s1 || !s2) { say("ext: host sites not found\n"); return FALSE; }
    uint8_t *buf = create_trampoline(0x10000, exe);   // the trampoline
    if (!buf) { say("ext: no trampoline\n"); return FALSE; }
    uint8_t *tr = buf;                                   // jmp [rip+0]; dq ext_hooked
    tr[0] = 0xff; tr[1] = 0x25; *(uint32_t *)(tr + 2) = 0; *(uint64_t *)(tr + 6) = (uint64_t)(uintptr_t)ext_hooked;
    uint8_t *gen = buf + 0x20;                           // lea eax,[rcx+0x3e8]; ret   (the "Xbyak" stub), hooked later by ext_late()
    static const uint8_t code[] = { 0x8d, 0x81, 0xe8, 0x03, 0x00, 0x00, 0xc3 };
    for (unsigned i = 0; i < sizeof code; i++) gen[i] = code[i];
    g_gen = gen;
    if (!write_branch(s1(), 0xe8, tr)) { say("ext: branch out of range\n"); return FALSE; }
    return TRUE;
}
