// Owned fixture for the static script-extender scheme (research/2026-11-11-skse-vr-on-aot.md): a "game" with two hook sites
// that skse_fixture_ext.dll patches at start-up the way SKSE VR does (a 5-byte call into a jmp [rip] stub in executable
// memory, and a 5-byte jump into a small generated stub). Under AOT, only the capture/patch/region scheme makes them fire.
#include <windows.h>

__attribute__((noinline)) int original(int x) { return x + 1; }
// site 1: "call original" (E8 rel32), the shape of BranchTrampoline::Write5Call
__attribute__((noinline, naked)) int work(int x) {
    __asm__ volatile("sub $40,%rsp\n.globl hook_site1\nhook_site1:\ncall original\nadd $40,%rsp\nret\n");
}
// site 2: five NOPs at the entry (E9 rel32 goes in), the shape of Write5Branch into an Xbyak stub
__attribute__((noinline, naked)) int work2(int x) {
    __asm__ volatile(".globl hook_site2\nhook_site2:\nnop\nnop\nnop\nnop\nnop\nmov %ecx,%eax\nret\n");
}
__declspec(dllexport) void *fixture_site1(void) { extern char hook_site1[]; return hook_site1; }
__declspec(dllexport) void *fixture_site2(void) { extern char hook_site2[]; return hook_site2; }

static void say(const char *s) {
    DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL);
}
void mainCRTStartup(void) {
    // (the extension DLL is loaded by VXRT_PRELOAD before this point; with no preload nothing is hooked)
    int a = work(10), b = work2(5);
    if (a == 110 && b == 1005) { say("skse_fixture: hooks fired (work=110 work2=1005) -> ok\n"); ExitProcess(0); }
    if (a == 11 && b == 5) say("skse_fixture: not hooked (work=11 work2=5)\n");
    else say("skse_fixture: unexpected results\n");
    ExitProcess(1);
}
