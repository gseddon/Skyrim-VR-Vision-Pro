// Registry-validated D3D11 resources to xrizer's native Metal host boundary.
#include "d3d_common.h"
#include "d3d11_capture.h"
#include "xrizer_guest_d3d.h"
#include "xrizer_eye_ring.h"   /* vx_eye_ring_sync_requested() */
#include "vx.h"
#include <stdlib.h>

typedef struct lease { d3d_texture *texture; void *metal; struct lease *next; } lease;
typedef struct {
    void *device, *queue;
    vx_xrizer_record_destination_fn record;
    void *record_context;
    uint64_t acquired, released, copied;
    lease *active;
    unsigned inflight;            /* atomic: the non-blocking copies not yet completed */
    int invalid_release;
    /* Non-blocking mode (default; VXRT_XR_SYNC_SUBMIT=1 keeps the CPU waits): the copy waits on the GPU for the game's
     * work (event), and the game's own next command buffers wait for the copy (d3d_xr_guard_*). */
    int async;
    void *event;                  /* id<MTLSharedEvent>, one counter for both directions */
    uint64_t event_value;         /* last value handed out (copy thread only) */
    d3d_device *last_dev; uint64_t last_target, last_signal;   /* the last producer signal, reused while nothing new was sent */
} bridge;
static unsigned acquire_notes;
static void note_acquire(const char *why, void *handle, d3d_texture *t, id<MTLTexture> src, int device_ok) {
    if (acquire_notes >= 4) return;
    acquire_notes++;
    if (!t) { vx_log("xrizer_guest_d3d: acquire %s handle %p", why, handle); return; }
    vx_log("xrizer_guest_d3d: acquire %s handle %p dim %u %ux%u array %u samples %u dxgi %u metal %ld type %lu shared %d external %d device_ok %d",
           why, handle, t->dim, t->desc[TD_WIDTH], t->desc[TD_HEIGHT], t->desc[TD_ARRAY], t->desc[TD_SAMPLES], t->desc[TD_FORMAT],
           src ? (long)src.pixelFormat : -1L, src ? (unsigned long)src.textureType : 0UL, t->shared, t->external_origin, device_ok);
}
static int32_t acquire(void *ctx, void *handle, XrizerMetalTexture *out) {
    bridge *b = ctx; if (!b || !out) return -1;
    *out = (XrizerMetalTexture){0};
    d3d_texture *t = d3d_texture_acquire(VX_LOW(handle));
    if (!t) { note_acquire("miss", handle, NULL, nil, 0); return -1; }
    id<MTLTexture> src = (__bridge id<MTLTexture>)t->mtl;
    int device_ok = t->base.dev && t->base.dev->mtl == b->device && src && src.device == (__bridge id<MTLDevice>)b->device;
    if (!src || !t->base.dev || t->base.dev->mtl != b->device || src.device != (__bridge id<MTLDevice>)b->device ||
        t->shared || t->external_origin || t->dim != 2 || t->desc[TD_ARRAY] != 1 || t->desc[TD_SAMPLES] != 1 || src.textureType != MTLTextureType2D ||
        src.pixelFormat != MTLPixelFormatRGBA8Unorm) {
        note_acquire("rejected", handle, t, src, device_ok);
        d3d_release(&t->base); return -1;
    }
    note_acquire("accepted", handle, t, src, device_ok);
    if (b->acquired == UINT64_MAX) { d3d_release(&t->base); return -1; }
    lease *held=malloc(sizeof(*held)); if (!held) { d3d_release(&t->base); return -1; }
    held->texture=t; held->metal=(void *)CFRetain(t->mtl); held->next=b->active; b->active=held; ++b->acquired;
    *out = (XrizerMetalTexture){.texture=held->metal,.device=b->device,.lease=held,.format=(int64_t)src.pixelFormat,
                                .width=(uint32_t)src.width,.height=(uint32_t)src.height,.sample_count=1};
    return 0;
}
static void release_source(void *ctx, void *token) {
    bridge *b=ctx; if (!b) return;
    lease **link=&b->active; while (*link && *link!=token) link=&(*link)->next;
    if (!*link || b->released==UINT64_MAX) { b->invalid_release=1; return; }
    lease *held=*link; *link=held->next; ++b->released;
    CFRelease(held->metal); d3d_release(&held->texture->base); free(held);
}
/* The non-blocking copy of one eye: game texture -> provider swapchain image, ordered on the GPU.
 *  1. send the game's recorded work and signal event=v1 behind it (d3d_flush_signal; no CPU poll);
 *  2. the copy waits for v1, copies, signals v2, and is committed on the provider queue; the provider records it as the
 *     image's write buffer (Klepton checks it before the image is read again and before any publish);
 *  3. from now on every command buffer the game's device opens first waits for v2, so the next frame cannot overwrite the
 *     texture the copy is still reading;
 *  4. the game's producer status (a failed D3D11 command buffer) is attached to the write buffer; the publisher checks it. */
@interface VXXRProducers : NSObject <VXXRWriteCheck>
- (instancetype)initWithDevice:(d3d_device *)d target:(uint64_t)t;
@end
@implementation VXXRProducers { d3d_device *_dev; uint64_t _target; }
- (instancetype)initWithDevice:(d3d_device *)d target:(uint64_t)t { if ((self = [super init])) { _dev = d; _target = t; d3d_addref(&d->base); } return self; }
- (BOOL)vxProducersOK { return d3d_producers_ok(_dev, _target) == 0; }
- (void)dealloc { d3d_release(&_dev->base); }
@end
static int32_t copy_async(bridge *b, d3d_texture *t, id<MTLTexture> src, id<MTLTexture> dst, const XrizerMetalCopy *copy) {
    d3d_device *dev = t->base.dev;
    if (!b->event) {
        id<MTLSharedEvent> ev = [(__bridge id<MTLDevice>)b->device newSharedEvent]; if (!ev) return -1;
        b->event = (void *)CFBridgingRetain(ev);
    }
    uint64_t target = 0, v1;
    if (b->last_dev == dev && b->last_signal && __atomic_load_n(&dev->producer_submitted, __ATOMIC_ACQUIRE) == b->last_target &&
        !((d3d_context *)dev->context)->cmd) { v1 = b->last_signal; target = b->last_target; }   /* nothing new since the last signal */
    else {
        v1 = ++b->event_value;
        if (d3d_flush_signal(dev, b->event, v1, &target)) return -1;
        b->last_dev = dev; b->last_target = target; b->last_signal = v1;
    }
    uint64_t v2 = ++b->event_value;
    id<MTLCommandBuffer> cb = [(__bridge id<MTLCommandQueue>)b->queue commandBuffer];
    if (!cb) return -1;
    [cb encodeWaitForEvent:(__bridge id<MTLEvent>)b->event value:v1];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder]; if (!blit) return -1;
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(copy->x,copy->y,0)
               sourceSize:MTLSizeMake(copy->width,copy->height,1) toTexture:dst destinationSlice:copy->eye
         destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    [cb encodeSignalEvent:(__bridge id<MTLEvent>)b->event value:v2];
    __atomic_add_fetch(&b->inflight, 1, __ATOMIC_ACQ_REL);
    d3d_addref(&dev->base);
    unsigned eye = copy->eye;
    /* A failed game producer must keep this image from being published even though the copy itself ran: the check is
     * attached to the write buffer and run by the publisher when its own copy completes (vx_eye_ring_writes_ok). */
    objc_setAssociatedObject(cb, @selector(vxProducersOK), [[VXXRProducers alloc] initWithDevice:dev target:target], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status == MTLCommandBufferStatusCompleted && !done.error) __atomic_add_fetch(&b->copied, 1, __ATOMIC_ACQ_REL);
        else vx_log("xrizer_guest_d3d: destination copy eye %u failed (status %ld)", eye, (long)done.status);
        d3d_xr_guard_clear(dev, v2);
        d3d_release(&dev->base);
        __atomic_sub_fetch(&b->inflight, 1, __ATOMIC_ACQ_REL);
    }];
    [cb commit];
    d3d_xr_guard_set(dev, b->event, v2);
    int recorded = b->record(b->record_context, copy->destination, (__bridge void *)cb);
    return recorded ? -1 : 0;
}
static int32_t copy_complete(void *ctx, const XrizerMetalCopy *copy) {
    bridge *b=ctx;
    if (!b || !copy || !copy->source || !copy->source->lease || copy->eye>1 || copy->color_space>2) return -1;
    lease *held=b->active; while (held && held!=copy->source->lease) held=held->next;
    if (!held || b->copied==UINT64_MAX) return -1;
    d3d_texture *t=held->texture;
    id<MTLTexture> src=(__bridge id<MTLTexture>)copy->source->texture, dst=(__bridge id<MTLTexture>)copy->destination;
    if (!src || !dst || held->metal != copy->source->texture || t->mtl != held->metal || t->shared || t->external_origin || t->base.dev->mtl != b->device ||
        dst.device != (__bridge id<MTLDevice>)b->device || dst.textureType != MTLTextureType2DArray || dst.arrayLength<2 ||
        dst.pixelFormat != src.pixelFormat || dst.sampleCount != 1 || !copy->width || !copy->height ||
        copy->x > src.width || copy->width > src.width-copy->x || copy->y > src.height || copy->height > src.height-copy->y ||
        copy->width > dst.width || copy->height > dst.height) return -1;
    // This checked wait orders every tracked source producer before the copy,
    // including when the producer and provider queues are different.
    if (d3d11_capture_on) d3d11_capture_eye(&t->base, copy->eye, copy->x, copy->y, copy->width, copy->height);   // VXRT_D3D11_CAPTURE
    if (b->async) return copy_async(b, t, src, dst, copy);
    if (d3d_flush_checked(t->base.dev)) return -1;
    vx_log("xrizer_guest_d3d: producer queue %p provider queue %p checked complete", t->base.dev->queue, b->queue);
    id<MTLCommandBuffer> cb=[(__bridge id<MTLCommandQueue>)b->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; if (!cb || !blit) return -1;
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(copy->x,copy->y,0)
               sourceSize:MTLSizeMake(copy->width,copy->height,1) toTexture:dst destinationSlice:copy->eye
         destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding]; ++b->inflight; [cb commit];
    int recorded=b->record(b->record_context, copy->destination, (__bridge void *)cb);
    [cb waitUntilCompleted]; --b->inflight;
    if (recorded || cb.status != MTLCommandBufferStatusCompleted || cb.error) return -1;
    ++b->copied;
    vx_log("xrizer_guest_d3d: destination copy eye %u GPU complete", copy->eye);
    return 0;
}
int vx_xrizer_guest_d3d_create(void *device, void *queue, vx_xrizer_record_destination_fn record, void *context, XrizerMetalHost *out) {
    if (!device || !queue || !record || !out) return -1;
    id<MTLDevice> d=(__bridge id<MTLDevice>)device; id<MTLCommandQueue> q=(__bridge id<MTLCommandQueue>)queue;
    if (q.device!=d) return -1;
    bridge *b=calloc(1,sizeof(*b)); if (!b) return -1;
    b->device=(void *)CFRetain(device); b->queue=(void *)CFRetain(queue); b->record=record; b->record_context=context;
    b->async=!vx_eye_ring_sync_requested();
    *out=(XrizerMetalHost){.abi_version=XRIZER_METAL_HOST_ABI_VERSION,.struct_size=sizeof(*out),.context=b,
        .device=device,.command_queue=queue,.acquire=acquire,.copy_complete=copy_complete,.release=release_source};
    return 0;
}
int vx_xrizer_guest_d3d_counts(const XrizerMetalHost *host, uint64_t *acquired, uint64_t *released, uint64_t *copied) {
    if (!host || !host->context || !acquired || !released || !copied) return -1;
    bridge *b=host->context; *acquired=b->acquired; *released=b->released; *copied=b->copied; return 0;
}
int vx_xrizer_guest_d3d_destroy(XrizerMetalHost *host) {
    if (!host || !host->context) return -1; bridge *b=host->context;
    for (unsigned spin=0; __atomic_load_n(&b->inflight,__ATOMIC_ACQUIRE) && spin<5000; spin++) usleep(1000);   // non-blocking copies finish
    if (b->active || b->inflight || b->invalid_release || b->acquired!=b->released) return -1;
    CFRelease(b->queue); CFRelease(b->device); free(b); *host=(XrizerMetalHost){0}; return 0;
}
