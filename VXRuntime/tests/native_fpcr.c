// A translated call must keep AFP's alternate NaN handling out of native frameworks, then restore it for
// the program. Two different NaNs after the call distinguish AH from ARM's usual NaN propagation.
#include "../translator/engine.h"
#include <stdio.h>
#include <string.h>

static uint64_t native_fpcr;
static void native(x86_ctx *c) {
    (void)c;
    __asm__ volatile("mrs %0, fpcr" : "=r"(native_fpcr));
}
static void (*find_native(uint64_t rip))(x86_ctx *) {
    return rip == (uint64_t)(uintptr_t)native ? native : NULL;
}

int main(void) {
    static const uint8_t code[] = { 0xff, 0xd0, 0xf3, 0x0f, 0x58, 0xc1, 0xc3 }; // call rax; addss xmm0,xmm1; ret
    enum { STOP = 0x7ff000 };
    uint64_t host_fpcr, after;
    __asm__ volatile("mrs %0, fpcr" : "=r"(host_fpcr));
    xe *e = xe_new(0);
    if (!e) return 1;
    xe_set_native(e, find_native);
    int wrong = 0;
    for (unsigned rc = 0; rc < 4; rc++) {
        uint64_t stack[64] = { 0 };
        x86_ctx c = { 0 };
        c.mxcsr = 0x1f80 | rc << 13;
        c.fcw = 0x037f;
        c.rip = (uint64_t)(uintptr_t)code;
        c.gpr[0] = (uint64_t)(uintptr_t)native;
        c.gpr[4] = (uint64_t)(uintptr_t)&stack[63];
        stack[63] = STOP;
        uint32_t a = 0x7fc12345, b = 0x7f854321, result;
        memcpy(c.xmm[0], &a, sizeof a); memcpy(c.xmm[1], &b, sizeof b);
        int r = xe_run(e, &c, STOP);
        __asm__ volatile("mrs %0, fpcr" : "=r"(after));
        memcpy(&result, c.xmm[0], sizeof result);
        uint64_t rounding = (uint64_t)((rc & 1) << 1 | rc >> 1) << 22;
        if (r || (native_fpcr & 2) || (native_fpcr & (3ull << 22)) != rounding || result != a || after != host_fpcr) {
            printf("native_fpcr: rc %u, exit %d, native %#llx, result %#x, host %#llx -> %#llx\n", rc, r,
                   (unsigned long long)native_fpcr, result, (unsigned long long)host_fpcr, (unsigned long long)after);
            wrong++;
        }
    }
    printf("native_fpcr: native calls, guest NaNs and rounding, host restoration: %d failures -> %s\n", wrong, wrong ? "FAILED" : "ok");
    return wrong != 0;
}
