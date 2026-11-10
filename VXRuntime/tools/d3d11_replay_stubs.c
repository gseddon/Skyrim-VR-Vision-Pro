// What the Direct3D 11 replayer (tools/d3d11_replay.m) links instead of the rest of the runtime: the d3d11/dxgi
// sources' few calls into the loader, windows and Direct3D 12, none of which a replay uses (no window, no swap
// chain, no D3D12 queue). Exports register here so that D3D11CreateDevice is found by name.
#include "vx.h"
#include "ui.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

int vx_trace;
vx_process vx_proc;
__thread int vx_keyed_held;
int vx_replay_quiet;

void vx_log(const char *fmt, ...) {
    if (vx_replay_quiet) return;
    va_list ap; va_start(ap, fmt);
    fputs("[vxrt] ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}
static struct { const char *dll; const vx_export *e; size_t n; } g_mods[16];
static int g_nmods;
void vx_register_module(const char *dll, const vx_export *exports, size_t count) {
    if (g_nmods < 16) { g_mods[g_nmods].dll = dll; g_mods[g_nmods].e = exports; g_mods[g_nmods].n = count; g_nmods++; }
}
void *vx_find_export(const char *dll, const char *name) {
    for (int m = 0; m < g_nmods; m++) {
        if (strcasecmp(g_mods[m].dll, dll)) continue;
        for (size_t i = 0; i < g_mods[m].n; i++) if (!strcmp(g_mods[m].e[i].name, name)) return g_mods[m].e[i].fn;
    }
    return NULL;
}
#ifdef __aarch64__
#include "arm64.h"
void vx_defer_add(const vx_defer *d, size_t n) { (void)d; (void)n; }
void *vx_x86_return_address(void) { return NULL; }
#endif
void xv_unmap(uint64_t va, uint64_t len) { (void)va; (void)len; }
BOOL vx_handle_close(HANDLE h) { (void)h; return 1; }
HANDLE vx_handle_dup(HANDLE h) { return h; }
const vx_image *vx_image_at(uint64_t pc) { (void)pc; return NULL; }
void vx_profile_held(int delta) { (void)delta; }
const char *vx_root(void) { return "/tmp"; }
void vx_set_event(HANDLE event) { (void)event; }
void vx_shlock(volatile uint32_t *word) { while (__sync_lock_test_and_set(word, 1)) {} }
void vx_shunlock(volatile uint32_t *word) { __sync_lock_release(word); }
size_t vx_utf8_to_utf16(const char *s, size_t n, WCHAR *out, size_t cap) {
    size_t k = 0;
    for (size_t i = 0; i < n && s[i] && k + 1 < cap; i++) out[k++] = (unsigned char)s[i];
    if (cap) out[k] = 0;
    return k;
}
int vx_virtual_screen(RECT *r) { r->left = r->top = 0; r->right = 1920; r->bottom = 1080; return 1; }
vx_window *vx_window_get(HANDLE hwnd) { (void)hwnd; return NULL; }
void *vx_cocoa_metal_layer(vx_window *w, void *dev, int fmt) { (void)w; (void)dev; (void)fmt; return NULL; }
int vx_x86_stack_words(uint64_t *out, int n, uint64_t lo, uint64_t hi) { (void)out; (void)n; (void)lo; (void)hi; return 0; }
// Direct3D 12 is not part of a Direct3D 11 replay.
int d3d12_is_queue(void *p) { (void)p; return 0; }
void *d3d12_queue_metal(void *q) { (void)q; return NULL; }
void *d3d12_device_of(void *p) { (void)p; return NULL; }
typedef struct d3d12_resource_info d3d12_resource_info;
int d3d12_resource_info_get(void *resource, d3d12_resource_info *out) { (void)resource; (void)out; return 0; }
void d3d12_resource_force_state(void *resource, uint32_t state) { (void)resource; (void)state; }
uint64_t d3d12_volatile_bytes(void) { return 0; }
int32_t d3d12_swapchain_create(void *factory, void *queue, HANDLE hwnd, uint32_t w, uint32_t h, uint32_t format, uint32_t count, uint32_t flags, void **out) {
    (void)factory; (void)queue; (void)hwnd; (void)w; (void)h; (void)format; (void)count; (void)flags; if (out) *out = NULL; return (int32_t)0x80004001;
}
