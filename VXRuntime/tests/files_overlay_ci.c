// Directory listing and opens through an overlay on a case-sensitive file system (the visionOS app's: a game folder holding only the
// vanilla files, the mods in an overlay, the game asking for DATA\... in other letters than the names on disk). Run with the game
// folder as the working directory and VXRT_OVERLAY=<game folder>:<overlay>, VXRT_CI_PATHS=1 (tests/files_overlay_ci_check.py).
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int fails;
static void say(const char *fmt, ...) {
    char b[512]; va_list ap; va_start(ap, fmt); int n = vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    DWORD w; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), b, n, &w, NULL);
}
static void check(int ok, const char *what) { say("%s: %s\n", ok ? "ok" : "FAIL", what); if (!ok) fails++; }
static int listed(const char *spec, const char *want[], int nwant, const char *label) {
    WIN32_FIND_DATAA d; HANDLE h = FindFirstFileA(spec, &d);
    char names[2048] = ""; int seen[16] = { 0 }, total = 0, dup = 0;
    if (h != INVALID_HANDLE_VALUE) do {
        total++; strcat(names, d.cFileName); strcat(names, " ");
        for (int i = 0; i < nwant; i++) if (!_stricmp(d.cFileName, want[i])) { if (seen[i]++) dup++; }
    } while (FindNextFileA(h, &d));
    int all = 1; for (int i = 0; i < nwant; i++) if (seen[i] != 1) all = 0;
    say("%s: %s -> %d entries: %s\n", label, spec, total, names);
    check(all && !dup, label);
    return total;
}
int main(void) {
    char cwd[MAX_PATH], p[2 * MAX_PATH];
    GetCurrentDirectoryA(sizeof cwd, cwd);
    // 0. exact letters first: tells a case problem from an overlay problem
    const char *all0[] = { "Skyrim.esm", "mod.esp", "Textures", "Interface", "SKSE", "Scripts" };
    listed("Data\\*", all0, 6, "exact-case Data\\* lists vanilla and overlay entries once each");
    // 1. the game's own scan: a relative DATA\*
    const char *all[] = { "Skyrim.esm", "mod.esp", "Textures", "Interface", "SKSE", "Scripts" };
    listed("DATA\\*", all, 6, "relative DATA\\* lists vanilla and overlay entries once each");
    // 2. an absolute path, other letters again, and a pattern
    snprintf(p, sizeof p, "%s\\data\\*.esp", cwd);
    const char *esp[] = { "mod.esp" };
    listed(p, esp, 1, "absolute data\\*.esp lists the overlay's ESP");
    // 3. opens the way Skyrim does: fopen with mixed separators and wrong case, then CreateFile
    snprintf(p, sizeof p, "%s\\DATA/mod.esp", cwd);
    FILE *f = fopen(p, "rb"); char buf[16] = { 0 };
    if (f) { fread(buf, 1, 8, f); fclose(f); }
    check(f && !memcmp(buf, "TES4mod!", 8), "fopen DATA/mod.esp reads the overlay file");
    snprintf(p, sizeof p, "%s\\data\\TEXTURES\\sub\\a.dds", cwd);
    HANDLE h = CreateFileA(p, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    check(h != INVALID_HANDLE_VALUE, "CreateFile data\\TEXTURES\\sub\\a.dds opens the overlay file");
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    snprintf(p, sizeof p, "%s\\DATA\\skyrim.ESM", cwd);
    h = CreateFileA(p, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    check(h != INVALID_HANDLE_VALUE, "CreateFile DATA\\skyrim.ESM opens the vanilla file");
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    // 4. the plugin list file in C:\users\...
    FILE *pt = fopen("C:\\users\\vxrt\\AppData\\Local\\Skyrim VR\\Plugins.txt", "rb");
    check(pt != NULL, "Plugins.txt opens");
    if (pt) fclose(pt);
    say(fails ? "files_overlay_ci: %d failed\n" : "files_overlay_ci: all ok\n", fails);
    return fails ? 1 : 0;
}
