// Unhandled execute, read, and write AV diagnostics, selected by command line.
#include <windows.h>
void mainCRTStartup(void) {
    const char *p = GetCommandLineA();
    while (*p && *p != '@') ++p;
    if (*p) ++p;
    if (*p == 'e') __asm__ volatile("xor %%rax, %%rax; call *%%rax" ::: "rax", "memory");
    if (*p == 'r') __asm__ volatile("movl (%%rcx), %%eax" :: "c"(16ull) : "eax", "memory");
    if (*p == 'w') __asm__ volatile("movl %%eax, (%%rcx)" :: "c"(16ull) : "memory");
    ExitProcess(25);
}
