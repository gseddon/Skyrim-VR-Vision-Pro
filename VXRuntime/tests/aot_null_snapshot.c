// A null virtual call must raise a guest execute access violation, not re-enter the host.
#include <windows.h>
#include <stdint.h>
static volatile LONG faults;
static LONG WINAPI handler(EXCEPTION_POINTERS *ep) {
    EXCEPTION_RECORD *r = ep->ExceptionRecord;
    CONTEXT *c = ep->ContextRecord;
    if (r->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || r->NumberParameters != 2) ExitProcess(20);
    if (faults < 6) {
        if (r->ExceptionInformation[0] != 8 || r->ExceptionInformation[1] != 0 || c->Rip != 0) ExitProcess(20);
        c->Rip = *(DWORD64 *)(uintptr_t)c->Rsp; c->Rsp += 8;
    } else {
        if (r->ExceptionInformation[0] != (ULONG_PTR)(faults == 7) || r->ExceptionInformation[1] != 16) ExitProcess(20);
        c->Rip += 2;
    }
    ++faults;
    return EXCEPTION_CONTINUE_EXECUTION;
}
typedef void (WINAPI *method)(void *);
typedef struct { method *vtable; } object;
method methods[7];
object obj = {methods};
extern char null_call_return;
static DWORD WINAPI worker(void *arg) {
    object *o = arg;
    __asm__ volatile("mov %[object], %%rcx\n\t"
                     "mov (%%rcx), %%rax\n\t"
                     "call *0x30(%%rax)\n\t"
                     ".globl null_call_return\nnull_call_return:"
                     :: [object] "r"(o) : "rax", "rcx", "memory");
    for (unsigned i = 0; i < 5; i++)
        __asm__ volatile("mov $1, %%rax; mov $1, %%rcx; xor %%r11, %%r11; call *%%r11" ::: "rax", "rcx", "r11", "memory");
    __asm__ volatile("movl (%%rcx), %%eax\n\t.globl after_read\nafter_read:" :: "c"(16ull) : "eax", "memory");
    __asm__ volatile("movl %%eax, (%%rcx)\n\t.globl after_write\nafter_write:" :: "c"(16ull) : "memory");
    return faults == 8 ? 0 : 21;
}
void mainCRTStartup(void) {
    DWORD id, result = 99, written;
    if (!AddVectoredExceptionHandler(1, handler)) ExitProcess(22);
    HANDLE t = CreateThread(NULL, 0, worker, &obj, 0, &id);
    if (!t || !id || WaitForSingleObject(t, 5000) != WAIT_OBJECT_0 ||
        !GetExitCodeThread(t, &result) || result || !CloseHandle(t)) ExitProcess(23);
    const char msg[] = "aot_null_snapshot: execute/read/write guest access violations, resumed\n";
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg, sizeof msg - 1, &written, NULL) || written != sizeof msg - 1) ExitProcess(24);
    ExitProcess(0);
}
