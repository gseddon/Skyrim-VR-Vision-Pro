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

    // vx_prune_pack_files: files of the remembered list that the new list no longer names go; everything else stays.
    char r[] = "/tmp/vx_prune_pack_XXXXXX"; if (!mkdtemp(r)) return 2;
    char ov[512]; snprintf(ov, sizeof ov, "%s/overlay_skyrimvr", r); mkdir(ov, 0755);
    char dd[600]; snprintf(dd, sizeof dd, "%s/Data", ov); mkdir(dd, 0755);
    char tx[700]; snprintf(tx, sizeof tx, "%s/Textures", dd); mkdir(tx, 0755);
    touch(ov, "sksevr_1_4_15.dll"); touch(dd, "higgs_vr.esp"); touch(tx, "rock.dds"); touch(tx, "tree.dds"); touch(dd, "game_wrote.log"); touch(r, "outside.txt");
    logged = 0;
    CHECK(vx_prune_pack_files(r, on_removed) == 0);                               // no list at all: nothing happens
    CHECK(!exists(r, "mods-files.applied.txt"));
    FILE *f = fopen("/dev/null", "w"); fclose(f);
    char lp[600]; snprintf(lp, sizeof lp, "%s/mods-files.txt", r);
    f = fopen(lp, "w"); fputs("sksevr_1_4_15.dll\nData/higgs_vr.esp\nData/Textures/rock.dds\nData/Textures/tree.dds\n", f); fclose(f);
    CHECK(vx_prune_pack_files(r, on_removed) == 0);                               // the first list: remembered, nothing removed
    CHECK(exists(r, "mods-files.applied.txt")); CHECK(exists(tx, "rock.dds"));
    CHECK(vx_prune_pack_files(r, on_removed) == 0);                               // the same list again
    f = fopen(lp, "w"); fputs("Data/Textures/rock.dds\r\n", f); fclose(f);        // a smaller pack (and CRLF lines)
    CHECK(vx_prune_pack_files(r, on_removed) == 3); CHECK(logged == 3);
    CHECK(!exists(ov, "sksevr_1_4_15.dll")); CHECK(!exists(dd, "higgs_vr.esp")); CHECK(!exists(tx, "tree.dds"));
    CHECK(exists(tx, "rock.dds")); CHECK(exists(dd, "game_wrote.log")); CHECK(exists(r, "outside.txt"));
    f = fopen(lp, "w"); fclose(f);                                                // no mods any more: an empty list
    CHECK(vx_prune_pack_files(r, on_removed) == 1); CHECK(!exists(tx, "rock.dds")); CHECK(exists(dd, "game_wrote.log"));
    // a remembered list that names places outside the overlay is not followed
    char ap[600]; snprintf(ap, sizeof ap, "%s/mods-files.applied.txt", r);
    f = fopen(ap, "w"); fputs("../outside.txt\n/etc/hosts\nData/../../outside.txt\nData\\game_wrote.log\nData/game_wrote.log\n", f); fclose(f);
    f = fopen(lp, "w"); fputs("Data/other.esp\n", f); fclose(f);
    CHECK(vx_prune_pack_files(r, on_removed) == 1); CHECK(exists(r, "outside.txt")); CHECK(!exists(dd, "game_wrote.log"));
    snprintf(cmd, sizeof cmd, "rm -rf %s", r); system(cmd);
    if (!fails) puts("xros_prune: ok");
    return fails ? 1 : 0;
}
