// Exercise synchronous native-to-guest nesting without UI, graphics or Steam.
#include <windows.h>

static unsigned calls, requested = 1;
static BOOL CALLBACK locale_callback(LPSTR locale) {
    if (!locale || locale[0] != '0') ExitProcess(1);
    if (++calls < requested && !EnumSystemLocalesA(locale_callback, 0)) ExitProcess(2);
    return TRUE;
}

void mainCRTStartup(void) {
    for (const char *p = GetCommandLineA(); *p; p++) if (*p == '@') requested = 3;
    if (!EnumSystemLocalesA(locale_callback, 0) || calls != requested) ExitProcess(3);
    const char message[] = "aot_callback_depth: ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof message - 1, &written, NULL) ||
        written != sizeof message - 1) ExitProcess(4);
    ExitProcess(0);
}
