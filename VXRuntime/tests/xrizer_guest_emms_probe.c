// Inspect hardware-visible FXSAVE tags/TOP around EMMS under a reference runner.
#include <windows.h>
static unsigned char before[512] __attribute__((aligned(16))),after[512] __attribute__((aligned(16)));
void mainCRTStartup(void) {
    __asm__ volatile("fninit; fld1; fldz; fxsave64 %0; emms; fxsave64 %1; fninit" : "=m"(before),"=m"(after) : : "memory");
    static const char hex[]="0123456789abcdef";
    char msg[]="ftw=00/00 fsw=0000/0000\n";
    unsigned char v[]={before[4],after[4],before[3],before[2],after[3],after[2]};
    unsigned p[]={4,7,14,16,19,21};
    for(unsigned i=0;i<6;i++){msg[p[i]]=hex[v[i]>>4];msg[p[i]+1]=hex[v[i]&15];}
    DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),msg,sizeof msg-1,&n,0);ExitProcess(0);
}
