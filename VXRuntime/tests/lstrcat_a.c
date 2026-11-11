// lstrcpyA / lstrcatA / lstrlenA: the string helpers a CRT-less plugin uses (the SKSE fixture plugin avoided lstrcatA because the
// runtime did not export it).
#include <windows.h>

static void say(const char *s) { DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL); }
void mainCRTStartup(void) {
    char buf[64];
    char *r = lstrcpyA(buf, "My Games");
    if (r != buf) ExitProcess(2);
    r = lstrcatA(buf, "\\Skyrim VR");
    if (r != buf) ExitProcess(3);
    lstrcatA(buf, "");                      // an empty append changes nothing
    lstrcatA(buf, "\\SKSE");
    if (lstrlenA(buf) != 23 || lstrcmpA(buf, "My Games\\Skyrim VR\\SKSE")) { say("lstrcat_a: wrong result\n"); ExitProcess(1); }
    say("lstrcat_a: lstrcpyA, lstrcatA, lstrlenA -> ok\n");
    ExitProcess(0);
}
