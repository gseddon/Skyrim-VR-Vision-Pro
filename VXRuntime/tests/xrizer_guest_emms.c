// Owned x87 state control for EMMS; executed by real Rosetta and strict AOT.
#include <windows.h>
#include <stdint.h>
static const uint16_t nondefault_control=0x077f;
static unsigned char before[512] __attribute__((aligned(16)));
static unsigned char middle[512] __attribute__((aligned(16)));
static unsigned char after[512] __attribute__((aligned(16)));
__attribute__((naked,noinline)) void emms_instruction(void) { __asm__ volatile("emms; ret"); }
void mainCRTStartup(void) {
    int rosetta=0; for (const char *p=GetCommandLineA();*p;p++) if (*p=='@') rosetta=1;
    uint64_t flags_before,flags_after;
    __asm__ volatile("fninit\n\tfldcw %5\n\tfld1\n\tfldz\n\tftst\n\tfxsave64 %0\n\t.byte 0xc5,0xf8,0x77\n\tfxsave64 %2\n\tpushfq\n\tpopq %3\n\tcall emms_instruction\n\tpushfq\n\tpopq %4\n\tfxsave64 %1\n\tfninit"
        : "=m"(before),"=m"(after),"=m"(middle),"=r"(flags_before),"=r"(flags_after) : "m"(nondefault_control) : "memory");
    for (unsigned i=0;i<5;i++) if (before[i]!=middle[i]) ExitProcess(5);
    for (unsigned i=0;i<8;i++) for (unsigned j=0;j<10;j++)
        if (before[32+i*16+j]!=middle[32+i*16+j]) ExitProcess(6);
    unsigned old_top=(before[3]>>3)&7, new_top=(after[3]>>3)&7;
    if (!before[4] || old_top!=6 || before[0]!=0x7f || before[1]!=0x07 || !(before[3]&0x40) || after[4] || before[0]!=after[0] || before[1]!=after[1] ||
        before[2]!=after[2] || (before[3]&0xc7)!=(after[3]&0xc7) || new_top!=(rosetta?old_top:0) || flags_before!=flags_after) ExitProcess(1);
    // FXSAVE stores data in logical TOP order; compare the same physical slot.
    for (unsigned i=0;i<8;i++) for (unsigned j=0;j<10;j++) {
        unsigned out=(old_top+i+8-new_top)&7;
        if (before[32+i*16+j]!=after[32+out*16+j]) ExitProcess(2);
    }
    for (unsigned i=24;i<28;i++) if (before[i]!=after[i]) ExitProcess(3);
    const char msg[]="xrizer_guest_emms: tags emptied; x87 physical values/control/non-TOP status, flags and MXCSR preserved -> ok\n";
    DWORD n=0; if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),msg,sizeof msg-1,&n,0) || n!=sizeof msg-1) ExitProcess(4);
    ExitProcess(0);
}
