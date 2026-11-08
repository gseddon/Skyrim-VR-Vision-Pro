// Owned signal diagnostic control; never enabled in ordinary runners.
#include "vx.h"
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
static WINAPI void TriggerNativeFatal(void) {
    pthread_t self=pthread_self(); uint64_t tid=0;
    uint64_t top=(uint64_t)(uintptr_t)pthread_get_stackaddr_np(self);
    size_t size=pthread_get_stacksize_np(self);
    (void)pthread_threadid_np(NULL,&tid);
    vx_log("xrizer_guest_nativefatal: expected stack_low=%#llx stack_high=%#llx tid=%#llx",
           (unsigned long long)(top-size),(unsigned long long)top,(unsigned long long)tid);
    raise(SIGBUS);
    vx_log("xrizer_guest_nativefatal: unexpected return");
}
static const vx_export exports[]={VX_EXPORT(TriggerNativeFatal)};
__attribute__((constructor)) static void register_fixture(void) {
    vx_register_module("vxrt_guest_nativefatal_fixture.dll",exports,sizeof exports/sizeof *exports);
}
#ifdef __aarch64__
#include "thunks/xrizer_guest_nativefatal_host.c.inc"
#endif
