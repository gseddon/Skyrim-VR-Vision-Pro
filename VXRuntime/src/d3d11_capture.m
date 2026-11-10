// Direct3D 11 capture: VXRT_D3D11_CAPTURE=<file> records the program's Direct3D 11 calls for tools/d3d11_replay.m
// (stream format: d3d11_capture.h). Off unless the variable is set; then d3d11.m's method tables get wrappers here
// that write each call and call the method they replaced. The capture starts at device creation: textures made
// without contents, every upload (initial data, UpdateSubresource, bytes written through Map at their Unmap), every
// shader, state object, view, binding, draw, dispatch, clear, copy and resolve, presents and the VR eye images.
// Reads back (Map for reading) are only noted. Deferred contexts, Direct3D 11.1 methods and Direct3D 12 are not
// captured: they are not implemented here, or a program calling them is told so by d3d_not_implemented.
//
// VXRT_D3D11_CAPTURE_FRAMES=<n>: stop after n presents. VXRT_D3D11_CAPTURE_EYE_FRAMES=<n>: stop after the VR frame
// with id n (the dev host's frame numbers). Without either the capture goes on until the process ends.
#include "d3d_common.h"
#include "d3d11_capture.h"
#include <pthread.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunused-variable"
#include "d3d_tables.h"
#pragma clang diagnostic pop

int d3d11_vtable_slot(int context, const char *name) {
    const char *const *names = context ? vt_ID3D11DeviceContext1 : vt_ID3D11Device1;
    int n = context ? VT_COUNT_ID3D11DeviceContext1 : VT_COUNT_ID3D11Device1;
    for (int i = 0; i < n; i++) if (!strcmp(names[i], name)) return i;
    return -1;
}

// The originals are this runtime's functions: native code with the Windows convention only in the x86-64 build.
#if defined(__aarch64__) || defined(VX_ABI_SCAN)
#define ORIG
#else
#define ORIG __attribute__((ms_abi))
#endif

volatile int d3d11_capture_on;
static FILE *g_file;
static pthread_mutex_t g_lock;
static uint32_t g_next_id = 1;
static uint64_t g_presents, g_limit_presents, g_limit_eye, g_records, g_bytes;
static int g_installed;

// ---- objects: pointer -> id --------------------------------------------------------------------------------------
typedef struct node { const void *p; uint32_t id; struct node *next; } node;
static node *g_ids[1 << 16];
static size_t bucket(const void *p) { uintptr_t v = (uintptr_t)p; return (size_t)((v >> 4) ^ (v >> 20)) & 0xffff; }
static uint32_t find_id(const void *p) {
    for (node *n = g_ids[bucket(p)]; n; n = n->next) if (n->p == p) return n->id;
    return 0;
}
static uint32_t new_id(const void *p) {
    node *n = malloc(sizeof *n);
    n->p = p; n->id = g_next_id++; n->next = g_ids[bucket(p)]; g_ids[bucket(p)] = n;
    return n->id;
}
static uint32_t forget_id(const void *p) {
    for (node **l = &g_ids[bucket(p)]; *l; l = &(*l)->next)
        if ((*l)->p == p) { node *n = *l; uint32_t id = n->id; *l = n->next; free(n); return id; }
    return 0;
}

// ---- records ---------------------------------------------------------------------------------------------------------
// A record is built in a buffer, then written whole (header and payload). Records made while one is being built
// (an object first seen in a call) go to the file first, through the second buffer.
typedef struct { uint8_t *p; size_t n, cap; } rbuf;
static rbuf g_rec, g_side;
static rbuf *g_cur = &g_rec;
static void put(const void *d, size_t n) {
    rbuf *b = g_cur;
    if (b->n + n > b->cap) { b->cap = (b->n + n) * 2 + 4096; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->n, d, n); b->n += n;
}
static void u32(uint32_t v) { put(&v, 4); }
static void f32(float v) { put(&v, 4); }
static void str(const char *s) { uint32_t n = s ? (uint32_t)strlen(s) : 0; u32(n); put(s ? s : "", n); }
static void bytes(const void *d, size_t n) { u32((uint32_t)n); if (n) put(d, n); }
static void begin(uint32_t op) { put(&op, 4); uint32_t len = 0; put(&len, 4); }
static void end(void) {
    rbuf *b = g_cur;
    uint32_t len = (uint32_t)(b->n - 8);
    memcpy(b->p + 4, &len, 4);
    if (g_file && fwrite(b->p, 1, b->n, g_file) != b->n) { vx_log("Direct3D capture: write failed; capture stopped"); fclose(g_file); g_file = NULL; d3d11_capture_on = 0; }
    g_records++; g_bytes += b->n;
    b->n = 0;
}

static void foreign(const d3d_object *o, uint32_t id) {
    rbuf *was = g_cur; g_cur = &g_side;
    uint32_t dev = o->dev ? find_id(o->dev) : 0;
    if (o->kind == K_TEXTURE) {
        const d3d_texture *t = (const d3d_texture *)o;
        begin(D3DCAP_FOREIGN_TEXTURE); u32(dev); u32(id); u32(t->dim); u32(t->depth);
        for (int i = 0; i < TD_COUNT; i++) u32(t->desc[i]);
    } else {
        const d3d_buffer *b = (const d3d_buffer *)o;
        begin(D3DCAP_FOREIGN_BUFFER); u32(dev); u32(id);
        for (int i = 0; i < 6; i++) u32(b->desc[i]);
    }
    end();
    g_cur = was;
}
// The id of an object a call names (0 for NULL). A texture or buffer not made through a wrapped method (a swap
// chain's buffer, an opened shared resource) is described now; another unknown object is 0 (noted once).
static uint32_t oid(const void *p) {
    if (!p) return 0;
    uint32_t id = find_id(p);
    if (id) return id;
    const d3d_object *o = p;
    if (o->kind == K_TEXTURE || o->kind == K_BUFFER) { id = new_id(p); foreign(o, id); return id; }
    static int told;
    if (told++ < 8) vx_log("Direct3D capture: an object of kind %d was not seen made; recorded as none", o->kind);
    return 0;
}

static int lock(void) {
    if (!d3d11_capture_on) return 0;
    pthread_mutex_lock(&g_lock);
    if (!d3d11_capture_on || !g_file) { pthread_mutex_unlock(&g_lock); return 0; }
    return 1;
}
static void unlock(void) { pthread_mutex_unlock(&g_lock); }
static void stop(const char *why) {
    if (!g_file) return;
    begin(D3DCAP_END); u32((uint32_t)g_presents); end();
    fclose(g_file); g_file = NULL;
    d3d11_capture_on = 0;
    vx_log("Direct3D capture: ended (%s): %llu records, %llu MB", why, (unsigned long long)g_records, (unsigned long long)(g_bytes >> 20));
}
static void frame_end(void) {
    fflush(g_file);
    static uint64_t frames;
    if (++frames % 300 == 0) vx_log("Direct3D capture: %llu frames, %llu records, %llu MB", (unsigned long long)frames, (unsigned long long)g_records, (unsigned long long)(g_bytes >> 20));
}

// ---- layout of texture data --------------------------------------------------------------------------------------
typedef struct { uint32_t w, h, d, row_bytes, rows; } region;
static void block_of(uint32_t format, uint32_t *bw, uint32_t *bh, uint32_t *bpb) {
    if (d3d_copy_format_block(format, bw, bh, bpb) && *bpb) return;
    uint32_t bpp = 0;
    d3d_mtl_format(format, &bpp);
    *bw = *bh = 1; *bpb = bpp ? bpp : 4;
}
static region texture_region(const d3d_texture *t, uint32_t sub, const uint32_t *box) {
    uint32_t mips = t->desc[TD_MIPS] ? t->desc[TD_MIPS] : 1, mip = sub % mips;
    region r;
    if (box) { r.w = box[3] - box[0]; r.h = box[4] - box[1]; r.d = box[5] - box[2]; }
    else {
        r.w = t->desc[TD_WIDTH] >> mip; if (!r.w) r.w = 1;
        r.h = t->dim > 1 ? t->desc[TD_HEIGHT] >> mip : 1; if (!r.h) r.h = 1;
        r.d = t->dim == 3 ? t->depth >> mip : 1; if (!r.d) r.d = 1;
    }
    uint32_t bw, bh, bpb;
    block_of(t->desc[TD_FORMAT], &bw, &bh, &bpb);
    r.row_bytes = (r.w + bw - 1) / bw * bpb;
    r.rows = (r.h + bh - 1) / bh;
    return r;
}
// The rows of one subresource region, tightly packed.
static void packed(const void *data, uint32_t pitch, uint32_t slice_pitch, region r) {
    size_t total = (size_t)r.row_bytes * r.rows * r.d;
    u32((uint32_t)total);
    for (uint32_t z = 0; z < r.d; z++)
        for (uint32_t y = 0; y < r.rows; y++)
            put((const uint8_t *)data + (size_t)z * slice_pitch + (size_t)y * pitch, r.row_bytes);
}

// ---- Map: the bytes the program wrote, at Unmap, as the runs that differ from what it wrote before -------------------
typedef struct map_shadow { uint64_t key; uint8_t *data; size_t size; struct map_shadow *next; } map_shadow;
static map_shadow *g_shadows[4096];
static map_shadow *shadow_of(uint32_t id, uint32_t sub, size_t size) {
    uint64_t key = (uint64_t)id << 32 | sub;
    map_shadow **l = &g_shadows[(id * 31 + sub) & 4095];
    for (map_shadow *s = *l; s; s = s->next)
        if (s->key == key) {
            if (s->size != size) { free(s->data); s->data = calloc(1, size ? size : 1); s->size = size; }
            return s;
        }
    map_shadow *s = calloc(1, sizeof *s);
    s->key = key; s->data = calloc(1, size ? size : 1); s->size = size; s->next = *l; *l = s;
    return s;
}
static void shadows_forget(uint32_t id) {
    for (int i = 0; i < 4096; i++)
        for (map_shadow **l = &g_shadows[i]; *l;) {
            if ((uint32_t)((*l)->key >> 32) == id) { map_shadow *s = *l; *l = s->next; free(s->data); free(s); }
            else l = &(*l)->next;
        }
}
typedef struct { const void *res; uint32_t sub, type, flags, row, depth; uint8_t *data; size_t size; } open_map;
static open_map g_maps[64];
static int g_nmaps;
static void runs(map_shadow *s, const uint8_t *now) {
    size_t n = s->size;
    if (memcmp(s->data, now, n)) {
        const size_t blk = 64;
        size_t at = 0;
        while (at < n) {
            size_t len = n - at < blk ? n - at : blk;
            if (!memcmp(s->data + at, now + at, len)) { at += len; continue; }
            size_t from = at;
            while (at < n) {
                len = n - at < blk ? n - at : blk;
                if (!memcmp(s->data + at, now + at, len)) break;
                at += len;
            }
            u32((uint32_t)from); u32((uint32_t)(at - from)); put(now + from, at - from);
            memcpy(s->data + from, now + from, at - from);
        }
    }
    u32(0xffffffffu);
}

// ---- the wrappers ----------------------------------------------------------------------------------------------------
typedef struct { const void *data; uint32_t pitch, slice_pitch; } SUBRESOURCE_DATA;
typedef struct { void *data; uint32_t row_pitch, depth_pitch; } MAPPED;
typedef struct { const char *semantic; uint32_t index, format, slot, offset, classification, step; } INPUT_ELEMENT;
typedef struct { uint32_t stream; const char *semantic; uint32_t index; uint8_t start, count, slot; } so_decl;

static HRESULT (ORIG *o_create_buffer)(void *, const uint32_t *, const SUBRESOURCE_DATA *, void **);
static WINAPI HRESULT w_create_buffer(void *this, const uint32_t *desc, const SUBRESOURCE_DATA *init, void **out) {
    HRESULT hr = o_create_buffer(this, desc, init, out);
    if (hr == S_OK && out && *out && lock()) {
        uint32_t id = new_id(*out);
        begin(D3DCAP_BUFFER); u32(oid(this)); u32(id);
        for (int i = 0; i < 6; i++) u32(desc[i]);
        u32(init && init->data ? 1 : 0);
        if (init && init->data) bytes(init->data, desc[0]);
        end(); unlock();
    }
    return hr;
}
static HRESULT (ORIG *o_create_tex[3])(void *, const uint32_t *, const SUBRESOURCE_DATA *, void **);
static void record_texture(void *this, int dim, const uint32_t *desc, const SUBRESOURCE_DATA *init, void *out) {
    const d3d_texture *t = out;
    uint32_t id = new_id(out), words = dim == 1 ? 8 : dim == 2 ? 11 : 9;
    begin(D3DCAP_TEXTURE); u32(oid(this)); u32(id); u32((uint32_t)dim); u32(words);
    for (uint32_t i = 0; i < words; i++) u32(desc[i]);
    uint32_t subs = (t->desc[TD_MIPS] ? t->desc[TD_MIPS] : 1) * (t->desc[TD_ARRAY] ? t->desc[TD_ARRAY] : 1);
    u32(subs); u32(init ? 1 : 0);
    if (init)
        for (uint32_t s = 0; s < subs; s++) {
            u32(init[s].data ? 1 : 0);
            if (!init[s].data) continue;
            region r = texture_region(t, s, NULL);
            u32(r.row_bytes); u32(r.rows); u32(r.d);
            packed(init[s].data, init[s].pitch, init[s].slice_pitch, r);
        }
    end();
}
#define TEXTURE_WRAPPER(n) \
    static WINAPI HRESULT w_create_tex##n(void *this, const uint32_t *desc, const SUBRESOURCE_DATA *init, void **out) { \
        HRESULT hr = o_create_tex[n - 1](this, desc, init, out); \
        if (hr == S_OK && out && *out && lock()) { record_texture(this, n, desc, init, *out); unlock(); } \
        return hr; \
    }
TEXTURE_WRAPPER(1) TEXTURE_WRAPPER(2) TEXTURE_WRAPPER(3)

static HRESULT (ORIG *o_create_view[4])(void *, d3d_object *, const uint32_t *, void **);
static void record_view(void *this, int kind, d3d_object *res, const uint32_t *desc, void *out) {
    begin(D3DCAP_VIEW); u32(oid(this)); uint32_t r = oid(res); u32(new_id(out)); u32((uint32_t)kind); u32(r); u32(desc ? 1 : 0);
    // SRV and DSV descriptions are 6 words, RTV and UAV 5
    uint32_t n = kind == 0 || kind == 2 ? 6 : 5;
    for (uint32_t i = 0; i < 6; i++) u32(desc && i < n ? desc[i] : 0);
    end();
}
#define VIEW_WRAPPER(k) \
    static WINAPI HRESULT w_create_view##k(void *this, d3d_object *res, const uint32_t *desc, void **out) { \
        HRESULT hr = o_create_view[k](this, res, desc, out); \
        if (hr == S_OK && out && *out && lock()) { record_view(this, k, res, desc, *out); unlock(); } \
        return hr; \
    }
VIEW_WRAPPER(0) VIEW_WRAPPER(1) VIEW_WRAPPER(2) VIEW_WRAPPER(3)

static HRESULT (ORIG *o_create_shader[4])(void *, const void *, size_t, void *, void **);
#define SHADER_WRAPPER(k) \
    static WINAPI HRESULT w_create_shader##k(void *this, const void *code, size_t size, void *linkage, void **out) { \
        HRESULT hr = o_create_shader[k](this, code, size, linkage, out); \
        if (hr == S_OK && out && *out && lock()) { \
            begin(D3DCAP_SHADER); u32(oid(this)); u32(new_id(*out)); u32(k); bytes(code, size); end(); unlock(); \
        } \
        return hr; \
    }
SHADER_WRAPPER(0) SHADER_WRAPPER(1) SHADER_WRAPPER(2) SHADER_WRAPPER(3)
static HRESULT (ORIG *o_create_gs_so)(void *, const void *, size_t, const so_decl *, uint32_t, const uint32_t *, uint32_t, uint32_t, void *, void **);
static WINAPI HRESULT w_create_gs_so(void *this, const void *code, size_t size, const so_decl *decl, uint32_t ndecl,
                                     const uint32_t *strides, uint32_t nstrides, uint32_t rasterized, void *linkage, void **out) {
    HRESULT hr = o_create_gs_so(this, code, size, decl, ndecl, strides, nstrides, rasterized, linkage, out);
    if (hr == S_OK && out && *out && lock()) {
        begin(D3DCAP_SHADER); u32(oid(this)); u32(new_id(*out)); u32(4); bytes(code, size);
        u32(decl ? ndecl : 0);
        for (uint32_t i = 0; decl && i < ndecl; i++) {
            u32(decl[i].stream); str(decl[i].semantic); u32(decl[i].index); u32(decl[i].start); u32(decl[i].count); u32(decl[i].slot);
        }
        u32(strides ? nstrides : 0);
        for (uint32_t i = 0; strides && i < nstrides; i++) u32(strides[i]);
        u32(rasterized);
        end(); unlock();
    }
    return hr;
}
static HRESULT (ORIG *o_create_layout)(void *, const INPUT_ELEMENT *, uint32_t, const void *, size_t, void **);
static WINAPI HRESULT w_create_layout(void *this, const INPUT_ELEMENT *els, uint32_t n, const void *code, size_t size, void **out) {
    HRESULT hr = o_create_layout(this, els, n, code, size, out);
    if (hr == S_OK && out && *out && lock()) {
        begin(D3DCAP_LAYOUT); u32(oid(this)); u32(new_id(*out)); u32(n);
        for (uint32_t i = 0; i < n; i++) {
            str(els[i].semantic); u32(els[i].index); u32(els[i].format); u32(els[i].slot); u32(els[i].offset);
            u32(els[i].classification); u32(els[i].step);
        }
        bytes(code, size);
        end(); unlock();
    }
    return hr;
}
// blend, depth-stencil, rasterizer, sampler, query, predicate: their descriptions' sizes
static const uint32_t g_state_size[6] = { 264, 52, 40, 52, 8, 8 };
static HRESULT (ORIG *o_create_state[6])(void *, const uint32_t *, void **);
#define STATE_WRAPPER(k) \
    static WINAPI HRESULT w_create_state##k(void *this, const uint32_t *desc, void **out) { \
        HRESULT hr = o_create_state[k](this, desc, out); \
        if (hr == S_OK && out && *out && lock()) { \
            begin(D3DCAP_STATE); u32(oid(this)); u32(new_id(*out)); u32(k); bytes(desc, g_state_size[k]); end(); unlock(); \
        } \
        return hr; \
    }
STATE_WRAPPER(0) STATE_WRAPPER(1) STATE_WRAPPER(2) STATE_WRAPPER(3) STATE_WRAPPER(4) STATE_WRAPPER(5)

// Context methods. CALL(m) starts the record (the method, the context); the original runs after it is written.
#define CALL(m) begin(D3DCAP_CALL); u32(D3DCAP_M_##m); u32(oid(this))
static void ids(uint32_t n, void *const *objs) { u32(objs ? 1 : 0); for (uint32_t i = 0; objs && i < n; i++) u32(oid(objs[i])); }
static void words(uint32_t n, const void *w) { u32(w ? 1 : 0); if (w) put(w, (size_t)n * 4); }

static void (ORIG *o_list[12])(void *, uint32_t, uint32_t, void *const *);
#define LIST_WRAPPER(k, m) \
    static WINAPI void w_##m(void *this, uint32_t start, uint32_t n, void *const *objs) { \
        if (lock()) { CALL(m); u32(start); u32(n); ids(n, objs); end(); unlock(); } \
        o_list[k](this, start, n, objs); \
    }
LIST_WRAPPER(0, VSSetConstantBuffers) LIST_WRAPPER(1, PSSetConstantBuffers) LIST_WRAPPER(2, GSSetConstantBuffers) LIST_WRAPPER(3, CSSetConstantBuffers)
LIST_WRAPPER(4, VSSetShaderResources) LIST_WRAPPER(5, PSSetShaderResources) LIST_WRAPPER(6, GSSetShaderResources) LIST_WRAPPER(7, CSSetShaderResources)
LIST_WRAPPER(8, VSSetSamplers) LIST_WRAPPER(9, PSSetSamplers) LIST_WRAPPER(10, GSSetSamplers) LIST_WRAPPER(11, CSSetSamplers)
static void (ORIG *o_shader[6])(void *, void *, void *const *, uint32_t);
#define SET_SHADER_WRAPPER(k, m) \
    static WINAPI void w_##m(void *this, void *sh, void *const *ci, uint32_t n) { \
        if (lock()) { CALL(m); u32(oid(sh)); end(); unlock(); } \
        o_shader[k](this, sh, ci, n); \
    }
SET_SHADER_WRAPPER(0, VSSetShader) SET_SHADER_WRAPPER(1, PSSetShader) SET_SHADER_WRAPPER(2, GSSetShader) SET_SHADER_WRAPPER(3, CSSetShader)
SET_SHADER_WRAPPER(4, HSSetShader) SET_SHADER_WRAPPER(5, DSSetShader)
// One object argument (or none).
static void (ORIG *o_one[6])(void *, void *);
#define ONE_WRAPPER(k, m) \
    static WINAPI void w_##m(void *this, void *a) { \
        if (lock()) { CALL(m); u32(oid(a)); end(); unlock(); } \
        o_one[k](this, a); \
    }
ONE_WRAPPER(0, IASetInputLayout) ONE_WRAPPER(1, RSSetState) ONE_WRAPPER(2, GenerateMips) ONE_WRAPPER(3, DiscardResource) ONE_WRAPPER(4, DiscardView)
static void (ORIG *o_none[2])(void *);
static WINAPI void w_ClearState(void *this) { if (lock()) { CALL(ClearState); end(); unlock(); } o_none[0](this); }
static WINAPI void w_Flush(void *this) { if (lock()) { CALL(Flush); end(); unlock(); } o_none[1](this); }

static void (ORIG *o_ia_vb)(void *, uint32_t, uint32_t, void *const *, const uint32_t *, const uint32_t *);
static WINAPI void w_IASetVertexBuffers(void *this, uint32_t start, uint32_t n, void *const *b, const uint32_t *strides, const uint32_t *offsets) {
    if (lock()) { CALL(IASetVertexBuffers); u32(start); u32(n); ids(n, b); words(n, strides); words(n, offsets); end(); unlock(); }
    o_ia_vb(this, start, n, b, strides, offsets);
}
static void (ORIG *o_ia_ib)(void *, void *, uint32_t, uint32_t);
static WINAPI void w_IASetIndexBuffer(void *this, void *b, uint32_t format, uint32_t offset) {
    if (lock()) { CALL(IASetIndexBuffer); u32(oid(b)); u32(format); u32(offset); end(); unlock(); }
    o_ia_ib(this, b, format, offset);
}
static void (ORIG *o_u32[1])(void *, uint32_t);
static WINAPI void w_IASetPrimitiveTopology(void *this, uint32_t t) {
    if (lock()) { CALL(IASetPrimitiveTopology); u32(t); end(); unlock(); }
    o_u32[0](this, t);
}
static void (ORIG *o_om_rt)(void *, uint32_t, void *const *, void *);
static WINAPI void w_OMSetRenderTargets(void *this, uint32_t n, void *const *rtvs, void *dsv) {
    if (lock()) { CALL(OMSetRenderTargets); u32(n); ids(n, rtvs); u32(oid(dsv)); end(); unlock(); }
    o_om_rt(this, n, rtvs, dsv);
}
#define KEEP 0xffffffffu
static void (ORIG *o_om_rt_uav)(void *, uint32_t, void *const *, void *, uint32_t, uint32_t, void *const *, const uint32_t *);
static WINAPI void w_OMSetRenderTargetsAndUnorderedAccessViews(void *this, uint32_t nrtv, void *const *rtvs, void *dsv, uint32_t start, uint32_t nuav,
                                                               void *const *uavs, const uint32_t *counts) {
    if (lock()) {
        CALL(OMSetRenderTargetsAndUnorderedAccessViews);
        u32(nrtv); if (nrtv != KEEP) ids(nrtv, rtvs); u32(nrtv != KEEP ? oid(dsv) : 0);
        u32(start); u32(nuav); if (nuav != KEEP) { ids(nuav, uavs); words(nuav, counts); }
        end(); unlock();
    }
    o_om_rt_uav(this, nrtv, rtvs, dsv, start, nuav, uavs, counts);
}
static void (ORIG *o_cs_uav)(void *, uint32_t, uint32_t, void *const *, const uint32_t *);
static WINAPI void w_CSSetUnorderedAccessViews(void *this, uint32_t start, uint32_t n, void *const *uavs, const uint32_t *counts) {
    if (lock()) { CALL(CSSetUnorderedAccessViews); u32(start); u32(n); ids(n, uavs); words(n, counts); end(); unlock(); }
    o_cs_uav(this, start, n, uavs, counts);
}
static void (ORIG *o_om_blend)(void *, void *, const float *, uint32_t);
static WINAPI void w_OMSetBlendState(void *this, void *b, const float *factor, uint32_t mask) {
    if (lock()) { CALL(OMSetBlendState); u32(oid(b)); words(4, factor); u32(mask); end(); unlock(); }
    o_om_blend(this, b, factor, mask);
}
static void (ORIG *o_om_depth)(void *, void *, uint32_t);
static WINAPI void w_OMSetDepthStencilState(void *this, void *d, uint32_t ref) {
    if (lock()) { CALL(OMSetDepthStencilState); u32(oid(d)); u32(ref); end(); unlock(); }
    o_om_depth(this, d, ref);
}
static void (ORIG *o_so)(void *, uint32_t, void *const *, const uint32_t *);
static WINAPI void w_SOSetTargets(void *this, uint32_t n, void *const *b, const uint32_t *offsets) {
    if (lock()) { CALL(SOSetTargets); u32(n); ids(n, b); words(n, offsets); end(); unlock(); }
    o_so(this, n, b, offsets);
}
static void (ORIG *o_rs_vp)(void *, uint32_t, const float *);
static WINAPI void w_RSSetViewports(void *this, uint32_t n, const float *vp) {
    if (lock()) { CALL(RSSetViewports); u32(n); words(n * 6, vp); end(); unlock(); }
    o_rs_vp(this, n, vp);
}
static void (ORIG *o_rs_sc)(void *, uint32_t, const int32_t *);
static WINAPI void w_RSSetScissorRects(void *this, uint32_t n, const int32_t *r) {
    if (lock()) { CALL(RSSetScissorRects); u32(n); words(n * 4, r); end(); unlock(); }
    o_rs_sc(this, n, r);
}
static void (ORIG *o_draw)(void *, uint32_t, uint32_t);
static WINAPI void w_Draw(void *this, uint32_t count, uint32_t start) {
    if (lock()) { CALL(Draw); u32(count); u32(start); end(); unlock(); }
    o_draw(this, count, start);
}
static void (ORIG *o_draw_inst)(void *, uint32_t, uint32_t, uint32_t, uint32_t);
static WINAPI void w_DrawInstanced(void *this, uint32_t count, uint32_t inst, uint32_t start, uint32_t start_inst) {
    if (lock()) { CALL(DrawInstanced); u32(count); u32(inst); u32(start); u32(start_inst); end(); unlock(); }
    o_draw_inst(this, count, inst, start, start_inst);
}
static void (ORIG *o_draw_idx)(void *, uint32_t, uint32_t, int32_t);
static WINAPI void w_DrawIndexed(void *this, uint32_t count, uint32_t start, int32_t base) {
    if (lock()) { CALL(DrawIndexed); u32(count); u32(start); u32((uint32_t)base); end(); unlock(); }
    o_draw_idx(this, count, start, base);
}
static void (ORIG *o_draw_idx_inst)(void *, uint32_t, uint32_t, uint32_t, int32_t, uint32_t);
static WINAPI void w_DrawIndexedInstanced(void *this, uint32_t count, uint32_t inst, uint32_t start, int32_t base, uint32_t start_inst) {
    if (lock()) { CALL(DrawIndexedInstanced); u32(count); u32(inst); u32(start); u32((uint32_t)base); u32(start_inst); end(); unlock(); }
    o_draw_idx_inst(this, count, inst, start, base, start_inst);
}
static void (ORIG *o_dispatch)(void *, uint32_t, uint32_t, uint32_t);
static WINAPI void w_Dispatch(void *this, uint32_t x, uint32_t y, uint32_t z) {
    if (lock()) { CALL(Dispatch); u32(x); u32(y); u32(z); end(); unlock(); }
    o_dispatch(this, x, y, z);
}
static void (ORIG *o_copy_region)(void *, void *, uint32_t, uint32_t, uint32_t, uint32_t, void *, uint32_t, const uint32_t *);
static WINAPI void w_CopySubresourceRegion(void *this, void *dst, uint32_t dst_sub, uint32_t x, uint32_t y, uint32_t z, void *src, uint32_t src_sub, const uint32_t *box) {
    if (lock()) { CALL(CopySubresourceRegion); u32(oid(dst)); u32(dst_sub); u32(x); u32(y); u32(z); u32(oid(src)); u32(src_sub); words(6, box); end(); unlock(); }
    o_copy_region(this, dst, dst_sub, x, y, z, src, src_sub, box);
}
static void (ORIG *o_copy)(void *, void *, void *);
static WINAPI void w_CopyResource(void *this, void *dst, void *src) {
    if (lock()) { CALL(CopyResource); u32(oid(dst)); u32(oid(src)); end(); unlock(); }
    o_copy(this, dst, src);
}
static void (ORIG *o_copy_count)(void *, void *, uint32_t, void *);
static WINAPI void w_CopyStructureCount(void *this, void *dst, uint32_t offset, void *v) {
    if (lock()) { CALL(CopyStructureCount); u32(oid(dst)); u32(offset); u32(oid(v)); end(); unlock(); }
    o_copy_count(this, dst, offset, v);
}
static void (ORIG *o_resolve)(void *, void *, uint32_t, void *, uint32_t, uint32_t);
static WINAPI void w_ResolveSubresource(void *this, void *dst, uint32_t dst_sub, void *src, uint32_t src_sub, uint32_t format) {
    if (lock()) { CALL(ResolveSubresource); u32(oid(dst)); u32(dst_sub); u32(oid(src)); u32(src_sub); u32(format); end(); unlock(); }
    o_resolve(this, dst, dst_sub, src, src_sub, format);
}
static void (ORIG *o_clear_rtv)(void *, void *, const float *);
static WINAPI void w_ClearRenderTargetView(void *this, void *v, const float *color) {
    if (lock()) { CALL(ClearRenderTargetView); u32(oid(v)); words(4, color); end(); unlock(); }
    o_clear_rtv(this, v, color);
}
static void (ORIG *o_clear_dsv)(void *, void *, uint32_t, float, uint8_t);
static WINAPI void w_ClearDepthStencilView(void *this, void *v, uint32_t flags, float depth, uint8_t stencil) {
    if (lock()) { CALL(ClearDepthStencilView); u32(oid(v)); u32(flags); f32(depth); u32(stencil); end(); unlock(); }
    o_clear_dsv(this, v, flags, depth, stencil);
}
static void (ORIG *o_clear_uav[2])(void *, void *, const void *);
static WINAPI void w_ClearUnorderedAccessViewUint(void *this, void *v, const void *values) {
    if (lock()) { CALL(ClearUnorderedAccessViewUint); u32(oid(v)); words(4, values); end(); unlock(); }
    o_clear_uav[0](this, v, values);
}
static WINAPI void w_ClearUnorderedAccessViewFloat(void *this, void *v, const void *values) {
    if (lock()) { CALL(ClearUnorderedAccessViewFloat); u32(oid(v)); words(4, values); end(); unlock(); }
    o_clear_uav[1](this, v, values);
}
static void (ORIG *o_discard1)(void *, void *, const int32_t *, uint32_t);
static WINAPI void w_DiscardView1(void *this, void *v, const int32_t *rects, uint32_t n) {
    if (lock()) { CALL(DiscardView1); u32(oid(v)); u32(n); words(n * 4, rects); end(); unlock(); }
    o_discard1(this, v, rects, n);
}

static void (ORIG *o_update)(void *, d3d_object *, uint32_t, const uint32_t *, const void *, uint32_t, uint32_t);
static WINAPI void w_UpdateSubresource(void *this, d3d_object *dst, uint32_t sub, const uint32_t *box, const void *data, uint32_t row_pitch, uint32_t depth_pitch) {
    if (dst && data && lock()) {
        begin(D3DCAP_UPDATE); u32(oid(this)); u32(oid(dst)); u32(sub); words(6, box);
        if (dst->kind == K_BUFFER) {
            const d3d_buffer *b = (const d3d_buffer *)dst;
            uint32_t size = box ? box[3] - box[0] : b->desc[0];
            if (size > b->desc[0]) size = 0;
            u32(size); u32(1); u32(1); u32(size); put(data, size);
        } else {
            region r = texture_region((const d3d_texture *)dst, sub, box);
            u32(r.row_bytes); u32(r.rows); u32(r.d);
            packed(data, row_pitch, depth_pitch, r);
        }
        end(); unlock();
    }
    o_update(this, dst, sub, box, data, row_pitch, depth_pitch);
}
static HRESULT (ORIG *o_map)(void *, d3d_object *, uint32_t, uint32_t, uint32_t, MAPPED *);
static WINAPI HRESULT w_Map(void *this, d3d_object *res, uint32_t sub, uint32_t type, uint32_t flags, MAPPED *out) {
    HRESULT hr = o_map(this, res, sub, type, flags, out);
    if (hr != S_OK || !res || !out || !lock()) return hr;
    if (type == 1) {
        // what the program reads, as its hash (FNV-1a 64 of the rows, tightly packed): the replayer checks its own
        size_t rb, rows, d = 1;
        if (res->kind == K_BUFFER) { rb = ((const d3d_buffer *)res)->desc[0]; rows = 1; }
        else { region r = texture_region((const d3d_texture *)res, sub, NULL); rb = r.row_bytes; rows = r.rows; d = r.d; }
        uint64_t h = 0xcbf29ce484222325ull;
        for (size_t z = 0; z < d; z++) for (size_t y = 0; y < rows; y++) {
            const uint8_t *p = (const uint8_t *)out->data + z * out->depth_pitch + y * out->row_pitch;
            for (size_t i = 0; i < rb; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
        }
        begin(D3DCAP_MAP_READ); u32(oid(this)); u32(oid(res)); u32(sub); u32(type); u32((uint32_t)(rb * rows * d)); put(&h, 8); end();
        fflush(g_file);                                    // (a sync point of the program's: what it saw so far is on disk)
    }
    else if (g_nmaps < 64) {
        size_t size;
        if (res->kind == K_BUFFER) size = ((const d3d_buffer *)res)->desc[0];
        else {
            const d3d_texture *t = (const d3d_texture *)res;
            region r = texture_region(t, sub, NULL);
            size = (size_t)out->depth_pitch * (r.d - 1) + (size_t)out->row_pitch * (r.rows - 1) + r.row_bytes;
        }
        g_maps[g_nmaps++] = (open_map){ res, sub, type, flags, out->row_pitch, out->depth_pitch, out->data, size };
    } else {
        static int told;
        if (!told++) vx_log("Direct3D capture: more than 64 resources mapped at once; writes through the others are not captured");
    }
    unlock();
    return hr;
}
static void (ORIG *o_unmap)(void *, d3d_object *, uint32_t);
static WINAPI void w_Unmap(void *this, d3d_object *res, uint32_t sub) {
    if (res && lock()) {
        for (int i = 0; i < g_nmaps; i++) {
            if (g_maps[i].res != res || g_maps[i].sub != sub) continue;
            open_map m = g_maps[i];
            g_maps[i] = g_maps[--g_nmaps];
            uint32_t id = oid(res);
            begin(D3DCAP_UNMAP); u32(oid(this)); u32(id); u32(sub); u32(m.type); u32(m.flags); u32(m.row); u32(m.depth); u32((uint32_t)m.size);
            runs(shadow_of(id, sub, m.size), m.data);
            end();
            break;
        }
        unlock();
    }
    o_unmap(this, res, sub);
}

// ---- hooks -------------------------------------------------------------------------------------------------------------
void d3d11_capture_device(d3d_object *device, d3d_object *context, uint32_t flags, uint32_t level) {
    if (!lock()) return;
    uint32_t d = new_id(device), c = new_id(context);
    begin(D3DCAP_DEVICE); u32(d); u32(c); u32(flags); u32(level); end();
    unlock();
}
void d3d11_capture_destroyed(d3d_object *o) {
    if (!lock()) return;
    uint32_t id = forget_id(o);
    if (id) {
        begin(D3DCAP_DESTROY); u32(id); end();
        if (o->kind == K_BUFFER || o->kind == K_TEXTURE) shadows_forget(id);
        for (int i = 0; i < g_nmaps; i++) if (g_maps[i].res == o) g_maps[i--] = g_maps[--g_nmaps];
    }
    unlock();
}
void d3d11_capture_present(d3d_object *buffer) {
    if (!lock()) return;
    g_presents++;
    begin(D3DCAP_PRESENT); u32(oid(buffer)); u32((uint32_t)g_presents); end();
    frame_end();
    if (g_limit_presents && g_presents >= g_limit_presents) stop("frame limit");
    unlock();
}
void d3d11_capture_eye(d3d_object *texture, uint32_t eye, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (!lock()) return;
    begin(D3DCAP_EYE); u32(eye); u32(oid(texture)); u32(x); u32(y); u32(w); u32(h); end();
    unlock();
}
void d3d11_capture_eye_frame(uint64_t frame_id) {
    if (!lock()) return;
    begin(D3DCAP_EYE_FRAME); u32((uint32_t)frame_id); end();
    frame_end();
    if (g_limit_eye && frame_id >= g_limit_eye) stop("eye frame limit");
    unlock();
}

void d3d11_capture_finish(void) { if (lock()) { stop("process exit"); unlock(); } }   // ExitProcess, and exit()
static void at_exit(void) { d3d11_capture_finish(); }

typedef struct { const char *name; void *wrapper; void **orig; } hook;
#define H(n, w, o) { n, (void *)(w), (void **)(o) }
static const hook g_device_hooks[] = {
    H("CreateBuffer", w_create_buffer, &o_create_buffer), H("CreateTexture1D", w_create_tex1, &o_create_tex[0]),
    H("CreateTexture2D", w_create_tex2, &o_create_tex[1]), H("CreateTexture3D", w_create_tex3, &o_create_tex[2]),
    H("CreateShaderResourceView", w_create_view0, &o_create_view[0]), H("CreateRenderTargetView", w_create_view1, &o_create_view[1]),
    H("CreateDepthStencilView", w_create_view2, &o_create_view[2]), H("CreateUnorderedAccessView", w_create_view3, &o_create_view[3]),
    H("CreateVertexShader", w_create_shader0, &o_create_shader[0]), H("CreatePixelShader", w_create_shader1, &o_create_shader[1]),
    H("CreateComputeShader", w_create_shader2, &o_create_shader[2]), H("CreateGeometryShader", w_create_shader3, &o_create_shader[3]),
    H("CreateGeometryShaderWithStreamOutput", w_create_gs_so, &o_create_gs_so), H("CreateInputLayout", w_create_layout, &o_create_layout),
    H("CreateBlendState", w_create_state0, &o_create_state[0]), H("CreateDepthStencilState", w_create_state1, &o_create_state[1]),
    H("CreateRasterizerState", w_create_state2, &o_create_state[2]), H("CreateSamplerState", w_create_state3, &o_create_state[3]),
    H("CreateQuery", w_create_state4, &o_create_state[4]), H("CreatePredicate", w_create_state5, &o_create_state[5]),
};
static const hook g_context_hooks[] = {
    H("VSSetConstantBuffers", w_VSSetConstantBuffers, &o_list[0]), H("PSSetConstantBuffers", w_PSSetConstantBuffers, &o_list[1]),
    H("GSSetConstantBuffers", w_GSSetConstantBuffers, &o_list[2]), H("CSSetConstantBuffers", w_CSSetConstantBuffers, &o_list[3]),
    H("VSSetShaderResources", w_VSSetShaderResources, &o_list[4]), H("PSSetShaderResources", w_PSSetShaderResources, &o_list[5]),
    H("GSSetShaderResources", w_GSSetShaderResources, &o_list[6]), H("CSSetShaderResources", w_CSSetShaderResources, &o_list[7]),
    H("VSSetSamplers", w_VSSetSamplers, &o_list[8]), H("PSSetSamplers", w_PSSetSamplers, &o_list[9]),
    H("GSSetSamplers", w_GSSetSamplers, &o_list[10]), H("CSSetSamplers", w_CSSetSamplers, &o_list[11]),
    H("VSSetShader", w_VSSetShader, &o_shader[0]), H("PSSetShader", w_PSSetShader, &o_shader[1]), H("GSSetShader", w_GSSetShader, &o_shader[2]),
    H("CSSetShader", w_CSSetShader, &o_shader[3]), H("HSSetShader", w_HSSetShader, &o_shader[4]), H("DSSetShader", w_DSSetShader, &o_shader[5]),
    H("IASetInputLayout", w_IASetInputLayout, &o_one[0]), H("RSSetState", w_RSSetState, &o_one[1]), H("GenerateMips", w_GenerateMips, &o_one[2]),
    H("DiscardResource", w_DiscardResource, &o_one[3]), H("DiscardView", w_DiscardView, &o_one[4]),
    H("ClearState", w_ClearState, &o_none[0]), H("Flush", w_Flush, &o_none[1]),
    H("IASetVertexBuffers", w_IASetVertexBuffers, &o_ia_vb), H("IASetIndexBuffer", w_IASetIndexBuffer, &o_ia_ib),
    H("IASetPrimitiveTopology", w_IASetPrimitiveTopology, &o_u32[0]), H("OMSetRenderTargets", w_OMSetRenderTargets, &o_om_rt),
    H("OMSetRenderTargetsAndUnorderedAccessViews", w_OMSetRenderTargetsAndUnorderedAccessViews, &o_om_rt_uav),
    H("CSSetUnorderedAccessViews", w_CSSetUnorderedAccessViews, &o_cs_uav), H("OMSetBlendState", w_OMSetBlendState, &o_om_blend),
    H("OMSetDepthStencilState", w_OMSetDepthStencilState, &o_om_depth), H("SOSetTargets", w_SOSetTargets, &o_so),
    H("RSSetViewports", w_RSSetViewports, &o_rs_vp), H("RSSetScissorRects", w_RSSetScissorRects, &o_rs_sc),
    H("Draw", w_Draw, &o_draw), H("DrawInstanced", w_DrawInstanced, &o_draw_inst), H("DrawIndexed", w_DrawIndexed, &o_draw_idx),
    H("DrawIndexedInstanced", w_DrawIndexedInstanced, &o_draw_idx_inst), H("Dispatch", w_Dispatch, &o_dispatch),
    H("CopySubresourceRegion", w_CopySubresourceRegion, &o_copy_region), H("CopyResource", w_CopyResource, &o_copy),
    H("CopyStructureCount", w_CopyStructureCount, &o_copy_count), H("ResolveSubresource", w_ResolveSubresource, &o_resolve),
    H("ClearRenderTargetView", w_ClearRenderTargetView, &o_clear_rtv), H("ClearDepthStencilView", w_ClearDepthStencilView, &o_clear_dsv),
    H("ClearUnorderedAccessViewUint", w_ClearUnorderedAccessViewUint, &o_clear_uav[0]),
    H("ClearUnorderedAccessViewFloat", w_ClearUnorderedAccessViewFloat, &o_clear_uav[1]), H("DiscardView1", w_DiscardView1, &o_discard1),
    H("UpdateSubresource", w_UpdateSubresource, &o_update), H("Map", w_Map, &o_map), H("Unmap", w_Unmap, &o_unmap),
};
static void install(void **vt, int context, const hook *h, size_t n) {
    for (size_t i = 0; i < n; i++) {
        int slot = d3d11_vtable_slot(context, h[i].name);
        if (slot < 0) { vx_log("Direct3D capture: no method %s", h[i].name); continue; }
        *h[i].orig = vt[slot];
        vt[slot] = h[i].wrapper;
    }
}
void d3d11_capture_install(void **device_vtbl, void **context_vtbl) {
    const char *path = getenv("VXRT_D3D11_CAPTURE");
    if (!path || !*path || g_installed++) return;
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_lock, &a);
    g_file = fopen(path, "wb");
    if (!g_file) { vx_log("Direct3D capture: cannot write %s", path); return; }
    setvbuf(g_file, NULL, _IOFBF, 16 << 20);
    const char *e = getenv("VXRT_D3D11_CAPTURE_FRAMES");
    g_limit_presents = e ? strtoull(e, NULL, 10) : 0;
    e = getenv("VXRT_D3D11_CAPTURE_EYE_FRAMES");
    g_limit_eye = e ? strtoull(e, NULL, 10) : 0;
    uint32_t version = D3DCAP_VERSION, zero = 0;
    fwrite(D3DCAP_MAGIC, 1, 8, g_file); fwrite(&version, 4, 1, g_file); fwrite(&zero, 4, 1, g_file);
    install(device_vtbl, 0, g_device_hooks, sizeof g_device_hooks / sizeof *g_device_hooks);
    install(context_vtbl, 1, g_context_hooks, sizeof g_context_hooks / sizeof *g_context_hooks);
    atexit(at_exit);
    d3d11_capture_on = 1;
    vx_log("Direct3D capture: writing %s (stop after %llu presents / eye frame %llu; 0: never)", path,
           (unsigned long long)g_limit_presents, (unsigned long long)g_limit_eye);
}

#ifdef __aarch64__
#include "thunks/d3d11_capture.m.inc"
#endif
