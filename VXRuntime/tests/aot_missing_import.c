// A loader-owned missing-import token must name its API without translating it.
#include <stdint.h>

__declspec(dllimport) void VXRT_MissingImportFixture(void);
__declspec(dllimport) char *GetCommandLineA(void);
__declspec(dllimport) void ExitProcess(unsigned int);

void mainCRTStartup(void) {
    uintptr_t target = (uintptr_t)VXRT_MissingImportFixture;
    // An interior address is deliberately not a registered import entry.
    for (const char *p = GetCommandLineA(); *p; p++) if (*p == '@') target++;
    ((void (*)(void))target)();
    ExitProcess(99);
}
