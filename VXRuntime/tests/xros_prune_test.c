// vx_prune_skse_dlls on a temp dir: the stale DLL goes; a listed DLL (any case), ini, log, a folder named .dll and other files stay.
#include "vx_prune.h"
#include <stdlib.h>
#include <sys/stat.h>
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)
static void touch(const char *d, const char *n) { char p[512]; snprintf(p, sizeof p, "%s/%s", d, n); FILE *f = fopen(p, "w"); if (f) { fputs("x", f); fclose(f); } }
static int exists(const char *d, const char *n) { char p[512]; snprintf(p, sizeof p, "%s/%s", d, n); return !access(p, F_OK); }
static int logged;
static void on_removed(const char *p) { logged++; (void)p; }
int main(void) {
    char d[] = "/tmp/vx_prune_XXXXXX"; if (!mkdtemp(d)) return 2;
    touch(d, "aaa_modlist_dump.dll"); touch(d, "STALE2.DLL"); touch(d, "HIGGS.dll"); touch(d, "higgs_vr.ini"); touch(d, "vrik.log"); touch(d, "notes.txt");
    char sub[512]; snprintf(sub, sizeof sub, "%s/dir.dll", d); mkdir(sub, 0755);
    const char *keep[] = { "higgs.dll" };
    int n = vx_prune_skse_dlls(d, keep, 1, on_removed);
    CHECK(n == 2); CHECK(logged == 2);
    CHECK(!exists(d, "aaa_modlist_dump.dll")); CHECK(!exists(d, "STALE2.DLL"));
    CHECK(exists(d, "HIGGS.dll")); CHECK(exists(d, "higgs_vr.ini")); CHECK(exists(d, "vrik.log")); CHECK(exists(d, "notes.txt")); CHECK(exists(d, "dir.dll"));
    CHECK(vx_prune_skse_dlls("/tmp/vx_prune_nonexistent", keep, 1, NULL) == 0);
    char cmd[600]; snprintf(cmd, sizeof cmd, "rm -rf %s", d); system(cmd);
    if (!fails) puts("xros_prune: ok");
    return fails ? 1 : 0;
}
