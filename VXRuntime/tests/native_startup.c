// Prove that the startup harness reads original assets and redirects writes.
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int read_value(const char *expected) {
    HANDLE f = CreateFileA("native_startup_asset.txt", GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    char value[32] = {0}; DWORD count = 0;
    if (f == INVALID_HANDLE_VALUE) return 0;
    int ok = ReadFile(f, value, sizeof(value) - 1, &count, NULL);
    CloseHandle(f);
    return ok && count == strlen(expected) && !memcmp(value, expected, count);
}

int main(void) {
    if (!read_value("original")) { puts("native_startup: original asset unavailable"); return 1; }
    HANDLE f = CreateFileA("native_startup_asset.txt", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) return 2;
    DWORD count = 0;
    int ok = WriteFile(f, "shadow", 6, &count, NULL);
    CloseHandle(f);
    if (!ok || count != 6 || !read_value("shadow")) return 3;
    puts("native_startup: overlay ok");
    return 0;
}
