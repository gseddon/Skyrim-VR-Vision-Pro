// Owned caller for rpcrt4!UuidCreateSequential. The bytes are this fixture's, not a game image.
#include <stdint.h>

__declspec(dllimport) long UuidCreateSequential(void *uuid);
__declspec(dllimport) void *GetStdHandle(unsigned long);
__declspec(dllimport) int WriteFile(void *file, const void *buf, unsigned long n, unsigned long *wrote, void *ov);
__declspec(dllimport) void ExitProcess(unsigned int);

typedef struct { uint32_t d1; uint16_t d2, d3; uint8_t d4[8]; } uuid;
typedef struct { uint8_t pre[16]; uuid u; uint8_t post[16]; } slot;

static uint64_t stamp(const uuid *u) {
    return (uint64_t)u->d1 | ((uint64_t)u->d2 << 32) | ((uint64_t)(u->d3 & 0x0fffu) << 48);
}
static int canary(const uint8_t *p) {
    for (int i = 0; i < 16; i++) if (p[i] != 0xa5) return 0;
    return 1;
}
static void fill(slot *s) {
    for (int i = 0; i < (int)sizeof *s; i++) ((uint8_t *)s)[i] = 0xa5;
}

void mainCRTStartup(void) {
    if (UuidCreateSequential(0) != 87) ExitProcess(1);
    slot s[3];
    long st[3];
    for (int i = 0; i < 3; i++) {
        fill(&s[i]);
        st[i] = UuidCreateSequential(&s[i].u);
    }
    if (st[0] != st[1] || st[1] != st[2] || (st[0] != 0 && st[0] != 1824)) ExitProcess(2);
    for (int i = 0; i < 3; i++) {
        if ((s[i].u.d3 >> 12) != 1 || (s[i].u.d4[0] & 0xc0) != 0x80) ExitProcess(3);
        if (!canary(s[i].pre) || !canary(s[i].post)) ExitProcess(6);
    }
    for (int i = 1; i < 3; i++) {
        if (s[i].u.d4[0] != s[0].u.d4[0] || s[i].u.d4[1] != s[0].u.d4[1]) ExitProcess(4);
        for (int b = 2; b < 8; b++) if (s[i].u.d4[b] != s[0].u.d4[b]) ExitProcess(4);
        if (stamp(&s[i].u) <= stamp(&s[i - 1].u)) ExitProcess(5);
    }
    if (st[0] == 1824) {
        if ((s[0].u.d4[2] & 1) == 0) ExitProcess(4);
    } else if (s[0].u.d4[2] & 1) ExitProcess(4);
    const char msg[] = "aot_uuid_sequential: version 1, variant, stable node, increasing time, canaries held -> ok\n";
    unsigned long n = 0;
    if (!WriteFile(GetStdHandle((unsigned long)-11), msg, sizeof msg - 1, &n, 0) || n != sizeof msg - 1) ExitProcess(7);
    ExitProcess(0);
}
