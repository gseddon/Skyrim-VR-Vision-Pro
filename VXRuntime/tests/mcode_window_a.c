// LuaJIT 2.1.0-beta3's mcode_alloc (SkyUI-VR.dll+0x4cba0) as a probe: the code area must lie within 0x3fe00000 bytes of the DLL, and it
// asks VirtualAlloc(hint, size, MEM_RESERVE|MEM_COMMIT|MEM_TOP_DOWN, PAGE_READWRITE) for up to 31 hints
// (target - 0x3fe00000 + (random & 0x7fff0000)), the first with no hint at all. Reports how many of 400 attempts (31 hints each) get an area:
// whether LuaJIT can compile at all depends on free address space around the module, i.e. on where the modules are mapped.
// usage: mcode_window_a.exe <target-hex>   (target: the address of the DLL's code, e.g. 4a729 above the DLL base)
#include <windows.h>

static void say(const char *s) { DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL); }
static void num(unsigned long long v) { char b[24]; int i = 24; b[--i] = 0; do { b[--i] = '0' + v % 10; v /= 10; } while (v); say(b + i); }
static unsigned long long hex(const char *s) { unsigned long long v = 0; for (; *s; s++) v = v * 16 + (*s <= '9' ? *s - '0' : (*s | 32) - 'a' + 10); return v; }
void mainCRTStartup(void) {
    char arg[32]; if (!GetEnvironmentVariableA("MCODE_TARGET", arg, sizeof arg)) { say("MCODE_TARGET missing\n"); ExitProcess(2); }
    unsigned long long target = hex(arg) & ~0xffffull, rnd = 12345;
    const unsigned long long range = 0x3fe00000ull, size = 0x10000;
    int got = 0, first = 0, hinted = 0, trials = 400;
    for (int t = 0; t < trials; t++) {
        unsigned long long hint = 0; void *p = NULL;
        for (int i = 0; i < 32 && !p; i++) {
            p = VirtualAlloc((void *)(uintptr_t)hint, size, MEM_RESERVE | MEM_COMMIT | MEM_TOP_DOWN, PAGE_READWRITE);
            if (p) {
                unsigned long long a = (unsigned long long)(uintptr_t)p;
                if ((a > target ? a - target : target - a) + size >= range) { VirtualFree(p, 0, MEM_RELEASE); p = NULL; }   // (outside the window: released, next hint)
                else { if (i == 0) first++; else hinted++; }
            }
            rnd = rnd * 6364136223846793005ull + 1442695040888963407ull;
            hint = ((rnd >> 33) & 0x7fff0000ull) + target - range;
        }
        if (p) { got++; /* kept: the area stays allocated, as in LuaJIT */ }
    }
    say("mcode window around "); num(target); say(": "); num(got); say(" of "); num(trials); say(" attempts got an area (first try without hint "); num(first); say(", by hint "); num(hinted); say(")\n");
    ExitProcess(0);
}
