/* Eye-pair copy ring shared by the Mac dev host and the visionOS host (header only; static functions, no ObjC classes,
 * so both hosts can include it in one binary).
 *
 * The host copies the game's two eye images into independent textures and publishes them to the presenter only after
 * the GPU copy completed. This ring replaces "commit; waitUntilCompleted" on the game's submit path:
 *   - at most `max_inflight` copy command buffers are outstanding; the (max_inflight+1)th submit blocks, and counts it;
 *   - a slot (two private textures) is busy from reserve until its completion handler finished, so a texture cannot be
 *     rewritten while the GPU still copies into it or while the host is publishing it;
 *   - after that the presenter's references (native_vr retain/release callbacks, routed to reader_retain/release)
 *     keep the slot out of the pool until the presenter lets go. A slot is reused only with no reader;
 *   - a failed command buffer calls the completion block with ok=0: the host must not publish;
 *   - drain waits for every outstanding copy (session end, retire, teardown).
 * Same-queue ordering: the copy reads the provider swapchain image after publish_pair returned; the next write into
 * that image is a blit committed on the same provider queue (xrizer_guest_d3d copy_complete), so it runs after the read.
 * VXRT_XR_SYNC_SUBMIT=1 selects the old blocking submit (the hosts keep that path literally). */
#ifndef VX_XRIZER_EYE_RING_H
#define VX_XRIZER_EYE_RING_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdio.h>

#include <objc/runtime.h>
/* The guest-to-provider copy (xrizer_guest_d3d.m) attaches the game producer status to its write buffer. */
@protocol VXXRWriteCheck <NSObject>
- (BOOL)vxProducersOK;
@end
/* Call from the publishing copy completion handler, for each eye write buffer (NULL: none recorded): the buffer
 * completed without error, and the game D3D11 work it waited for did too. */
static inline int vx_eye_ring_writes_ok(id<MTLCommandBuffer> w) {
    if (!w) return 1;
    if (w.status != MTLCommandBufferStatusCompleted || w.error) return 0;
    id<MTLCommandBuffer> prior = objc_getAssociatedObject(w, @selector(klPriorWrites));   /* Klepton's ordered mode: the earlier write */
    if (prior && !vx_eye_ring_writes_ok(prior)) return 0;
    id<VXXRWriteCheck> check = objc_getAssociatedObject(w, @selector(vxProducersOK));
    return !check || [check vxProducersOK];
}
#define VX_EYE_RING_MAX_SLOTS 16
/* up[]: the upscaled eye (VXRT_UPSCALE=metalfx), same format, size r->up_w/up_h; NULL when not upscaling. The presenter reads up[] then. */
typedef struct vx_eye_slot { void *tex[2]; void *up[2]; uint32_t w[2], h[2], fmt[2], uw[2], uh[2]; int busy; unsigned readers; } vx_eye_slot;
typedef struct vx_eye_ring {
    pthread_mutex_t lock; pthread_cond_t cv;
    void *device;
    void (*log)(const char *);
    unsigned max_inflight, inflight, nslots;
    uint32_t up_w, up_h;   /* set by the publisher before reserve: nonzero = give each slot upscale targets of this size (private, shader write) */
    vx_eye_slot *slots[VX_EYE_RING_MAX_SLOTS];
    uint64_t submitted, completed, failed, blocked, allocs, max_seen;
} vx_eye_ring;

static inline int vx_eye_ring_sync_requested(void) {
    const char *e = getenv("VXRT_XR_SYNC_SUBMIT"); return e && !strcmp(e, "1");
}
static inline vx_eye_ring *vx_eye_ring_create(void *device, unsigned max_inflight, void (*log)(const char *)) {
    if (!device) return NULL;
    const char *e = getenv("VXRT_XR_SUBMIT_INFLIGHT");   /* optional experiment knob, 1..4 */
    if (e && atoi(e) >= 1 && atoi(e) <= 4) max_inflight = (unsigned)atoi(e);
    if (!max_inflight) max_inflight = 2;
    vx_eye_ring *r = calloc(1, sizeof *r); if (!r) return NULL;
    pthread_mutex_init(&r->lock, NULL); pthread_cond_init(&r->cv, NULL);
    r->device = (void *)CFRetain(device); r->log = log; r->max_inflight = max_inflight; return r;
}
static inline void vx_eye_ring_free_slot(vx_eye_slot *s) {
    for (unsigned i = 0; i < 2; i++) { if (s->tex[i]) { CFRelease(s->tex[i]); s->tex[i] = NULL; } if (s->up[i]) { CFRelease(s->up[i]); s->up[i] = NULL; } }
}
/* Take a slot whose textures match w/h/fmt for both eyes. Blocks while max_inflight copies are outstanding (counted in
 * `blocked`). Returns 0 and the slot, -1 on failure (out of memory, or no slot freed within 2 s: a stuck reader). */
static inline int vx_eye_ring_reserve(vx_eye_ring *r, const uint32_t w[2], const uint32_t h[2], const uint32_t fmt[2], vx_eye_slot **out) {
    if (!r || !out) return -1;
    pthread_mutex_lock(&r->lock);
    int counted = 0; struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_sec += 2;
    for (;;) {
        if (r->inflight >= r->max_inflight) {
            if (!counted) { ++r->blocked; counted = 1; }
            if (pthread_cond_timedwait(&r->cv, &r->lock, &until)) { pthread_mutex_unlock(&r->lock); return -1; }
            continue;
        }
        vx_eye_slot *pick = NULL;
        for (unsigned i = 0; i < r->nslots; i++) {
            vx_eye_slot *s = r->slots[i]; if (s->busy || s->readers) continue;
            int match = 1; for (unsigned e = 0; e < 2; e++) match &= s->tex[e] && s->w[e] == w[e] && s->h[e] == h[e] && s->fmt[e] == fmt[e] &&
                (r->up_w ? (s->up[e] && s->uw[e] == r->up_w && s->uh[e] == r->up_h) : !s->up[e]);
            if (match) { pick = s; break; }
            if (!pick) pick = s;
        }
        if (!pick && r->nslots < VX_EYE_RING_MAX_SLOTS) {
            pick = calloc(1, sizeof *pick); if (!pick) { pthread_mutex_unlock(&r->lock); return -1; }
            r->slots[r->nslots++] = pick;
        }
        if (!pick) {   /* every slot is busy or still held by the presenter: wait for a release */
            if (pthread_cond_timedwait(&r->cv, &r->lock, &until)) { pthread_mutex_unlock(&r->lock); return -1; }
            continue;
        }
        pick->busy = 1;
        for (unsigned e = 0; e < 2; e++) {
            if (pick->up[e] && (!r->up_w || pick->uw[e] != r->up_w || pick->uh[e] != r->up_h || pick->fmt[e] != fmt[e])) { CFRelease(pick->up[e]); pick->up[e] = NULL; }
            if (r->up_w && !pick->up[e]) {
                MTLTextureDescriptor *ud = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)fmt[e] width:r->up_w height:r->up_h mipmapped:NO];
                ud.storageMode = MTLStorageModePrivate; ud.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
                id<MTLTexture> ut = [(__bridge id<MTLDevice>)r->device newTextureWithDescriptor:ud];
                if (!ut) { pick->busy = 0; pthread_cond_broadcast(&r->cv); pthread_mutex_unlock(&r->lock); return -1; }
                pick->up[e] = (void *)CFBridgingRetain(ut); pick->uw[e] = r->up_w; pick->uh[e] = r->up_h; ++r->allocs;
            }
            if (pick->tex[e] && pick->w[e] == w[e] && pick->h[e] == h[e] && pick->fmt[e] == fmt[e]) continue;
            if (pick->tex[e]) { CFRelease(pick->tex[e]); pick->tex[e] = NULL; }
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)fmt[e] width:w[e] height:h[e] mipmapped:NO];
            d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> t = [(__bridge id<MTLDevice>)r->device newTextureWithDescriptor:d];
            if (!t) { pick->busy = 0; pthread_cond_broadcast(&r->cv); pthread_mutex_unlock(&r->lock); return -1; }
            pick->tex[e] = (void *)CFBridgingRetain(t); pick->w[e] = w[e]; pick->h[e] = h[e]; pick->fmt[e] = fmt[e]; ++r->allocs;
        }
        ++r->inflight; if (r->inflight > r->max_seen) r->max_seen = r->inflight;
        *out = pick; pthread_mutex_unlock(&r->lock); return 0;
    }
}
/* The copy was not committed (validation failed after reserve). */
static inline void vx_eye_ring_abort(vx_eye_ring *r, vx_eye_slot *s) {
    pthread_mutex_lock(&r->lock); s->busy = 0; --r->inflight; pthread_cond_broadcast(&r->cv); pthread_mutex_unlock(&r->lock);
}
static inline void vx_eye_ring_log_stats(vx_eye_ring *r) {
    if (r && r->log) { char m[192]; snprintf(m, sizeof m, "xr submit ring: submitted %llu completed %llu failed %llu blocked-at-bound %llu max-in-flight %llu texture-allocs %llu",
           (unsigned long long)r->submitted, (unsigned long long)r->completed, (unsigned long long)r->failed,
           (unsigned long long)r->blocked, (unsigned long long)r->max_seen, (unsigned long long)r->allocs); r->log(m); }
}
/* Commit `cb` (already encoded with copies into the slot) and run `done(ok, gpu_seconds)` from its completion handler;
 * the slot stays busy until `done` returned. ok is 0 when the command buffer failed. */
static inline void vx_eye_ring_commit(vx_eye_ring *r, id<MTLCommandBuffer> cb, vx_eye_slot *s, void (^done)(int ok, double gpu_s)) {
    pthread_mutex_lock(&r->lock); unsigned long long n = ++r->submitted; pthread_mutex_unlock(&r->lock);
    if (n % 600 == 0) vx_eye_ring_log_stats(r);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        int ok = finished.status == MTLCommandBufferStatusCompleted && !finished.error;
        double gpu = ok && finished.GPUEndTime > finished.GPUStartTime ? finished.GPUEndTime - finished.GPUStartTime : 0;
        if (!ok && r->log) { char m[128]; snprintf(m, sizeof m, "xr submit: copy command buffer failed (status %ld): frame not published", (long)finished.status); r->log(m); }
        if (done) done(ok, gpu);
        pthread_mutex_lock(&r->lock);
        if (ok) ++r->completed; else ++r->failed;
        s->busy = 0; --r->inflight; pthread_cond_broadcast(&r->cv); pthread_mutex_unlock(&r->lock);
    }];
    [cb commit];
}
/* Presenter/native_vr references (the native_vr retain/release callbacks). Returns 1 when `tex` belongs to the ring. */
static inline int vx_eye_ring_reader(vx_eye_ring *r, void *tex, int delta) {
    if (!r || !tex) return 0;
    pthread_mutex_lock(&r->lock);
    for (unsigned i = 0; i < r->nslots; i++) for (unsigned e = 0; e < 2; e++) if (r->slots[i]->tex[e] == tex || r->slots[i]->up[e] == tex) {
        if (delta > 0) ++r->slots[i]->readers; else if (r->slots[i]->readers) --r->slots[i]->readers;
        pthread_cond_broadcast(&r->cv); pthread_mutex_unlock(&r->lock); return 1;
    }
    pthread_mutex_unlock(&r->lock); return 0;
}
static inline void vx_eye_ring_drain(vx_eye_ring *r) {
    if (!r) return;
    pthread_mutex_lock(&r->lock); while (r->inflight) pthread_cond_wait(&r->cv, &r->lock); pthread_mutex_unlock(&r->lock);
}
/* Block until fewer than `limit` pairs are in flight (submitted by the game, its GPU work and the copy not yet complete), at most `timeout_ms`.
 * Returns the milliseconds waited (0 when nothing had to be). Used to start the game's next frame only when its pose will be fresh when
 * the GPU gets to it: with a GPU-bound game and two frames queued, a pose was about two frame times old by the time it was drawn. */
static inline double vx_eye_ring_wait_below(vx_eye_ring *r, unsigned limit, unsigned timeout_ms) {
    if (!r || !limit) return 0;
    struct timespec t0, until; clock_gettime(CLOCK_REALTIME, &t0); until = t0;
    until.tv_sec += timeout_ms / 1000; until.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) { ++until.tv_sec; until.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&r->lock);
    while (r->inflight >= limit) if (pthread_cond_timedwait(&r->cv, &r->lock, &until)) break;
    pthread_mutex_unlock(&r->lock);
    struct timespec t1; clock_gettime(CLOCK_REALTIME, &t1);
    return (double)(t1.tv_sec - t0.tv_sec) * 1e3 + (double)(t1.tv_nsec - t0.tv_nsec) / 1e6;
}
static inline unsigned vx_eye_ring_inflight(vx_eye_ring *r) {
    if (!r) return 0;
    pthread_mutex_lock(&r->lock); unsigned n = r->inflight; pthread_mutex_unlock(&r->lock); return n;
}
static inline void vx_eye_ring_destroy(vx_eye_ring *r) {
    if (!r) return;
    vx_eye_ring_drain(r);
    if (r->log) { char m[192]; snprintf(m, sizeof m, "xr submit ring: submitted %llu completed %llu failed %llu blocked-at-bound %llu max-in-flight %llu texture-allocs %llu",
           (unsigned long long)r->submitted, (unsigned long long)r->completed, (unsigned long long)r->failed,
           (unsigned long long)r->blocked, (unsigned long long)r->max_seen, (unsigned long long)r->allocs); r->log(m); }
    for (unsigned i = 0; i < r->nslots; i++) { vx_eye_ring_free_slot(r->slots[i]); free(r->slots[i]); }
    CFRelease(r->device); pthread_cond_destroy(&r->cv); pthread_mutex_destroy(&r->lock); free(r);
}
#endif
