// Leaf callbacks have no unwind metadata. Their only address is in .text data.
#include <stdio.h>
extern int (*aot_text_callbacks[])(void);
int main(void) {
    int n = aot_text_callbacks[0]();
    printf("aot_text_callbacks: %s\n", n == 42 ? "ok" : "FAILED");
    return n == 42 ? 0 : 1;
}
