// (The functions sit in .data, so they and the written variables always share a host page.)
// Threads write data that shares a host page with code the translator has watched, while other threads keep
// translating new code from that page. A write that faults on the watch must go again, never be reported as an
// access violation because another thread watched the page again between the fault and the check.
#include <windows.h>
#include <stdio.h>

#define NFUNC 300
#define F(n) __attribute__((noinline, section(".data"))) static int f##n(int x) { return x * (n | 1) + (x >> (n % 7)) + n; }
#define F10(n) F(n##0) F(n##1) F(n##2) F(n##3) F(n##4) F(n##5) F(n##6) F(n##7) F(n##8) F(n##9)
#define F100(n) F10(n##0) F10(n##1) F10(n##2) F10(n##3) F10(n##4) F10(n##5) F10(n##6) F10(n##7) F10(n##8) F10(n##9)
F100(1) F100(2) F100(3)
#define P(n) f##n,
#define P10(n) P(n##0) P(n##1) P(n##2) P(n##3) P(n##4) P(n##5) P(n##6) P(n##7) P(n##8) P(n##9)
#define P100(n) P10(n##0) P10(n##1) P10(n##2) P10(n##3) P10(n##4) P10(n##5) P10(n##6) P10(n##7) P10(n##8) P10(n##9)
static int (*const funcs[])(int) = { P100(1) P100(2) P100(3) };

__asm__(".section .data\n.balign 64\n.globl smcvars\nsmcvars: .fill 64,1,0\n.text\n");
extern volatile LONG64 smcvars[8];
#define spin smcvars[0]
#define counter smcvars[1]
#define go smcvars[2]
#define stop smcvars[3]
#define sink smcvars[4]

static DWORD WINAPI writer(void *arg) {
    (void)arg;
    while (!go) ;
    for (long i = 0; i < 4000; i++) { spin = -1; counter++; spin = 0; }
    return 0;
}
static DWORD WINAPI translator(void *arg) {
    int x = (int)(intptr_t)arg;
    while (!go) ;
    for (int i = 0; i < NFUNC && !stop; i++) { x = funcs[i](x); }
    sink += x;
    return 0;
}

int main(void) {
    for (int round = 0; round < 3; round++) {
        HANDLE h[24];
        stop = 0; go = 0;
        for (int i = 0; i < 12; i++) h[i] = CreateThread(NULL, 0, writer, NULL, 0, NULL);
        for (int i = 12; i < 24; i++) h[i] = CreateThread(NULL, 0, translator, (void *)(intptr_t)i, 0, NULL);
        Sleep(20); go = 1;
        WaitForMultipleObjects(24, h, TRUE, INFINITE);
        for (int i = 0; i < 24; i++) CloseHandle(h[i]);
    }
    printf("smc_data_threads: ok (text %p data %p)\n", (void *)funcs[0], (void *)&spin);
    return 0;
}
