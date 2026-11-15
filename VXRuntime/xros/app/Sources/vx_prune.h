// Removes SKSE plugin DLLs the deployed pack no longer lists. tools/mods.py deploy only copies (devicectl cannot delete), so a DLL from
// an older pack stays on the device and SKSE VR would load it, with no AOT module. Only *.dll directly in `dir` are considered
// (case-insensitive); nothing else (ini, logs, other folders) is touched. `keep` holds the listed DLL base names.
#ifndef VX_PRUNE_H
#define VX_PRUNE_H
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
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

// A mod pack that was put on the device leaves its files behind when the next pack has fewer (devicectl cannot delete). An installer
// that deploys packs says which files belong to the one it just put there: <root>/mods-files.txt, one path per line, relative to
// <root>/overlay_skyrimvr (tools/avpplay_toolchain/visionos/stage_sync.py). The app remembers the list it last acted on beside it
// (mods-files.applied.txt). At a start with a new list, every file of the remembered one that the new one no longer names is removed,
// then the new list is remembered. Only files a pack brought are ever touched: what the game or a mod wrote into the overlay (logs,
// settings, the shader cache) was in no list. A line with "..", an absolute path or a backslash is ignored. Returns the number of
// files removed, 0 when there is no list or it is the remembered one. `removed` (optional) is called with each removed path.
static inline char *vx_prune_slurp(const char *path, long *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *t = n >= 0 ? (char *)malloc((size_t)n + 2) : NULL;
    if (t && fread(t, 1, (size_t)n, f) != (size_t)n) { free(t); t = NULL; }
    fclose(f);
    if (t) { t[n] = '\n'; t[n + 1] = 0; if (size) *size = n; }
    return t;
}
static inline int vx_prune_line_ok(const char *l, size_t n) {
    if (!n || l[0] == '/' || memchr(l, '\\', n)) return 0;
    for (size_t i = 0; i + 1 < n; i++) if (l[i] == '.' && l[i + 1] == '.' && (i == 0 || l[i - 1] == '/') && (i + 2 == n || l[i + 2] == '/')) return 0;
    return 1;
}
static inline int vx_prune_listed(const char *list, const char *l, size_t n) {   // a whole line of `list` equal to l[0..n)
    for (const char *p = list; *p;) {
        const char *e = strchr(p, '\n'); if (!e) e = p + strlen(p);
        size_t m = (size_t)(e - p); if (m && p[m - 1] == '\r') m--;
        if (m == n && !memcmp(p, l, n)) return 1;
        p = *e ? e + 1 : e;
    }
    return 0;
}
static inline int vx_prune_pack_files(const char *root, void (*removed)(const char *path)) {
    char now_path[1700], was_path[1700];
    snprintf(now_path, sizeof now_path, "%s/mods-files.txt", root);
    snprintf(was_path, sizeof was_path, "%s/mods-files.applied.txt", root);
    long now_n = 0, was_n = 0;
    char *now = vx_prune_slurp(now_path, &now_n);
    if (!now) return 0;
    char *was = vx_prune_slurp(was_path, &was_n);
    int n = 0;
    if (was && (was_n != now_n || memcmp(was, now, (size_t)now_n))) {
        for (const char *p = was; *p;) {
            const char *e = strchr(p, '\n'); if (!e) e = p + strlen(p);
            size_t m = (size_t)(e - p); if (m && p[m - 1] == '\r') m--;
            if (vx_prune_line_ok(p, m) && !vx_prune_listed(now, p, m)) {
                char f[3600]; snprintf(f, sizeof f, "%s/overlay_skyrimvr/%.*s", root, (int)m, p);
                if (!unlink(f)) { n++; if (removed) removed(f); }
            }
            p = *e ? e + 1 : e;
        }
    }
    if (!was || was_n != now_n || memcmp(was, now, (size_t)now_n)) {
        char tmp[1750]; snprintf(tmp, sizeof tmp, "%s.tmp", was_path);
        FILE *f = fopen(tmp, "wb");
        if (f) { int ok = fwrite(now, 1, (size_t)now_n, f) == (size_t)now_n; ok = !fclose(f) && ok; if (ok) rename(tmp, was_path); else unlink(tmp); }
    }
    free(now); free(was);
    return n;
}
#endif
