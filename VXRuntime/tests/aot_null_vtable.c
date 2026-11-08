// A null virtual call must raise a guest execute access violation, not re-enter the host.
#include <windows.h>
#include <stdint.h>
static volatile LONG faults;
static LONG WINAPI handler(EXCEPTION_POINTERS *ep) {
    EXCEPTION_RECORD *r = ep->ExceptionRecord;
    CONTEXT *c = ep->ContextRecord;
    if (r->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || r->NumberParameters != 2) ExitProcess(20);
    if (!faults) {
        if (r->ExceptionInformation[0] != 8 || r->ExceptionInformation[1] != 0 || c->Rip != 0) ExitProcess(20);
        c->Rip = *(DWORD64 *)(uintptr_t)c->Rsp; c->Rsp += 8;
    } else {
        if (r->ExceptionInformation[0] != (ULONG_PTR)(faults == 2) || r->ExceptionInformation[1] != 16) ExitProcess(20);
        c->Rip += 2;
    }
    ++faults;
    return EXCEPTION_CONTINUE_EXECUTION;
}
typedef void (WINAPI *method)(void *);
typedef struct { method *vtable; } object;
static method methods[7];
static object obj = {methods};
static DWORD WINAPI worker(void *arg) {
    object *o = arg;
    o->vtable[6](o);
    __asm__ volatile("movl (%%rcx), %%eax" :: "c"(16ull) : "eax", "memory");
    __asm__ volatile("movl %%eax, (%%rcx)" :: "c"(16ull) : "memory");
    return faults == 3 ? 0 : 21;
}
void mainCRTStartup(void) {
    DWORD id, result = 99, written;
    if (!AddVectoredExceptionHandler(1, handler)) ExitProcess(22);
    HANDLE t = CreateThread(NULL, 0, worker, &obj, 0, &id);
    if (!t || !id || WaitForSingleObject(t, 5000) != WAIT_OBJECT_0 ||
        !GetExitCodeThread(t, &result) || result || !CloseHandle(t)) ExitProcess(23);
    const char msg[] = "aot_null_vtable: execute/read/write guest access violations, resumed\n";
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg, sizeof msg - 1, &written, NULL) || written != sizeof msg - 1) ExitProcess(24);
    ExitProcess(0);
}
