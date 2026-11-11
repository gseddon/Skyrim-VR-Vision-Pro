// Windows C runtime text mode: a file opened without 'b' reads CR LF as LF (fgets, fgetc, fread); with 'b' the bytes come as they are.
// Skyrim VR reads its Plugins.txt with fgets in text mode and treats a trailing CR as part of the plugin name, so no plugin was found
// when the file had Windows line endings.
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int fails;
static void check(int ok, const char *what) { printf("%s: %s\n", ok ? "ok" : "FAIL", what); if (!ok) fails++; }
int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "crt_text_mode.tmp";
    FILE *w = fopen(path, "wb");
    fwrite("*one.esp\r\n*two words.esp\r\nlast", 1, 30, w);                 // CR LF, CR LF, and an unterminated last line
    fclose(w);
    char b[64];
    FILE *f = fopen(path, "r");
    check(f && fgets(b, sizeof b, f) && !strcmp(b, "*one.esp\n"), "fgets in \"r\" mode returns the line with LF only");
    check(fgets(b, sizeof b, f) && !strcmp(b, "*two words.esp\n"), "the second line too");
    check(fgets(b, sizeof b, f) && !strcmp(b, "last"), "an unterminated last line");
    check(fgets(b, sizeof b, f) == NULL, "then EOF");
    fclose(f);
    f = fopen(path, "rb");
    check(f && fgets(b, sizeof b, f) && !strcmp(b, "*one.esp\r\n"), "fgets in \"rb\" mode keeps the CR");
    fclose(f);
    f = fopen(path, "r");
    int c1 = fgetc(f); for (int i = 0; i < 7; i++) fgetc(f);
    check(c1 == '*' && fgetc(f) == '\n', "fgetc in \"r\" mode returns LF for CR LF");
    fclose(f);
    f = fopen(path, "r"); memset(b, 0, sizeof b);
    size_t n = fread(b, 1, 20, f);
    check(n == 20 && !memcmp(b, "*one.esp\n*two wo", 16), "fread in \"r\" mode returns the 20 requested bytes after translation");
    fclose(f);
    remove(path);
    printf(fails ? "crt_text_mode: %d failed\n" : "crt_text_mode: all ok\n", fails);
    return fails != 0;
}
