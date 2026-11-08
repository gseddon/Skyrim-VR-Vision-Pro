// Strict-AOT worker-thread callback nesting; no graphics or Steam.
#include <windows.h>

static unsigned calls;
static BOOL CALLBACK callback(LPSTR locale) {
    if (!locale || locale[0] != '0') ExitProcess(10);
    if (++calls < 3 && !EnumSystemLocalesA(callback, 0)) ExitProcess(11);
    return TRUE;
}
static DWORD WINAPI worker(void *arg) {
    (void)arg;
    if (!EnumSystemLocalesA(callback, 0) || calls != 3) return 12;
    return 0;
}
void mainCRTStartup(void) {
    DWORD id, result = 99, written;
    HANDLE t = CreateThread(NULL, 0, worker, NULL, 0, &id);
    if (!t || !id || WaitForSingleObject(t, 5000) != WAIT_OBJECT_0 ||
        !GetExitCodeThread(t, &result) || result || !CloseHandle(t)) ExitProcess(13);
    const char message[] = "aot_callback_worker: ok\n";
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof message - 1, &written, NULL) ||
        written != sizeof message - 1) ExitProcess(14);
    ExitProcess(0);
}
