// Removes SKSE plugin DLLs the deployed pack no longer lists. tools/mods.py deploy only copies (devicectl cannot delete), so a DLL from
// an older pack stays on the device and SKSE VR would load it, with no AOT module. Only *.dll directly in `dir` are considered
// (case-insensitive); nothing else (ini, logs, other folders) is touched. `keep` holds the listed DLL base names.
#ifndef VX_PRUNE_H
#define VX_PRUNE_H
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

// Returns how many files were removed. `removed` (optional) is called with each removed path.
static inline int vx_prune_skse_dlls(const char *dir, const char *const *keep, int nkeep, void (*removed)(const char *path)) {
    int n = 0; DIR *d = opendir(dir); struct dirent *e;
    if (!d) return 0;
    while ((e = readdir(d))) {
        size_t l = strlen(e->d_name);
        if (l < 5 || strcasecmp(e->d_name + l - 4, ".dll") || e->d_type == DT_DIR) continue;
        int listed = 0;
        for (int i = 0; i < nkeep; i++) if (!strcasecmp(keep[i], e->d_name)) { listed = 1; break; }
        if (listed) continue;
        char p[1800]; snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        if (!unlink(p)) { n++; if (removed) removed(p); }
    }
    closedir(d); return n;
}
#endif
