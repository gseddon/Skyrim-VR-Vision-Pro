// In-process injection and code-patch capture/verify for script-extender style DLLs (SKSE VR: research/2026-11-11-skse-vr-on-aot.md).
//
// On Windows a loader starts the game suspended and injects a DLL, which then writes branches into the game's code and
// into executable memory it allocates. Under strict AOT the guest's code is recompiled ahead of time, so those writes
// change nothing that runs. This file provides the three runtime pieces of the static scheme:
//
//  VXRT_PRELOAD=<dll>;<dll>...   loaded in this process after the program's image and TLS callbacks, before its entry
//                                point (where the injected thread's LoadLibrary ran), in order.
//  VXRT_EXEC_REGION=<dll name>   executable VirtualAlloc commits (the script extender's branch trampoline and code buffer)
//                                are served from the first section of that already loaded image, 64 KB slices in
//                                request order, zeroed. The image is a module made ahead of time from a capture, so the
//                                stubs the DLL writes there are recompiled code at the same addresses.
//  VXRT_CODE_CAPTURE=<file>      (development, Mac, translator allowed) after the preload list has run: every difference
//                                in an executable section of the images loaded before it, and the used part of the
//                                region, is written as text: "P <image> <rva> <hex>" and "R <image> <offset> <hex>".
//  VXRT_PRELOAD_EXIT=1           exit 0 once the preload list, capture and verify are done: the program never starts.
//  VXRT_CODE_VERIFY=<file>       the same lines are compared with memory after the preload list has run; any difference
//                                stops the run (exit 3): the capture the modules were made from does not describe this run.
//
// Nothing here generates code. The region's pages hold whatever the DLL writes; they are never executed as ARM64.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>
#include <pthread.h>
#include "vx.h"

#define MAXIMG 64
typedef struct { const vx_image *im; uint32_t va, n; uint8_t *copy; int exec; } snap_sec;
static snap_sec g_snap[MAXIMG * 8];
static int g_nsnap;
static uint8_t *g_region; static size_t g_region_size, g_region_used;
static const vx_image *g_region_image;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_region_failed;

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint16_t rd16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }

// Section headers of a mapped image: *n sections at the returned pointer (40 bytes each), NULL if the header is not a PE's.
static const uint8_t *sections(const vx_image *im, int *n) {
    const uint8_t *b = im->base;
    if (im->size < 0x200 || b[0] != 'M' || b[1] != 'Z') return NULL;
    uint32_t nt = rd32(b + 0x3c);
    if (nt + 24 > im->size || memcmp(b + nt, "PE\0\0", 4)) return NULL;
    *n = rd16(b + nt + 6);
    return b + nt + 24 + rd16(b + nt + 20);
}

static const vx_image *find_image(const char *name) {
    const vx_image *list[MAXIMG];
    int total = vx_image_list(list, MAXIMG);
    for (int i = 0; i < total && i < MAXIMG; i++) if (!strcasecmp(list[i]->name, name)) return list[i];
    return NULL;
}

void *vx_exec_region_alloc(size_t size) {
    const char *want = getenv("VXRT_EXEC_REGION");
    if (!want || !*want || g_region_failed) return NULL;
    pthread_mutex_lock(&g_lock);
    if (!g_region) {
        g_region_image = find_image(want);
        int n = 0;
        const uint8_t *s = g_region_image ? sections(g_region_image, &n) : NULL;
        if (!s || !n) { g_region_failed = 1; vx_log("codehooks: VXRT_EXEC_REGION %s is not a loaded image", want); pthread_mutex_unlock(&g_lock); return NULL; }
        g_region = g_region_image->base + rd32(s + 12);
        g_region_size = rd32(s + 8);
        vx_log("codehooks: executable allocations are served from %s: %p, %#zx bytes", want, (void *)g_region, g_region_size);
    }
    size_t at = (g_region_used + 0xffff) & ~(size_t)0xffff, len = (size + 0xfff) & ~(size_t)0xfff;
    void *p = NULL;
    if (at + len <= g_region_size) { p = g_region + at; memset(p, 0, len); g_region_used = at + len; }
    else vx_log("codehooks: the region is full (%#zx used of %#zx): %#zx more bytes go to the ordinary allocator", g_region_used, g_region_size, size);
    pthread_mutex_unlock(&g_lock);
    if (p) vx_log("codehooks: executable allocation of %#zx bytes -> %p (region offset %#zx)", size, p, (size_t)((uint8_t *)p - g_region));
    return p;
}

// VirtualQuery: the part of the region not yet served, as free space (0: not in it, or no region)
size_t vx_exec_region_free(const void *addr, uint8_t **base) {
    const char *want = getenv("VXRT_EXEC_REGION");
    if (!want || !*want || g_region_failed) return 0;
    pthread_mutex_lock(&g_lock);
    if (!g_region) {
        const vx_image *im = find_image(want);
        int n = 0;
        const uint8_t *s = im ? sections(im, &n) : NULL;
        if (s && n) { g_region_image = im; g_region = im->base + rd32(s + 12); g_region_size = rd32(s + 8); }
    }
    size_t r = 0;
    if (g_region) {
        size_t at = (g_region_used + 0xffff) & ~(size_t)0xffff;
        const uint8_t *a = addr;
        if (at < g_region_size && a >= g_region + at && a < g_region + g_region_size) { *base = g_region + at; r = g_region_size - at; }
    }
    pthread_mutex_unlock(&g_lock);
    return r;
}

static void snapshot(void) {
    const vx_image *list[MAXIMG];
    int total = vx_image_list(list, MAXIMG);
    for (int i = 0; i < total && i < MAXIMG; i++) {
        int n = 0;
        const uint8_t *s = sections(list[i], &n);
        for (int k = 0; s && k < n && g_nsnap < MAXIMG * 8; k++, s += 40) {
            uint32_t ch = rd32(s + 36);
            int exec = (ch & 0x20000000) != 0;                          // IMAGE_SCN_MEM_EXECUTE; writable data too (vtable swaps that point into the region)
            if (!exec && !(ch & 0x80000000)) continue;
            uint32_t va = rd32(s + 12), len = rd32(s + 8);
            if (va + (uint64_t)len > list[i]->size) continue;
            snap_sec *e = &g_snap[g_nsnap++];
            e->im = list[i]; e->va = va; e->n = len; e->exec = exec; e->copy = malloc(len ? len : 1);
            memcpy(e->copy, list[i]->base + va, len);
        }
    }
}

static void hex_out(FILE *f, const uint8_t *p, size_t n) { for (size_t i = 0; i < n; i++) fprintf(f, "%02x", p[i]); }

static int capture(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) { vx_log("codehooks: cannot write %s", path); return 1; }
    size_t runs = 0, bytes = 0;
    for (int i = 0; i < g_nsnap; i++) {
        const snap_sec *e = &g_snap[i];
        const uint8_t *now = e->im->base + e->va;
        if (!e->exec) continue;
        for (uint32_t k = 0; k < e->n;) {
            if (now[k] == e->copy[k]) { k++; continue; }
            uint32_t last = k;                                  // (a run: gaps of up to 3 equal bytes stay inside it)
            for (uint32_t j = k; j < e->n && j - last <= 3; j++) if (now[j] != e->copy[j]) last = j;
            uint32_t a = k >= 6 ? k - 6 : 0;                           // (up to six unchanged bytes of context: the opcode of a rel32 branch or FF 15 even when low displacement bytes happen to match)
            fprintf(f, "P %s %x ", e->im->name, e->va + a);
            hex_out(f, now + a, last + 1 - a);
            fprintf(f, "\n");
            runs++; bytes += last + 1 - a; k = last + 1;
        }
    }
    if (g_region && g_region_used) {   // "T <image> <rva> <qword>": every pointer into the used region in a writable data section of any loaded image
        const vx_image *list[MAXIMG];                           // (the extender's own globals: the address of a stub that calls the original code; vtable swaps)
        int total = vx_image_list(list, MAXIMG);
        for (int i = 0; i < total && i < MAXIMG; i++) {
            int n = 0;
            const uint8_t *s = sections(list[i], &n);
            for (int q = 0; s && q < n; q++, s += 40) {
                uint32_t ch = rd32(s + 36);
                if ((ch & 0x20000000) || !(ch & 0x80000000)) continue;
                uint32_t va = rd32(s + 12), len = rd32(s + 8);
                if (va + (uint64_t)len > list[i]->size) continue;
                for (uint32_t k = 0; k + 8 <= len; k += 8) {
                    uint64_t v; memcpy(&v, list[i]->base + va + k, 8);
                    if (v >= (uint64_t)(uintptr_t)g_region && v < (uint64_t)(uintptr_t)g_region + g_region_used)
                        fprintf(f, "T %s %x %016llx\n", list[i]->name, va + k, (unsigned long long)v);
                }
            }
        }
        fprintf(f, "R %s %x ", g_region_image->name, (unsigned)(g_region - g_region_image->base));
        hex_out(f, g_region, g_region_used);
        fprintf(f, "\n");
    }
    fclose(f);
    vx_log("codehooks: capture %s: %zu code runs (%zu bytes) in loaded images, %zu bytes of region", path, runs, bytes, g_region_used);
    return 0;
}

static int unhex(const char *s, uint8_t *out, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(s + 2 * i, "%2x", &v) != 1) return 0;
        out[i] = (uint8_t)v;
    }
    return 1;
}

static int verify(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { vx_log("codehooks: cannot read %s", path); return 1; }
    size_t cap = 1 << 20; char *line = malloc(cap);
    size_t sites = 0, bad = 0;
    while (fgets(line, (int)cap, f)) {
        char kind, name[128]; unsigned off; int used = 0;
        if (sscanf(line, "%c %127s %x %n", &kind, name, &off, &used) != 3 || !used) continue;
        if (kind == 'T') continue;                                      // (a pointer into the region written into data: roots for the module only)
        size_t hn = strcspn(line + used, "\r\n") / 2;
        uint8_t *want = malloc(hn ? hn : 1);
        if (!unhex(line + used, want, hn)) { bad++; free(want); continue; }
        const vx_image *im = find_image(name);
        sites++;
        if (!im || off + (uint64_t)hn > im->size) { vx_log("codehooks: verify: %s +%#x is not in a loaded image", name, off); bad++; }
        else if (memcmp(im->base + off, want, hn)) {
            size_t d = 0; while (im->base[off + d] == want[d]) d++;
            vx_log("codehooks: verify: %s +%#x differs from the capture at byte %zu (have %02x, capture %02x)", name, off, d, im->base[off + d], want[d]);
            bad++;
        }
        free(want);
    }
    fclose(f); free(line);
    vx_log("codehooks: verify %s: %zu entries, %zu differ", path, sites, bad);
    return bad ? 1 : 0;
}


// ---- late writes -------------------------------------------------------------------------------------------------------
// Plugins install hooks in their messaging handlers (kPostLoad, kDataLoaded, after the main menu), on first use or on a config
// reload, not only in DllMain. Two pieces keep a missing capture from being silent:
//  VXRT_CODE_CAPTURE_AT=<seconds>  the capture is written that many seconds after the preload list (the dev run goes on to the
//                                  main menu or past kDataLoaded); VXRT_CODE_CAPTURE_EXIT=1 then ends the run.
//  VXRT_CODE_WATCH=<ms>            a thread compares every executable section of the images loaded before the preload, and the
//                                  region, with what they held after it (baseline) every <ms> milliseconds. A byte that is not
//                                  the baseline's and not the capture's (VXRT_CODE_VERIFY) is a code write the modules were not
//                                  made from: logged with the address, and with VXRT_AOT_STRICT the run stops (exit 3).
//                                  The initial verify is replaced by this: a site not yet written is fine, a wrong one is not.
typedef struct { snap_sec *s; uint8_t *base, *want; } watch_sec;
static watch_sec g_watch[MAXIMG * 8]; static int g_nwatch;
static uint8_t *g_rbase, *g_rwant; static size_t g_rused0, g_rwant_len;
static int g_watch_ms;

static void watch_load(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { vx_log("codehooks: cannot read %s", path); exit(3); }
    size_t cap = 1 << 22; char *line = malloc(cap);
    while (fgets(line, (int)cap, f)) {
        char kind, name[128]; unsigned off; int used = 0;
        if (sscanf(line, "%c %127s %x %n", &kind, name, &off, &used) != 3 || !used || (kind != 'P' && kind != 'R')) continue;
        size_t hn = strcspn(line + used, "\r\n") / 2;
        uint8_t *b = malloc(hn ? hn : 1);
        if (!unhex(line + used, b, hn)) { free(b); continue; }
        if (kind == 'R') { g_rwant = b; g_rwant_len = hn; continue; }
        for (int i = 0; i < g_nwatch; i++) {
            snap_sec *e = g_watch[i].s;
            if (strcasecmp(e->im->name, name) || off + hn <= e->va || off >= e->va + e->n) continue;
            for (size_t k = 0; k < hn; k++) if (off + k >= e->va && off + k < e->va + e->n) g_watch[i].want[off + k - e->va] = b[k];
        }
        free(b);
    }
    fclose(f); free(line);
}
static void late_fail(const char *what, const char *image, uint32_t at, int live, int base, int want) {
    vx_log("codehooks: LATE CODE WRITE not in the capture: %s %s +%#x (live %02x, after preload %02x, capture %02x): "
           "capture a run that reaches the code that writes it (VXRT_CODE_CAPTURE_AT)", what, image, at, live, base, want);
    const char *st = getenv("VXRT_AOT_STRICT");
    if (st && atoi(st)) { vx_log("codehooks: VXRT_AOT_STRICT: stopping"); fflush(NULL); _exit(3); }
}
static void watch_once(void) {
    for (int i = 0; i < g_nwatch; i++) {
        snap_sec *e = g_watch[i].s; const uint8_t *live = e->im->base + e->va;
        if (!memcmp(live, g_watch[i].base, e->n) || !memcmp(live, g_watch[i].want, e->n)) continue;
        for (uint32_t k = 0; k < e->n; k++)
            if (live[k] != g_watch[i].base[k] && live[k] != g_watch[i].want[k]) { late_fail("code", e->im->name, e->va + k, live[k], g_watch[i].base[k], g_watch[i].want[k]); break; }
        // (writes that are in the capture are fine; the log says nothing about them)
    }
    if (g_region) {
        pthread_mutex_lock(&g_lock); size_t used = g_region_used; pthread_mutex_unlock(&g_lock);
        if (used > g_rwant_len) late_fail("executable allocation beyond the capture's region", g_region_image->name, (uint32_t)used, 0, 0, 0);
        for (size_t k = 0; k < used && k < g_rwant_len; k++) {
            uint8_t l = g_region[k], b = k < g_rused0 ? g_rbase[k] : 0, w = g_rwant[k];
            if (l != b && l != w) { late_fail("region", g_region_image->name, (uint32_t)k + 0x1000, l, b, w); break; }
        }
    }
}
static void *watch_thread(void *arg) {
    (void)arg;
    for (;;) { struct timespec ts = { g_watch_ms / 1000, (g_watch_ms % 1000) * 1000000L }; nanosleep(&ts, NULL); watch_once(); }
    return NULL;
}
static void *capture_at_thread(void *arg) {
    int secs = (int)(intptr_t)arg;
    sleep((unsigned)secs);
    capture(getenv("VXRT_CODE_CAPTURE"));
    if (getenv("VXRT_CODE_CAPTURE_EXIT") && atoi(getenv("VXRT_CODE_CAPTURE_EXIT"))) { fflush(NULL); _exit(0); }
    return NULL;
}
static void watch_start(void) {
    g_watch_ms = atoi(getenv("VXRT_CODE_WATCH"));
    if (g_watch_ms < 50) g_watch_ms = 50;
    for (int i = 0; i < g_nsnap; i++) {
        snap_sec *e = &g_snap[i];
        if (!e->exec) continue;
        watch_sec *w = &g_watch[g_nwatch++];
        w->s = e; w->base = malloc(e->n ? e->n : 1); w->want = malloc(e->n ? e->n : 1);
        memcpy(w->base, e->im->base + e->va, e->n); memcpy(w->want, w->base, e->n);
    }
    pthread_mutex_lock(&g_lock);
    g_rused0 = g_region_used; g_rbase = malloc(g_rused0 ? g_rused0 : 1);
    if (g_region) memcpy(g_rbase, g_region, g_rused0);
    pthread_mutex_unlock(&g_lock);
    const int have_capture = getenv("VXRT_CODE_VERIFY") != NULL;
    if (have_capture) watch_load(getenv("VXRT_CODE_VERIFY"));
    else {                                                      // (observe only: everything written later is reported, nothing is expected)
        g_rwant_len = g_rused0; g_rwant = malloc(g_rused0 ? g_rused0 : 1);
        if (g_region) memcpy(g_rwant, g_region, g_rused0);
    }
    // what the preload list wrote must already be the capture's (a site not yet written still holds the original)
    for (int i = 0; have_capture && i < g_nwatch; i++) {
        snap_sec *e = g_watch[i].s;
        for (uint32_t k = 0; k < e->n; k++) {
            uint8_t b = g_watch[i].base[k];
            if (b != e->copy[k] && b != g_watch[i].want[k]) {
                vx_log("codehooks: verify: %s +%#x differs from the capture (have %02x, original %02x, capture %02x)", e->im->name, e->va + k, b, e->copy[k], g_watch[i].want[k]);
                vx_log("codehooks: VXRT_CODE_VERIFY: the code in memory is not the capture the modules were made from; stopping"); fflush(NULL); _exit(3);
            }
        }
    }
    for (size_t k = 0; have_capture && g_region && k < g_rused0; k++) {
        if (g_rbase[k] && (k >= g_rwant_len || g_rbase[k] != g_rwant[k])) {
            vx_log("codehooks: verify: %s +%#zx differs from the capture (have %02x)", g_region_image->name, k + 0x1000, g_rbase[k]);
            vx_log("codehooks: VXRT_CODE_VERIFY: the code in memory is not the capture the modules were made from; stopping"); fflush(NULL); _exit(3);
        }
    }
    pthread_t t; pthread_create(&t, NULL, watch_thread, NULL); pthread_detach(t);
    vx_log("codehooks: watching %d executable sections and the region every %d ms for code writes outside the capture", g_nwatch, g_watch_ms);
}

// Called by the loader once the program's image is mapped and its imports are bound.
void vx_codehooks_preload(void) {
    const char *list = getenv("VXRT_PRELOAD");
    if (!list || !*list) return;
    void *(WINAPI *load)(const char *) = (void *(WINAPI *)(const char *))vx_find_export("kernel32.dll", "LoadLibraryA");
    if (!load) return;
    snapshot();
    char *copy = strdup(list), *save = NULL;
    for (char *p = strtok_r(copy, ";", &save); p; p = strtok_r(NULL, ";", &save)) {
        void *h = load(p);
        vx_log("codehooks: preload %s -> %p", p, h);
        if (!h && !getenv("VXRT_PRELOAD_OPTIONAL")) { vx_log("codehooks: preload failed; stopping"); exit(3); }
    }
    free(copy);
    int watching = getenv("VXRT_CODE_WATCH") && atoi(getenv("VXRT_CODE_WATCH")) > 0;
    if (getenv("VXRT_CODE_CAPTURE") && getenv("VXRT_CODE_CAPTURE_AT")) {
        pthread_t t; pthread_create(&t, NULL, capture_at_thread, (void *)(intptr_t)atoi(getenv("VXRT_CODE_CAPTURE_AT"))); pthread_detach(t);
    } else if (getenv("VXRT_CODE_CAPTURE")) capture(getenv("VXRT_CODE_CAPTURE"));
    if (watching) watch_start();
    else if (getenv("VXRT_CODE_VERIFY") && verify(getenv("VXRT_CODE_VERIFY"))) {
        vx_log("codehooks: VXRT_CODE_VERIFY: the code in memory is not the capture the modules were made from; stopping");
        exit(3);
    }
    if (getenv("VXRT_PRELOAD_EXIT") && atoi(getenv("VXRT_PRELOAD_EXIT"))) { vx_log("codehooks: VXRT_PRELOAD_EXIT: stopping before the program's entry point"); fflush(NULL); _exit(0); }   // (a capture run needs no game)
}
