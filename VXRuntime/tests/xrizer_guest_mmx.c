// Owned MMX control for the opcodes in the reached Bink block.
// Data results are compared with values observed on Rosetta. FXSAVE alias
// (tags valid, destination exponent all ones) is required on the translator;
// Rosetta leaves the x87 image unchanged and exits 2.
#include <windows.h>
#include <stdint.h>

static const uint64_t A = 0x0123456789abcdefull, B = 0xfedcba9876543210ull, C = 0x80017fff7fff0001ull;
static const uint32_t D = 0x89abcdefu;
static const uint64_t COUNT = 4, COUNT32 = 32, COUNT40 = 40;
static const uint16_t CW = 0x077f;
static const uint32_t MX = 0x9FC0u;

static uint64_t run2(const uint64_t *x, const uint64_t *y, const char *op) {
    uint64_t r;
    #define BODY(code) do { __asm__ volatile(code "\n\tmovq %%mm0, %0\n\temms" : "=m"(r) : "m"(*x), "m"(*y) : "memory"); return r; } while (0)
    if (op[0] == 'x') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpxor %%mm1, %%mm0");
    if (op[0] == 'z') BODY("movq %1, %%mm0\n\tpxor %%mm0, %%mm0");
    if (op[0] == 'o') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpor %%mm1, %%mm0");
    if (op[0] == 'a') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpaddw %%mm1, %%mm0");
    if (op[0] == 's' && op[1] == 'u') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpsubw %%mm1, %%mm0");
    if (op[0] == 's' && op[1] == 'a') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpaddsw %%mm1, %%mm0");
    if (op[0] == 'u') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpsubusw %%mm1, %%mm0");
    if (op[0] == 'm') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpmulhw %%mm1, %%mm0");
    if (op[0] == 'l' && op[1] == 'b') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpunpcklbw %%mm1, %%mm0");
    if (op[0] == 'h' && op[1] == 'b') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpunpckhbw %%mm1, %%mm0");
    if (op[0] == 'l' && op[1] == 'w') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpunpcklwd %%mm1, %%mm0");
    if (op[0] == 'h' && op[1] == 'w') BODY("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpunpckhwd %%mm1, %%mm0");
    if (op[0] == 'L') BODY("movq %1, %%mm0\n\tpsllw $4, %%mm0");
    if (op[0] == 'R') BODY("movq %1, %%mm0\n\tpsrlw $4, %%mm0");
    if (op[0] == 'D') BODY("movq %1, %%mm0\n\tpslld $8, %%mm0");
    if (op[0] == 'Z') BODY("movq %1, %%mm0\n\tpsllw $16, %%mm0");
    if (op[0] == 'I') BODY("movq %1, %%mm0\n\tpsllw $0, %%mm0");
    #undef BODY
    return 0;
}

static void fail(const char *msg) {
    DWORD n = 0;
    const char *p = msg;
    while (*p) p++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg, (DWORD)(p - msg), &n, 0);
    ExitProcess(1);
}

static void expect(const char *name, uint64_t got, uint64_t want) {
    if (got == want) return;
    char buf[96];
    DWORD n = 0;
    int k = 0;
    const char *p = "xrizer_guest_mmx: mismatch ";
    while (*p) buf[k++] = *p++;
    while (*name) buf[k++] = *name++;
    buf[k++] = '\n';
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), buf, (DWORD)k, &n, 0);
    ExitProcess(1);
}

static int alias(void) {
    static unsigned char before[512] __attribute__((aligned(64)));
    static unsigned char after[512] __attribute__((aligned(64)));
    static unsigned char pat[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    uint64_t flags_before, flags_after;
    __asm__ volatile(
        "fninit\n\tfldcw %4\n\tfld1\n\tfldz\n\tftst\n\tldmxcsr %5\n"
        "movdqu %6, %%xmm7\n\tstc\n\tfxsave64 %0\n\tpushfq\n\tpopq %2\n"
        "pxor %%mm5, %%mm5\n\tpushfq\n\tpopq %3\n\tfxsave64 %1\n\temms"
        : "=m"(before), "=m"(after), "=r"(flags_before), "=r"(flags_after)
        : "m"(CW), "m"(MX), "m"(pat) : "memory");
    if (before[4] == after[4] && after[4] != 0xFF) return 2;
    int old_top = (before[3] >> 3) & 7, new_top = (after[3] >> 3) & 7;
    if (after[4] != 0xFF || old_top != new_top || old_top != 6) return 1;
    if (before[0] != after[0] || before[1] != after[1] || before[2] != after[2] || before[3] != after[3]) return 1;
    if (flags_before != flags_after) return 1;
    for (int i = 24; i < 28; i++) if (before[i] != after[i] || after[24] != 0xC0 || after[25] != 0x9F) return 1;
    for (int i = 0; i < 16; i++) if (after[160 + 7 * 16 + i] != pat[i]) return 1;
    for (int p = 0; p < 8; p++) {
        int b = (p - old_top + 8) & 7, a = (p - new_top + 8) & 7;
        int n = p == 5 ? 8 : 10;
        for (int j = 0; j < n; j++) if (before[32 + b * 16 + j] != after[32 + a * 16 + j]) return 1;
        if (p == 5 && (after[32 + a * 16 + 8] != 0xFF || after[32 + a * 16 + 9] != 0xFF)) return 1;
        if (p == 5) for (int j = 0; j < 8; j++) if (after[32 + a * 16 + j] != 0) return 1;
    }
    return 0;
}

void mainCRTStartup(void) {
    expect("pxor", run2(&A, &B, "x"), 0xffffffffffffffffull);
    expect("pxor0", run2(&A, &B, "z"), 0);
    expect("por", run2(&A, &B, "o"), 0xffffffffffffffffull);
    expect("paddw", run2(&A, &B, "a"), 0xffffffffffffffffull);
    expect("psubw", run2(&A, &B, "su"), 0x02478acf13579bdfull);
    expect("paddsw", run2(&C, &C, "sa"), 0x80007fff7fff0002ull);
    expect("psubusw", run2(&C, &A, "u"), 0x7ede3a9800000000ull);
    expect("pmulhw", run2(&A, &B, "m"), 0xfffeed2fc94df635ull);
    expect("punpcklbw", run2(&A, &B, "lb"), 0x768954ab32cd10efull);
    expect("punpckhbw", run2(&A, &B, "hb"), 0xfe01dc23ba459867ull);
    expect("punpcklwd", run2(&A, &B, "lw"), 0x765489ab3210cdefull);
    expect("punpckhwd", run2(&A, &B, "hw"), 0xfedc0123ba984567ull);
    expect("psllw", run2(&A, &B, "L"), 0x123056709ab0def0ull);
    expect("psrlw", run2(&A, &B, "R"), 0x00120456089a0cdeull);
    expect("pslld", run2(&A, &B, "D"), 0x23456700abcdef00ull);
    expect("psllw0", run2(&A, &B, "I"), A);
    expect("psllw16", run2(&A, &B, "Z"), 0);
    uint64_t got, mem = C;
    __asm__ volatile("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpslld %%mm1, %%mm0\n\tmovq %%mm0, %0\n\temms"
        : "=m"(got) : "m"(A), "m"(COUNT) : "memory");
    expect("pslld-mm", got, 0x123456709abcdef0ull);
    __asm__ volatile("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpslld %%mm1, %%mm0\n\tmovq %%mm0, %0\n\temms"
        : "=m"(got) : "m"(A), "m"(COUNT32) : "memory");
    expect("pslld-32", got, 0);
    __asm__ volatile("movq %1, %%mm0\n\tmovq %2, %%mm1\n\tpslld %%mm1, %%mm0\n\tmovq %%mm0, %0\n\temms"
        : "=m"(got) : "m"(A), "m"(COUNT40) : "memory");
    expect("pslld-40", got, 0);
    __asm__ volatile("movd %1, %%mm4\n\tmovq %%mm4, %0\n\temms" : "=m"(got) : "m"(D) : "memory");
    expect("movd", got, 0x89abcdefull);
    __asm__ volatile("movq %1, %%mm2\n\tmovq %%mm2, %0\n\temms" : "=m"(got) : "m"(A) : "memory");
    expect("movq", got, A);
    __asm__ volatile("movq %2, %%mm4\n\tpaddsw %1, %%mm4\n\tmovq %%mm4, %0\n\temms" : "=m"(got) : "m"(mem), "m"(A) : "memory");
    expect("paddsw-m", got, 0x81247fff09aacdf0ull);
    uint32_t d32 = 0;
    __asm__ volatile("movq %1, %%mm3\n\tmovd %%mm3, %0\n\temms" : "=m"(d32) : "m"(A) : "memory");
    if (d32 != 0x89abcdefu) fail("xrizer_guest_mmx: mismatch movd-store\n");
    int al = alias();
    const char *msg = al == 2
        ? "xrizer_guest_mmx: data ok; fxsave did not show the MMX alias\n"
        : "xrizer_guest_mmx: reached ops match, tags valid, destination exponent ones, other x87 MXCSR flags and XMM preserved -> ok\n";
    if (al == 1) fail("xrizer_guest_mmx: alias mismatch\n");
    DWORD n = 0;
    const char *p = msg;
    while (*p) p++;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg, (DWORD)(p - msg), &n, 0) || n != (DWORD)(p - msg)) ExitProcess(4);
    ExitProcess(al == 2 ? 2 : 0);
}
