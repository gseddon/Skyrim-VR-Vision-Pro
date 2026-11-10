// vxrt-d3d11-replay: plays a Direct3D 11 capture (VXRT_D3D11_CAPTURE, src/d3d11_capture.h) on this checkout's
// Direct3D 11 implementation (src/d3d11.m, d3d11_draw.m, dxbc.c, linked in), with no program, no xrizer, no Steam,
// and writes the images asked for: the VR eye images, render targets after chosen draws, the program's readbacks.
//
// usage: vxrt-d3d11-replay <capture> [options]
//   --frames a-b          replay up to frame b (eye frames if the capture has VR eyes, else presents); dumps only in a..b
//   --dump-eyes <dir>     each eye image (frame<F>_eye<E>_<W>x<H>.rgba, .png)
//   --compare-eyes <dir>  compare each eye image with <dir>/frame<F>_eye<E>_<W>x<H>.rgba (the dev host's live dumps)
//   --dump-rt <spec>      after the draws named, the render targets bound (spec: comma list of <global draw>,
//                         <frame>:<draw in frame>, ps:<pixel shader hash> (each such draw in the frames range))
//   --dump-dir <dir>      where --dump-rt and --dump-reads write (default .)
//   --dump-reads          each readback the program made (Map for reading), as raw bytes, with its hash
//   --check-reads         compare each readback with the hash of what the live program read; exit 1 unless all match
//   --list-draws          a line per draw/dispatch in the frames range: frame, index, shaders, targets
//   --from <f>            replay everything up to frame f, then dump from f on (--frames f-); with no dump option set
//                         the frames before f only cost what their GPU work costs
//   --fast[=k]            with --from: no draws or dispatches before frame f-k (default k 200; uploads, Map writes,
//                         copies, clears, mips, resolves and bindings all kept). Approximate: anything drawn before
//                         f-k and read later (shadow maps, TAA history, eye adaptation) is missing or stale
//   --skip-before <f>     the same, by frame number
//   --stats               records and bytes by kind
//   --max-dumps <n>       at most n render-target dumps (default 64)
//   --env K=V             set an environment variable before Direct3D starts (fix toggles), repeatable
//   --quiet               no runtime log
// Hashes are FNV-1a 64 of the raw texels (rows tightly packed); non-black: pixels whose RGB is not 0 (8-bit formats).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#include "d3d_common.h"
#include "d3d11_capture.h"
#include <sys/stat.h>

void vx_d3d11_init(void);
extern int vx_replay_quiet;

static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); fputs("replay: ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr); va_end(ap); exit(2);
}

// ---- options ----------------------------------------------------------------------------------------------------------
static uint64_t g_from, g_to = UINT64_MAX, g_skip_before, g_skipped;
static uint64_t g_op_count[32], g_op_bytes[32];
static int g_stats;
static const char *g_eye_dir, *g_cmp_dir, *g_dump_dir = ".";
static int g_dump_reads, g_list, g_max_dumps = 64, g_dumps;
typedef struct { int kind; uint64_t a, b; } rt_spec;     // 0: global draw a; 1: frame a draw b; 2: ps hash a
static rt_spec g_specs[64];
static int g_nspecs;

// ---- objects ------------------------------------------------------------------------------------------------------------
typedef struct { void *p; int kind; uint32_t hash; } robj;   // kind: D3DCAP_* creation op; hash: shaders' (SHA-256 prefix)
static robj *g_obj;
static uint32_t g_nobj;
static void put_obj(uint32_t xid, void *p, int kind) {
    if (xid >= g_nobj) { uint32_t n = xid * 2 + 1024; g_obj = realloc(g_obj, n * sizeof *g_obj); memset(g_obj + g_nobj, 0, (n - g_nobj) * sizeof *g_obj); g_nobj = n; }
    g_obj[xid] = (robj){ p, kind, 0 };
}
static uint64_t g_missing;
// Shaders are made on other threads (translation and Metal compilation are most of a game's start-up), as the
// program's loading threads do: a shader still being made is a job, waited for when a call names it.
#define PENDING 99
typedef struct { void *volatile p; volatile int done; } job;
static dispatch_queue_t g_jobs_queue;
static dispatch_group_t g_jobs;
static dispatch_semaphore_t g_jobs_slots;
static void *resolve(uint32_t xid) {
    job *j = g_obj[xid].p;
    while (!__atomic_load_n(&j->done, __ATOMIC_ACQUIRE)) usleep(20);
    g_obj[xid].p = j->p; g_obj[xid].kind = D3DCAP_SHADER;
    free(j);
    return g_obj[xid].p;
}
static void *obj(uint32_t xid) {
    if (!xid) return NULL;
    if (xid >= g_nobj || !g_obj[xid].p) { if (g_missing++ < 8) fprintf(stderr, "replay: object %u is not known\n", xid); return NULL; }
    if (g_obj[xid].kind == PENDING) return resolve(xid);
    return g_obj[xid].p;
}
static void *g_dev, *g_ctx;
static void **dvt(void) { return *(void ***)g_dev; }
static void **cvt(void) { return *(void ***)g_ctx; }
static int g_dslot[64], g_cslot[D3DCAP_M_COUNT], g_slot_map, g_slot_unmap, g_slot_update;
static const char *const g_mnames[] = {
#define NAME(n) #n,
    D3DCAP_METHODS(NAME)
#undef NAME
};

// ---- reading -------------------------------------------------------------------------------------------------------------
typedef struct { const uint8_t *p, *end; } rd;
static uint32_t r32(rd *r) { if (r->p + 4 > r->end) die("record too short"); uint32_t v; memcpy(&v, r->p, 4); r->p += 4; return v; }
static float rf(rd *r) { uint32_t v = r32(r); float f; memcpy(&f, &v, 4); return f; }
static const uint8_t *rbytes(rd *r, size_t n) { if (r->p + n > r->end) die("record too short"); const uint8_t *p = r->p; r->p += n; return p; }
static char *rstr(rd *r, char *buf, size_t cap) {
    uint32_t n = r32(r); const uint8_t *p = rbytes(r, n);
    if (n >= cap) n = (uint32_t)cap - 1;
    memcpy(buf, p, n); buf[n] = 0; return buf;
}
// A pointer array (present flag, ids) as the objects.
static void *const *rids(rd *r, uint32_t n, void **out) {
    if (!r32(r)) return NULL;
    for (uint32_t i = 0; i < n; i++) { uint32_t xid = r32(r); if (i < 128) out[i] = obj(xid); }
    return out;
}
static const void *rwords(rd *r, uint32_t n) { if (!r32(r)) return NULL; return rbytes(r, (size_t)n * 4); }

// ---- images ------------------------------------------------------------------------------------------------------------------
static uint64_t fnv(const uint8_t *p, size_t n) { uint64_t h = 0xcbf29ce484222325ull; for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ull; } return h; }
static double non_black(const uint8_t *px, size_t n) {
    size_t k = 0; for (size_t i = 0; i < n; i++) if (px[i * 4] | px[i * 4 + 1] | px[i * 4 + 2]) k++;
    return n ? 100.0 * (double)k / (double)n : 0;
}
static void write_png(const char *path, const uint8_t *rgba, uint32_t w, uint32_t h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate((void *)rgba, w, h, 8, (size_t)w * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(cg);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (dst) { CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst); CFRelease(dst); }
    CFRelease(url); CGImageRelease(img); CGContextRelease(cg); CGColorSpaceRelease(cs);
}
static void write_file(const char *path, const void *p, size_t n) {
    FILE *f = fopen(path, "wb"); if (!f) die("cannot write %s", path);
    fwrite(p, 1, n, f); fclose(f);
}
// A region of a Metal texture (level 0, slice), tightly packed rows; NULL if its format has no fixed texel size.
static uint8_t *read_texture(id<MTLTexture> t, NSUInteger slice, NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h, size_t *row_out) {
    d3d_device *d = g_dev;
    d3d_flush(d, 1);
    NSUInteger bpp;
    switch (t.pixelFormat) {
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRG11B10Float: case MTLPixelFormatR32Float: case MTLPixelFormatRG16Float:
    case MTLPixelFormatR32Uint: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Snorm: bpp = 4; break;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRG32Float: bpp = 8; break;
    case MTLPixelFormatRGBA32Float: bpp = 16; break;
    case MTLPixelFormatR16Float: case MTLPixelFormatR16Unorm: case MTLPixelFormatRG8Unorm: bpp = 2; break;
    case MTLPixelFormatR8Unorm: case MTLPixelFormatA8Unorm: bpp = 1; break;
    default: return NULL;
    }
    size_t row = w * bpp;
    id<MTLBuffer> buf = [t.device newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cmd = [(__bridge id<MTLCommandQueue>)d->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:slice sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [blit endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
    uint8_t *out = malloc(row * h);
    memcpy(out, buf.contents, row * h);
    *row_out = row;
    return out;
}

// ---- frames -----------------------------------------------------------------------------------------------------------------
static int g_eye_unit = -1;            // the capture has VR eye frames: frames are numbered by them
static uint64_t g_frame = 1;           // the frame being replayed
static uint64_t g_draws, g_frame_draws;
static uint32_t g_rtv[8], g_dsv, g_nrtv;
static uint32_t g_ps, g_vs, g_cs;
static int in_range(void) { return g_frame >= g_from && g_frame <= g_to; }
typedef struct { uint32_t eye, w, h; uint8_t *px; } eye_image;
static eye_image g_eyes[4];
static int g_neyes;
static uint64_t g_eye_images, g_eye_same, g_eye_compared;

static void eye_record(rd *r) {
    uint32_t eye = r32(r), xid = r32(r), x = r32(r), y = r32(r), w = r32(r), h = r32(r);
    if (!in_range() || (!g_eye_dir && !g_cmp_dir) || g_neyes >= 4) return;
    if (!g_eye_dir) {                                  // only comparing: only frames with a live dump (this frame's id, if ids run on)
        char path[1200];
        snprintf(path, sizeof path, "%s/frame%llu_eye%u_%ux%u.rgba", g_cmp_dir, (unsigned long long)g_frame, eye, w, h);
        if (access(path, R_OK)) return;
    }
    d3d_texture *t = obj(xid);
    if (!t) return;
    size_t row;
    uint8_t *px = read_texture((__bridge id<MTLTexture>)t->mtl, 0, x, y, w, h, &row);
    if (!px) { fprintf(stderr, "replay: eye texture format %ld not read\n", (long)((__bridge id<MTLTexture>)t->mtl).pixelFormat); return; }
    g_eyes[g_neyes++] = (eye_image){ eye, w, h, px };
}
static void eyes_done(uint64_t fid) {
    for (int i = 0; i < g_neyes; i++) {
        eye_image *e = &g_eyes[i];
        size_t n = (size_t)e->w * e->h;
        char name[160], path[1200];
        snprintf(name, sizeof name, "frame%llu_eye%u_%ux%u", (unsigned long long)fid, e->eye, e->w, e->h);
        printf("eye frame %llu eye %u %ux%u fnv %016llx non-black %.2f%%", (unsigned long long)fid, e->eye, e->w, e->h,
               (unsigned long long)fnv(e->px, n * 4), non_black(e->px, n));
        if (g_eye_dir) {
            snprintf(path, sizeof path, "%s/%s.rgba", g_eye_dir, name); write_file(path, e->px, n * 4);
            snprintf(path, sizeof path, "%s/%s.png", g_eye_dir, name); write_png(path, e->px, e->w, e->h);
        }
        if (g_cmp_dir) {
            snprintf(path, sizeof path, "%s/%s.rgba", g_cmp_dir, name);
            FILE *f = fopen(path, "rb");
            if (f) {
                uint8_t *live = malloc(n * 4);
                size_t got = fread(live, 1, n * 4, f); fclose(f);
                if (got == n * 4) {
                    size_t differ = 0; int maxd = 0;
                    for (size_t k = 0; k < n; k++) {
                        int dd = 0;
                        for (int c = 0; c < 3; c++) { int v = abs((int)live[k * 4 + c] - (int)e->px[k * 4 + c]); if (v > dd) dd = v; }
                        if (dd) differ++;
                        if (dd > maxd) maxd = dd;
                    }
                    g_eye_compared++; if (!differ) g_eye_same++;
                    printf(" | live fnv %016llx non-black %.2f%%: %zu pixels differ in RGB (%.3f%%), max %d%s", (unsigned long long)fnv(live, n * 4),
                           non_black(live, n), differ, 100.0 * (double)differ / (double)n, maxd, differ ? "" : " IDENTICAL");
                } else printf(" | live dump %s is short", path);
                free(live);
            } else printf(" | no live dump");
        }
        printf("\n");
        free(e->px);
        g_eye_images++;
    }
    g_neyes = 0;
}
static void frame_done(uint64_t fid) {
    if (g_eye_unit) eyes_done(fid);
    g_frame = fid + 1;
    g_frame_draws = 0;
}

// ---- render target dumps -----------------------------------------------------------------------------------------------
static int wanted(void) {
    for (int i = 0; i < g_nspecs; i++) {
        rt_spec *s = &g_specs[i];
        if (s->kind == 0 && s->a == g_draws) return 1;
        if (s->kind == 1 && s->a == g_frame && s->b == g_frame_draws) return 1;
        if (s->kind == 2 && in_range() && g_ps && g_ps < g_nobj && g_obj[g_ps].hash == s->a) return 1;
    }
    return 0;
}
static void dump_view(const char *what, uint32_t xid) {
    d3d_view *v = obj(xid);
    if (!v) return;
    id<MTLTexture> t = (__bridge id<MTLTexture>)(v->base.kind == K_RTV ? d3d_rtv_texture(v) : ((d3d_texture *)v->resource)->mtl);
    if (!t) return;
    char path[1200];
    snprintf(path, sizeof path, "%s/f%llu_d%llu_%s_%ux%u.png", g_dump_dir, (unsigned long long)g_frame, (unsigned long long)g_frame_draws,
             what, (unsigned)t.width, (unsigned)t.height);
    size_t row;
    uint8_t *px = v->base.kind == K_RTV ? read_texture(t, 0, 0, 0, t.width, t.height, &row) : NULL;
    printf("  %s (view %u, texture %ux%u format %ld): ", what, xid, (unsigned)t.width, (unsigned)t.height, (long)t.pixelFormat);
    if (px) {
        printf("fnv %016llx", (unsigned long long)fnv(px, row * t.height));
        if (row == t.width * 4 && (t.pixelFormat == MTLPixelFormatRGBA8Unorm || t.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ||
                                    t.pixelFormat == MTLPixelFormatBGRA8Unorm || t.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB))
            printf(" non-black %.2f%%", non_black(px, (size_t)t.width * t.height));
        free(px);
    }
    d3d_texture_png(g_dev, (__bridge void *)t, path);
    printf(" -> %s\n", path);
}
static void after_draw(const char *what) {
    g_draws++; g_frame_draws++;
    if (g_list && in_range())
        printf("frame %llu draw %llu (#%llu) %s vs %08x ps %08x cs %08x rtv %u %u %u %u dsv %u\n", (unsigned long long)g_frame,
               (unsigned long long)g_frame_draws, (unsigned long long)g_draws, what,
               g_vs < g_nobj ? g_obj[g_vs].hash : 0, g_ps < g_nobj ? g_obj[g_ps].hash : 0, g_cs < g_nobj ? g_obj[g_cs].hash : 0,
               g_rtv[0], g_rtv[1], g_rtv[2], g_rtv[3], g_dsv);
    if (g_nspecs && g_dumps < g_max_dumps && wanted()) {
        g_dumps++;
        printf("render targets after frame %llu draw %llu (#%llu, %s, ps %08x):\n", (unsigned long long)g_frame, (unsigned long long)g_frame_draws,
               (unsigned long long)g_draws, what, g_ps < g_nobj ? g_obj[g_ps].hash : 0);
        for (uint32_t i = 0; i < g_nrtv && i < 8; i++) if (g_rtv[i]) { char n[16]; snprintf(n, sizeof n, "rt%u", i); dump_view(n, g_rtv[i]); }
    }
}

// ---- records ------------------------------------------------------------------------------------------------------------------
typedef struct { const void *data; uint32_t pitch, slice_pitch; } SUBRESOURCE_DATA;
typedef struct { void *data; uint32_t row_pitch, depth_pitch; } MAPPED;
typedef struct { const char *semantic; uint32_t index, format, slot, offset, classification, step; } INPUT_ELEMENT;
typedef struct { uint32_t stream; const char *semantic; uint32_t index; uint8_t start, count, slot; } so_decl;
typedef HRESULT (*create_fn)(void *, uint32_t, void *, uint32_t, const uint32_t *, uint32_t, uint32_t, void **, uint32_t *, void **);

enum { DS_BUFFER, DS_TEX1, DS_TEX2, DS_TEX3, DS_SRV, DS_RTV, DS_DSV, DS_UAV, DS_VS, DS_PS, DS_CS, DS_GS, DS_GSSO, DS_LAYOUT,
       DS_BLEND, DS_DEPTH, DS_RASTER, DS_SAMPLER, DS_QUERY, DS_PREDICATE, DS_COUNT };
static const char *const g_dnames[DS_COUNT] = { "CreateBuffer", "CreateTexture1D", "CreateTexture2D", "CreateTexture3D",
    "CreateShaderResourceView", "CreateRenderTargetView", "CreateDepthStencilView", "CreateUnorderedAccessView",
    "CreateVertexShader", "CreatePixelShader", "CreateComputeShader", "CreateGeometryShader", "CreateGeometryShaderWithStreamOutput",
    "CreateInputLayout", "CreateBlendState", "CreateDepthStencilState", "CreateRasterizerState", "CreateSamplerState", "CreateQuery", "CreatePredicate" };
#define DCALL(slot, type) ((type)dvt()[g_dslot[slot]])
#define CCALL(m, type) ((type)cvt()[g_cslot[D3DCAP_M_##m]])
static uint64_t g_fail;
static void check(HRESULT hr, const char *what, uint32_t xid) { if (hr != S_OK && g_fail++ < 16) fprintf(stderr, "replay: %s for object %u failed: %#x\n", what, xid, (unsigned)hr); }

static void device_record(rd *r) {
    uint32_t d = r32(r), c = r32(r), flags = r32(r), level = r32(r);
    if (g_dev) { fprintf(stderr, "replay: a second device (%u) is not replayed; its objects use the first\n", d); put_obj(d, g_dev, D3DCAP_DEVICE); put_obj(c, g_ctx, D3DCAP_DEVICE); return; }
    create_fn create = (create_fn)vx_find_export("d3d11.dll", "D3D11CreateDevice");
    if (!create) die("no D3D11CreateDevice");
    uint32_t got = 0;
    HRESULT hr = create(NULL, 0, NULL, flags, &level, 1, 7, &g_dev, &got, &g_ctx);
    if (hr) die("D3D11CreateDevice failed: %#x", (unsigned)hr);
    put_obj(d, g_dev, D3DCAP_DEVICE); put_obj(c, g_ctx, D3DCAP_DEVICE);
    for (int i = 0; i < DS_COUNT; i++) if ((g_dslot[i] = d3d11_vtable_slot(0, g_dnames[i])) < 0) die("no device method %s", g_dnames[i]);
    for (int i = 0; i < D3DCAP_M_COUNT; i++) if ((g_cslot[i] = d3d11_vtable_slot(1, g_mnames[i])) < 0) die("no context method %s", g_mnames[i]);
    g_slot_map = d3d11_vtable_slot(1, "Map"); g_slot_unmap = d3d11_vtable_slot(1, "Unmap"); g_slot_update = d3d11_vtable_slot(1, "UpdateSubresource");
}
static void texture_record(rd *r) {
    r32(r); uint32_t xid = r32(r), dim = r32(r), nw = r32(r);
    uint32_t desc[11] = { 0 };
    for (uint32_t i = 0; i < nw; i++) { uint32_t v = r32(r); if (i < 11) desc[i] = v; }
    uint32_t subs = r32(r), has = r32(r);
    SUBRESOURCE_DATA *init = has ? calloc(subs, sizeof *init) : NULL;
    for (uint32_t s = 0; has && s < subs; s++) {
        if (!r32(r)) continue;
        uint32_t row = r32(r), rows = r32(r); r32(r);
        uint32_t size = r32(r);
        init[s] = (SUBRESOURCE_DATA){ rbytes(r, size), row, row * rows };
    }
    void *out = NULL;
    HRESULT hr = DCALL(dim == 1 ? DS_TEX1 : dim == 2 ? DS_TEX2 : DS_TEX3, HRESULT (*)(void *, const uint32_t *, const SUBRESOURCE_DATA *, void **))(g_dev, desc, init, &out);
    check(hr, "CreateTexture", xid);
    free(init);
    put_obj(xid, out, D3DCAP_TEXTURE);
}
static void foreign_texture_record(rd *r) {
    r32(r); uint32_t xid = r32(r), dim = r32(r), depth = r32(r), d[11];
    for (int i = 0; i < 11; i++) d[i] = r32(r);
    d[TD_MISC] &= ~(0x2u | 0x100u | 0x800u);       // not shared here
    d[TD_USAGE] = d[TD_USAGE] == 1 ? 0 : d[TD_USAGE];   // (immutable without contents: default)
    uint32_t raw[11];
    if (dim == 1) { uint32_t v[8] = { d[0], d[2], d[3], d[4], d[7], d[8], d[9], d[10] }; memcpy(raw, v, sizeof v); }
    else if (dim == 3) { uint32_t v[9] = { d[0], d[1], depth, d[2], d[4], d[7], d[8], d[9], d[10] }; memcpy(raw, v, sizeof v); }
    else memcpy(raw, d, sizeof raw);
    void *out = NULL;
    HRESULT hr = DCALL(dim == 1 ? DS_TEX1 : dim == 2 ? DS_TEX2 : DS_TEX3, HRESULT (*)(void *, const uint32_t *, const SUBRESOURCE_DATA *, void **))(g_dev, raw, NULL, &out);
    check(hr, "a texture made outside CreateTexture (swap chain, shared)", xid);
    put_obj(xid, out, D3DCAP_TEXTURE);
}
static void buffer_record(rd *r, int foreign) {
    r32(r); uint32_t xid = r32(r), desc[6];
    for (int i = 0; i < 6; i++) desc[i] = r32(r);
    SUBRESOURCE_DATA init = { 0 };
    if (!foreign && r32(r)) { uint32_t n = r32(r); init.data = rbytes(r, n); }
    if (foreign) desc[4] &= ~(0x2u | 0x100u | 0x800u);
    void *out = NULL;
    HRESULT hr = DCALL(DS_BUFFER, HRESULT (*)(void *, const uint32_t *, const SUBRESOURCE_DATA *, void **))(g_dev, desc, init.data ? &init : NULL, &out);
    check(hr, "CreateBuffer", xid);
    put_obj(xid, out, D3DCAP_BUFFER);
}
static void view_record(rd *r) {
    r32(r); uint32_t xid = r32(r), kind = r32(r), res = r32(r), has = r32(r), desc[6];
    for (int i = 0; i < 6; i++) desc[i] = r32(r);
    void *out = NULL;
    HRESULT hr = DCALL(DS_SRV + kind, HRESULT (*)(void *, void *, const uint32_t *, void **))(g_dev, obj(res), has ? desc : NULL, &out);
    check(hr, "Create*View", xid);
    put_obj(xid, out, D3DCAP_VIEW);
}
static uint32_t sha_prefix(const void *p, size_t n) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(p, (CC_LONG)n, d);
    return (uint32_t)d[0] << 24 | (uint32_t)d[1] << 16 | (uint32_t)d[2] << 8 | d[3];
}
static void shader_record(rd *r) {
    r32(r); uint32_t xid = r32(r), stage = r32(r), size = r32(r);
    const void *code = rbytes(r, size);
    void *out = NULL;
    HRESULT hr;
    if (stage == 4) {
        uint32_t n = r32(r);
        so_decl *d = calloc(n ? n : 1, sizeof *d);
        char (*names)[64] = calloc(n ? n : 1, 64);
        for (uint32_t i = 0; i < n; i++) {
            d[i].stream = r32(r); d[i].semantic = rstr(r, names[i], 64); d[i].index = r32(r);
            d[i].start = (uint8_t)r32(r); d[i].count = (uint8_t)r32(r); d[i].slot = (uint8_t)r32(r);
            if (!names[i][0]) d[i].semantic = NULL;
        }
        uint32_t ns = r32(r), strides[8] = { 0 };
        for (uint32_t i = 0; i < ns; i++) { uint32_t v = r32(r); if (i < 8) strides[i] = v; }
        uint32_t rast = r32(r);
        hr = DCALL(DS_GSSO, HRESULT (*)(void *, const void *, size_t, const so_decl *, uint32_t, const uint32_t *, uint32_t, uint32_t, void *, void **))
             (g_dev, code, size, d, n, ns ? strides : NULL, ns, rast, NULL, &out);
        free(d); free(names);
    } else {
        static const int slot[4] = { DS_VS, DS_PS, DS_CS, DS_GS };
        HRESULT (*create)(void *, const void *, size_t, void *, void **) = (HRESULT (*)(void *, const void *, size_t, void *, void **))dvt()[g_dslot[slot[stage & 3]]];
        job *j = calloc(1, sizeof *j);
        void *copy = malloc(size); memcpy(copy, code, size);
        put_obj(xid, j, PENDING);
        g_obj[xid].hash = sha_prefix(code, size);
        dispatch_semaphore_wait(g_jobs_slots, DISPATCH_TIME_FOREVER);
        void *dev = g_dev;
        dispatch_group_async(g_jobs, g_jobs_queue, ^{
            void *made = NULL;
            HRESULT made_hr = create(dev, copy, size, NULL, &made);
            if (made_hr != S_OK) fprintf(stderr, "replay: Create*Shader for object %u failed: %#x\n", xid, (unsigned)made_hr);
            free(copy);
            j->p = made;
            __atomic_store_n(&j->done, 1, __ATOMIC_RELEASE);
            dispatch_semaphore_signal(g_jobs_slots);
        });
        return;
    }
    check(hr, "Create*Shader", xid);
    put_obj(xid, out, D3DCAP_SHADER);
    if (xid < g_nobj) g_obj[xid].hash = sha_prefix(code, size);
}
static void layout_record(rd *r) {
    r32(r); uint32_t xid = r32(r), n = r32(r);
    INPUT_ELEMENT *e = calloc(n ? n : 1, sizeof *e);
    char (*names)[64] = calloc(n ? n : 1, 64);
    for (uint32_t i = 0; i < n; i++) {
        e[i].semantic = rstr(r, names[i], 64); e[i].index = r32(r); e[i].format = r32(r); e[i].slot = r32(r);
        e[i].offset = r32(r); e[i].classification = r32(r); e[i].step = r32(r);
    }
    uint32_t size = r32(r);
    const void *code = rbytes(r, size);
    void *out = NULL;
    HRESULT hr = DCALL(DS_LAYOUT, HRESULT (*)(void *, const INPUT_ELEMENT *, uint32_t, const void *, size_t, void **))(g_dev, e, n, code, size, &out);
    check(hr, "CreateInputLayout", xid);
    free(e); free(names);
    put_obj(xid, out, D3DCAP_LAYOUT);
}
static void state_record(rd *r) {
    r32(r); uint32_t xid = r32(r), kind = r32(r), size = r32(r);
    const void *desc = rbytes(r, size);
    void *out = NULL;
    HRESULT hr = DCALL(DS_BLEND + (kind < 6 ? kind : 0), HRESULT (*)(void *, const void *, void **))(g_dev, desc, &out);
    check(hr, "Create*State", xid);
    put_obj(xid, out, D3DCAP_STATE);
}
static void destroy_record(rd *r) {
    uint32_t xid = r32(r);
    if (xid >= g_nobj || !g_obj[xid].p || g_obj[xid].kind == D3DCAP_DEVICE) return;
    void *o = g_obj[xid].kind == PENDING ? resolve(xid) : g_obj[xid].p;
    if (!o) return;
    ((uint32_t (*)(void *))(*(void ***)o)[2])(o);   // IUnknown::Release
    g_obj[xid].p = NULL;
}

// Map: the replay's own copy of what the program wrote (as the capture's), put in place at each Unmap.
typedef struct map_shadow { uint64_t key; uint8_t *data; size_t size; struct map_shadow *next; } map_shadow;
static map_shadow *g_shadows[4096];
static map_shadow *shadow_of(uint32_t xid, uint32_t sub, size_t size) {
    uint64_t key = (uint64_t)xid << 32 | sub;
    map_shadow **l = &g_shadows[(xid * 31 + sub) & 4095];
    for (map_shadow *s = *l; s; s = s->next)
        if (s->key == key) { if (s->size != size) { free(s->data); s->data = calloc(1, size ? size : 1); s->size = size; } return s; }
    map_shadow *s = calloc(1, sizeof *s);
    s->key = key; s->data = calloc(1, size ? size : 1); s->size = size; s->next = *l; *l = s;
    return s;
}
static void unmap_record(rd *r) {
    r32(r); uint32_t xid = r32(r), sub = r32(r), type = r32(r), flags = r32(r), row = r32(r), depth = r32(r), size = r32(r);
    map_shadow *s = shadow_of(xid, sub, size);
    typedef struct { uint32_t off, len; const uint8_t *p; } run;
    run *runs = NULL; size_t nruns = 0, cap = 0;
    for (;;) {
        uint32_t off = r32(r);
        if (off == 0xffffffffu) break;
        uint32_t len = r32(r);
        const uint8_t *p = rbytes(r, len);
        if ((size_t)off + len > size) die("map run outside the mapping");
        memcpy(s->data + off, p, len);
        if (nruns == cap) { cap = cap * 2 + 16; runs = realloc(runs, cap * sizeof *runs); }
        runs[nruns++] = (run){ off, len, p };
    }
    d3d_object *res = obj(xid);
    if (!res) { free(runs); return; }
    MAPPED m = { 0 };
    HRESULT hr = ((HRESULT (*)(void *, void *, uint32_t, uint32_t, uint32_t, MAPPED *))cvt()[g_slot_map])(g_ctx, res, sub, type, flags & ~0x100000u, &m);
    if (hr) { check(hr, "Map", xid); free(runs); return; }
    if (res->kind == K_BUFFER) {
        if (type == 4) memcpy(m.data, s->data, size);          // WRITE_DISCARD: new storage, all of it
        else for (size_t i = 0; i < nruns; i++) memcpy((uint8_t *)m.data + runs[i].off, runs[i].p, runs[i].len);
    } else if (m.row_pitch == row && m.depth_pitch == depth) memcpy(m.data, s->data, size);
    else {
        d3d_texture *t = (d3d_texture *)res;
        uint32_t mips = t->desc[TD_MIPS] ? t->desc[TD_MIPS] : 1, mip = sub % mips;
        uint32_t w = t->desc[TD_WIDTH] >> mip, h = t->dim > 1 ? t->desc[TD_HEIGHT] >> mip : 1, d = t->dim == 3 ? t->depth >> mip : 1;
        if (!w) w = 1; if (!h) h = 1; if (!d) d = 1;
        uint32_t bw = 1, bh = 1, bpb = 4;
        d3d_copy_format_block(t->desc[TD_FORMAT], &bw, &bh, &bpb);
        uint32_t rb = (w + bw - 1) / bw * bpb, rows = (h + bh - 1) / bh;
        for (uint32_t z = 0; z < d; z++) for (uint32_t y = 0; y < rows; y++)
            memcpy((uint8_t *)m.data + (size_t)z * m.depth_pitch + (size_t)y * m.row_pitch, s->data + (size_t)z * depth + (size_t)y * row, rb);
    }
    ((void (*)(void *, void *, uint32_t))cvt()[g_slot_unmap])(g_ctx, res, sub);
    free(runs);
}
static void update_record(rd *r) {
    r32(r); uint32_t xid = r32(r), sub = r32(r);
    const uint32_t *box = rwords(r, 6);
    uint32_t row = r32(r), rows = r32(r); r32(r);
    uint32_t size = r32(r);
    const void *data = rbytes(r, size);
    void *res = obj(xid);
    if (!res) return;
    ((void (*)(void *, void *, uint32_t, const uint32_t *, const void *, uint32_t, uint32_t))cvt()[g_slot_update])(g_ctx, res, sub, box, data, row, row * rows);
}
static uint64_t g_reads, g_reads_checked, g_reads_same;
static int g_check_reads;
static void map_read_record(rd *r) {
    r32(r); uint32_t xid = r32(r), sub = r32(r), type = r32(r), live_size = r32(r);
    uint64_t live; memcpy(&live, rbytes(r, 8), 8);
    g_reads++;
    if ((!g_dump_reads && !g_check_reads) || !in_range()) return;
    d3d_object *res = obj(xid);
    if (!res) return;
    MAPPED m = { 0 };
    HRESULT hr = ((HRESULT (*)(void *, void *, uint32_t, uint32_t, uint32_t, MAPPED *))cvt()[g_slot_map])(g_ctx, res, sub, type, 0, &m);
    if (hr) { check(hr, "Map (read)", xid); return; }
    size_t rb, rows, d = 1;
    if (res->kind == K_BUFFER) { rb = ((d3d_buffer *)res)->desc[0]; rows = 1; }
    else {
        d3d_texture *t = (d3d_texture *)res;
        uint32_t mips = t->desc[TD_MIPS] ? t->desc[TD_MIPS] : 1, mip = sub % mips;
        uint32_t w = t->desc[TD_WIDTH] >> mip, h = t->dim > 1 ? t->desc[TD_HEIGHT] >> mip : 1;
        if (!w) w = 1; if (!h) h = 1;
        d = t->dim == 3 ? (t->depth >> mip ? t->depth >> mip : 1) : 1;
        uint32_t bw = 1, bh = 1, bpb = 4;
        d3d_copy_format_block(t->desc[TD_FORMAT], &bw, &bh, &bpb);
        rb = (w + bw - 1) / bw * bpb; rows = (h + bh - 1) / bh;
    }
    uint8_t *tight = malloc(rb * rows * d);
    for (size_t z = 0; z < d; z++) for (size_t y = 0; y < rows; y++)
        memcpy(tight + (z * rows + y) * rb, (uint8_t *)m.data + z * m.depth_pitch + y * m.row_pitch, rb);
    ((void (*)(void *, void *, uint32_t))cvt()[g_slot_unmap])(g_ctx, res, sub);
    char path[1200] = "";
    if (g_dump_reads) {
        snprintf(path, sizeof path, "%s/read%llu_obj%u_sub%u.bin", g_dump_dir, (unsigned long long)g_reads, xid, sub);
        write_file(path, tight, rb * rows * d);
    }
    uint64_t h = fnv(tight, rb * rows * d);
    int same = h == live && rb * rows * d == live_size;
    g_reads_checked++; if (same) g_reads_same++;
    if (g_dump_reads || !same)
        printf("read %llu (frame %llu): object %u sub %u, %zu bytes, fnv %016llx, live %016llx (%u bytes): %s%s%s\n", (unsigned long long)g_reads,
               (unsigned long long)g_frame, xid, sub, rb * rows * d, (unsigned long long)h, (unsigned long long)live, live_size,
               same ? "same" : "DIFFERENT", path[0] ? " -> " : "", path);
    free(tight);
}

typedef void (*list_fn)(void *, uint32_t, uint32_t, void *const *);
typedef void (*one_fn)(void *, void *);
static void call_record(rd *r) {
    uint32_t m = r32(r); r32(r);
    void *a[128], *b[128];
    if (m >= D3DCAP_M_COUNT) die("unknown method %u", m);
    if (g_frame < g_skip_before)                     // --skip-before/--fast: no draws or dispatches before that frame (all else kept)
        switch (m) {
        case D3DCAP_M_Draw: case D3DCAP_M_DrawInstanced: case D3DCAP_M_DrawIndexed: case D3DCAP_M_DrawIndexedInstanced: case D3DCAP_M_Dispatch:
            g_skipped++;
            if (m == D3DCAP_M_Draw || m == D3DCAP_M_DrawInstanced || m == D3DCAP_M_DrawIndexed || m == D3DCAP_M_DrawIndexedInstanced ||
                m == D3DCAP_M_Dispatch) { g_draws++; g_frame_draws++; }   // (the draw numbers stay those of a full replay)
            return;
        }
    void *f = cvt()[g_cslot[m]];
    switch (m) {
    case D3DCAP_M_VSSetConstantBuffers: case D3DCAP_M_PSSetConstantBuffers: case D3DCAP_M_GSSetConstantBuffers: case D3DCAP_M_CSSetConstantBuffers:
    case D3DCAP_M_VSSetShaderResources: case D3DCAP_M_PSSetShaderResources: case D3DCAP_M_GSSetShaderResources: case D3DCAP_M_CSSetShaderResources:
    case D3DCAP_M_VSSetSamplers: case D3DCAP_M_PSSetSamplers: case D3DCAP_M_GSSetSamplers: case D3DCAP_M_CSSetSamplers: {
        uint32_t start = r32(r), n = r32(r);
        void *const *objs = rids(r, n, a);
        ((list_fn)f)(g_ctx, start, n > 128 ? 128 : n, objs);
        break;
    }
    case D3DCAP_M_VSSetShader: case D3DCAP_M_PSSetShader: case D3DCAP_M_GSSetShader: case D3DCAP_M_CSSetShader:
    case D3DCAP_M_HSSetShader: case D3DCAP_M_DSSetShader: {
        uint32_t xid = r32(r);
        if (m == D3DCAP_M_VSSetShader) g_vs = xid; else if (m == D3DCAP_M_PSSetShader) g_ps = xid; else if (m == D3DCAP_M_CSSetShader) g_cs = xid;
        ((void (*)(void *, void *, void *const *, uint32_t))f)(g_ctx, obj(xid), NULL, 0);
        break;
    }
    case D3DCAP_M_IASetInputLayout: case D3DCAP_M_RSSetState: case D3DCAP_M_GenerateMips: case D3DCAP_M_DiscardResource: case D3DCAP_M_DiscardView:
        ((one_fn)f)(g_ctx, obj(r32(r)));
        break;
    case D3DCAP_M_ClearState: case D3DCAP_M_Flush:
        ((void (*)(void *))f)(g_ctx);
        break;
    case D3DCAP_M_IASetVertexBuffers: {
        uint32_t start = r32(r), n = r32(r);
        void *const *bufs = rids(r, n, a);
        const uint32_t *strides = rwords(r, n), *offsets = rwords(r, n);
        ((void (*)(void *, uint32_t, uint32_t, void *const *, const uint32_t *, const uint32_t *))f)(g_ctx, start, n, bufs, strides, offsets);
        break;
    }
    case D3DCAP_M_IASetIndexBuffer: {
        uint32_t xid = r32(r), format = r32(r), offset = r32(r);
        ((void (*)(void *, void *, uint32_t, uint32_t))f)(g_ctx, obj(xid), format, offset);
        break;
    }
    case D3DCAP_M_IASetPrimitiveTopology: ((void (*)(void *, uint32_t))f)(g_ctx, r32(r)); break;
    case D3DCAP_M_OMSetRenderTargets: {
        uint32_t n = r32(r);
        const uint8_t *at = r->p;
        void *const *rtvs = rids(r, n, a);
        uint32_t dsv = r32(r);
        rd again = { at, r->end };
        g_nrtv = n; memset(g_rtv, 0, sizeof g_rtv);
        if (r32(&again)) for (uint32_t i = 0; i < n; i++) { uint32_t xid = r32(&again); if (i < 8) g_rtv[i] = xid; }
        g_dsv = dsv;
        ((void (*)(void *, uint32_t, void *const *, void *))f)(g_ctx, n, rtvs, obj(dsv));
        break;
    }
    case D3DCAP_M_OMSetRenderTargetsAndUnorderedAccessViews: {
        uint32_t nrtv = r32(r);
        void *const *rtvs = NULL;
        if (nrtv != 0xffffffffu) {
            const uint8_t *at = r->p;
            rtvs = rids(r, nrtv, a);
            rd again = { at, r->end };
            g_nrtv = nrtv; memset(g_rtv, 0, sizeof g_rtv);
            if (r32(&again)) for (uint32_t i = 0; i < nrtv; i++) { uint32_t xid = r32(&again); if (i < 8) g_rtv[i] = xid; }
        }
        uint32_t dsv = r32(r);
        if (nrtv != 0xffffffffu) g_dsv = dsv;
        uint32_t start = r32(r), nuav = r32(r);
        void *const *uavs = NULL; const uint32_t *counts = NULL;
        if (nuav != 0xffffffffu) { uavs = rids(r, nuav, b); counts = rwords(r, nuav); }
        ((void (*)(void *, uint32_t, void *const *, void *, uint32_t, uint32_t, void *const *, const uint32_t *))f)(g_ctx, nrtv, rtvs, obj(dsv), start, nuav, uavs, counts);
        break;
    }
    case D3DCAP_M_CSSetUnorderedAccessViews: {
        uint32_t start = r32(r), n = r32(r);
        void *const *uavs = rids(r, n, a);
        const uint32_t *counts = rwords(r, n);
        ((void (*)(void *, uint32_t, uint32_t, void *const *, const uint32_t *))f)(g_ctx, start, n, uavs, counts);
        break;
    }
    case D3DCAP_M_OMSetBlendState: {
        uint32_t xid = r32(r); const float *factor = rwords(r, 4); uint32_t mask = r32(r);
        ((void (*)(void *, void *, const float *, uint32_t))f)(g_ctx, obj(xid), factor, mask);
        break;
    }
    case D3DCAP_M_OMSetDepthStencilState: { uint32_t xid = r32(r), ref = r32(r); ((void (*)(void *, void *, uint32_t))f)(g_ctx, obj(xid), ref); break; }
    case D3DCAP_M_SOSetTargets: {
        uint32_t n = r32(r);
        void *const *bufs = rids(r, n, a);
        const uint32_t *offsets = rwords(r, n);
        ((void (*)(void *, uint32_t, void *const *, const uint32_t *))f)(g_ctx, n, bufs, offsets);
        break;
    }
    case D3DCAP_M_RSSetViewports: { uint32_t n = r32(r); const float *vp = rwords(r, n * 6); ((void (*)(void *, uint32_t, const float *))f)(g_ctx, n, vp); break; }
    case D3DCAP_M_RSSetScissorRects: { uint32_t n = r32(r); const int32_t *rc = rwords(r, n * 4); ((void (*)(void *, uint32_t, const int32_t *))f)(g_ctx, n, rc); break; }
    case D3DCAP_M_Draw: { uint32_t c = r32(r), s = r32(r); ((void (*)(void *, uint32_t, uint32_t))f)(g_ctx, c, s); after_draw("Draw"); break; }
    case D3DCAP_M_DrawInstanced: {
        uint32_t c = r32(r), i = r32(r), s = r32(r), si = r32(r);
        ((void (*)(void *, uint32_t, uint32_t, uint32_t, uint32_t))f)(g_ctx, c, i, s, si); after_draw("DrawInstanced"); break;
    }
    case D3DCAP_M_DrawIndexed: {
        uint32_t c = r32(r), s = r32(r); int32_t base = (int32_t)r32(r);
        ((void (*)(void *, uint32_t, uint32_t, int32_t))f)(g_ctx, c, s, base); after_draw("DrawIndexed"); break;
    }
    case D3DCAP_M_DrawIndexedInstanced: {
        uint32_t c = r32(r), i = r32(r), s = r32(r); int32_t base = (int32_t)r32(r); uint32_t si = r32(r);
        ((void (*)(void *, uint32_t, uint32_t, uint32_t, int32_t, uint32_t))f)(g_ctx, c, i, s, base, si); after_draw("DrawIndexedInstanced"); break;
    }
    case D3DCAP_M_Dispatch: {
        uint32_t x = r32(r), y = r32(r), z = r32(r);
        ((void (*)(void *, uint32_t, uint32_t, uint32_t))f)(g_ctx, x, y, z); after_draw("Dispatch"); break;
    }
    case D3DCAP_M_CopySubresourceRegion: {
        uint32_t dst = r32(r), ds = r32(r), x = r32(r), y = r32(r), z = r32(r), src = r32(r), ss = r32(r);
        const uint32_t *box = rwords(r, 6);
        ((void (*)(void *, void *, uint32_t, uint32_t, uint32_t, uint32_t, void *, uint32_t, const uint32_t *))f)(g_ctx, obj(dst), ds, x, y, z, obj(src), ss, box);
        break;
    }
    case D3DCAP_M_CopyResource: { uint32_t dst = r32(r), src = r32(r); ((void (*)(void *, void *, void *))f)(g_ctx, obj(dst), obj(src)); break; }
    case D3DCAP_M_CopyStructureCount: {
        uint32_t dst = r32(r), off = r32(r), v = r32(r);
        ((void (*)(void *, void *, uint32_t, void *))f)(g_ctx, obj(dst), off, obj(v)); break;
    }
    case D3DCAP_M_ResolveSubresource: {
        uint32_t dst = r32(r), ds = r32(r), src = r32(r), ss = r32(r), fmt = r32(r);
        ((void (*)(void *, void *, uint32_t, void *, uint32_t, uint32_t))f)(g_ctx, obj(dst), ds, obj(src), ss, fmt); break;
    }
    case D3DCAP_M_ClearRenderTargetView: {
        uint32_t v = r32(r); const float *c = rwords(r, 4);
        ((void (*)(void *, void *, const float *))f)(g_ctx, obj(v), c); break;
    }
    case D3DCAP_M_ClearDepthStencilView: {
        uint32_t v = r32(r), flags = r32(r); float depth = rf(r); uint32_t st = r32(r);
        ((void (*)(void *, void *, uint32_t, float, uint8_t))f)(g_ctx, obj(v), flags, depth, (uint8_t)st); break;
    }
    case D3DCAP_M_ClearUnorderedAccessViewUint: case D3DCAP_M_ClearUnorderedAccessViewFloat: {
        uint32_t v = r32(r); const void *vals = rwords(r, 4);
        ((void (*)(void *, void *, const void *))f)(g_ctx, obj(v), vals); break;
    }
    case D3DCAP_M_DiscardView1: {
        uint32_t v = r32(r), n = r32(r); const int32_t *rc = rwords(r, n * 4);
        ((void (*)(void *, void *, const int32_t *, uint32_t))f)(g_ctx, obj(v), rc, n); break;
    }
    default: die("method %s is not replayed", g_mnames[m]);
    }
}

// ---- main --------------------------------------------------------------------------------------------------------------------
static void usage(void) {
    fprintf(stderr, "usage: vxrt-d3d11-replay <capture> [--frames a-b] [--dump-eyes dir] [--compare-eyes dir] [--dump-rt spec] [--dump-dir dir]\n"
                    "                         [--dump-reads] [--check-reads] [--list-draws] [--from f [--fast[=k]]] [--skip-before f] [--stats] [--max-dumps n] [--env K=V]... [--quiet]\n");
    exit(2);
}
static void parse_specs(const char *s) {
    char buf[1024]; snprintf(buf, sizeof buf, "%s", s);
    for (char *tok = strtok(buf, ","); tok && g_nspecs < 64; tok = strtok(NULL, ",")) {
        rt_spec *sp = &g_specs[g_nspecs++];
        if (!strncmp(tok, "ps:", 3)) { sp->kind = 2; sp->a = strtoull(tok + 3, NULL, 16); }
        else if (strchr(tok, ':')) { sp->kind = 1; sp->a = strtoull(tok, NULL, 10); sp->b = strtoull(strchr(tok, ':') + 1, NULL, 10); }
        else { sp->kind = 0; sp->a = strtoull(tok, NULL, 10); }
    }
}
int main(int argc, char **argv) {
    {   // (no @autoreleasepool: d3d_flush drains its own pool, and must not run inside one)
    const char *path = NULL;
    int64_t fast = -1;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--frames") && v) {
            i++;
            const char *dash = strchr(v, '-');
            g_from = strtoull(v, NULL, 10); g_to = dash ? (dash[1] ? strtoull(dash + 1, NULL, 10) : UINT64_MAX) : g_from;
        }
        else if (!strcmp(a, "--dump-eyes") && v) { g_eye_dir = v; i++; mkdir(v, 0755); }
        else if (!strcmp(a, "--compare-eyes") && v) { g_cmp_dir = v; i++; }
        else if (!strcmp(a, "--dump-rt") && v) { parse_specs(v); i++; }
        else if (!strcmp(a, "--dump-dir") && v) { g_dump_dir = v; i++; mkdir(v, 0755); }
        else if (!strcmp(a, "--dump-reads")) g_dump_reads = 1;
        else if (!strcmp(a, "--check-reads")) g_check_reads = 1;
        else if (!strcmp(a, "--list-draws")) g_list = 1;
        else if (!strcmp(a, "--skip-before") && v) { g_skip_before = strtoull(v, NULL, 10); i++; }
        else if (!strcmp(a, "--from") && v) { g_from = strtoull(v, NULL, 10); g_to = UINT64_MAX; i++; }
        else if (!strncmp(a, "--fast", 6) && (!a[6] || a[6] == '=')) fast = a[6] ? (int64_t)strtoll(a + 7, NULL, 10) : 200;
        else if (!strcmp(a, "--stats")) g_stats = 1;
        else if (!strcmp(a, "--max-dumps") && v) { g_max_dumps = atoi(v); i++; }
        else if (!strcmp(a, "--env") && v) {
            char kv[1024]; snprintf(kv, sizeof kv, "%s", v); i++;
            char *eq = strchr(kv, '='); if (!eq) usage();
            *eq = 0; setenv(kv, eq + 1, 1);
        }
        else if (!strcmp(a, "--quiet")) vx_replay_quiet = 1;
        else if (a[0] != '-' && !path) path = a;
        else usage();
    }
    if (!path) usage();
    if (fast >= 0) {
        if (!g_from) die("--fast needs --from");
        g_skip_before = g_from > (uint64_t)fast ? g_from - (uint64_t)fast : 0;
    }
    if (getenv("VXRT_D3D11_CAPTURE")) unsetenv("VXRT_D3D11_CAPTURE");   // (the replay is not captured)
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot open %s", path);
    char magic[16];
    if (fread(magic, 1, 16, f) != 16 || memcmp(magic, D3DCAP_MAGIC, 8)) die("%s is not a Direct3D 11 capture", path);
    uint32_t version; memcpy(&version, magic + 8, 4);
    if (version != D3DCAP_VERSION) die("capture version %u, this replayer reads %u", version, D3DCAP_VERSION);
    // Whether frames are VR eye frames: an eye frame early in the capture says (a VR program may present a desktop
    // mirror too, and once before its first eye frame).
    for (uint64_t n = 0, presents = 0; g_eye_unit < 0 && n < 4000000 && presents < 100; n++) {
        uint32_t h[2];
        if (fread(h, 4, 2, f) != 2) break;
        if (h[0] == D3DCAP_EYE_FRAME) g_eye_unit = 1;
        if (h[0] == D3DCAP_PRESENT) presents++;
        if (fseeko(f, h[1], SEEK_CUR)) break;
    }
    if (g_eye_unit < 0) g_eye_unit = 0;
    fseeko(f, 16, SEEK_SET);
    vx_d3d11_init();
    g_jobs_queue = dispatch_queue_create("replay shaders", DISPATCH_QUEUE_CONCURRENT);
    g_jobs = dispatch_group_create();
    g_jobs_slots = dispatch_semaphore_create((long)NSProcessInfo.processInfo.activeProcessorCount);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), records = 0, bytes = 16, presents = 0;
    uint8_t *buf = NULL; size_t cap = 0;
    int clean = 0, truncated = 0;
    for (;;) {
        uint32_t h[2];
        if (fread(h, 4, 2, f) != 2) { truncated = ftello(f) == (off_t)bytes ? 2 : 1; break; }
        if (h[1] > cap) { cap = (size_t)h[1] * 2; buf = realloc(buf, cap); }
        if (fread(buf, 1, h[1], f) != h[1]) { truncated = 1; break; }
        rd r = { buf, buf + h[1] };
        records++; bytes += 8 + (uint64_t)h[1];
        g_op_count[h[0] & 31]++; g_op_bytes[h[0] & 31] += 8 + (uint64_t)h[1];
        if (h[0] != D3DCAP_DEVICE && h[0] != D3DCAP_END && h[0] != D3DCAP_DESTROY && h[0] != D3DCAP_EYE_FRAME && h[0] != D3DCAP_PRESENT && !g_dev)
            die("record %llu (op %u) before any device", (unsigned long long)records, h[0]);
        {
        switch (h[0]) {
        case D3DCAP_DEVICE: device_record(&r); break;
        case D3DCAP_TEXTURE: texture_record(&r); break;
        case D3DCAP_BUFFER: buffer_record(&r, 0); break;
        case D3DCAP_VIEW: view_record(&r); break;
        case D3DCAP_SHADER: shader_record(&r); break;
        case D3DCAP_LAYOUT: layout_record(&r); break;
        case D3DCAP_STATE: state_record(&r); break;
        case D3DCAP_DESTROY: destroy_record(&r); break;
        case D3DCAP_FOREIGN_TEXTURE: foreign_texture_record(&r); break;
        case D3DCAP_FOREIGN_BUFFER: buffer_record(&r, 1); break;
        case D3DCAP_CALL: call_record(&r); break;
        case D3DCAP_UNMAP: unmap_record(&r); break;
        case D3DCAP_UPDATE: update_record(&r); break;
        case D3DCAP_MAP_READ: map_read_record(&r); break;
        case D3DCAP_PRESENT: {
            r32(&r); presents++;
            if (g_dev) d3d_flush(g_dev, 0);
            if (!g_eye_unit) frame_done(r32(&r));
            break;
        }
        case D3DCAP_EYE: eye_record(&r); break;
        case D3DCAP_EYE_FRAME: frame_done(r32(&r)); break;
        case D3DCAP_END: clean = 1; break;
        default: die("unknown record op %u", h[0]);
        }
        }
        if (clean || g_frame > g_to) break;
    }
    dispatch_group_wait(g_jobs, DISPATCH_TIME_FOREVER);
    if (g_dev) d3d_flush(g_dev, 1);
    double secs = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e9;
    printf("replayed %llu records (%.1f MB) in %.2f s: %llu frames (%s), %llu draws/dispatches, %llu presents, %llu readbacks; %s\n",
           (unsigned long long)records, (double)bytes / 1048576.0, secs, (unsigned long long)(g_frame - 1), g_eye_unit ? "eye frames" : "presents",
           (unsigned long long)g_draws, (unsigned long long)presents, (unsigned long long)g_reads,
           clean ? "the capture's end" : g_frame > g_to ? "the frames asked for" : truncated == 2 ? "the file ends without an end record (the process ended without closing the capture; a frame or readback flushed what came before)" : truncated ? "the file ends inside a record (a capture cut short): stopped there" : "?");
    if (g_skip_before) printf("fast-forward: %llu draws and dispatches before frame %llu not done (an approximation: what they drew is missing)\n",
                              (unsigned long long)g_skipped, (unsigned long long)g_skip_before);
    if (g_stats) {
        static const char *const names[] = { "", "device", "texture", "buffer", "view", "shader", "layout", "state", "destroy", "foreign texture",
                                             "foreign buffer", "call", "unmap", "update", "map read", "present", "eye", "eye frame", "end" };
        for (int i = 1; i < 19; i++) if (g_op_count[i])
            printf("  %-16s %10llu records %10.1f MB\n", names[i], (unsigned long long)g_op_count[i], (double)g_op_bytes[i] / 1048576.0);
    }
    if (g_cmp_dir) printf("eye images compared with live dumps: %llu, identical %llu\n", (unsigned long long)g_eye_compared, (unsigned long long)g_eye_same);
    if (g_missing || g_fail) printf("warnings: %llu unknown objects, %llu failed creations/maps\n", (unsigned long long)g_missing, (unsigned long long)g_fail);
    fclose(f);
    if (g_check_reads || g_dump_reads) {
        printf("readbacks compared with the live program's: %llu, the same %llu\n", (unsigned long long)g_reads_checked, (unsigned long long)g_reads_same);
        if (g_check_reads && (!g_reads_checked || g_reads_same != g_reads_checked)) return 1;
    }
    }
    return 0;
}
