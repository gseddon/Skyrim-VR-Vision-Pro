// Registry-validated D3D11 resources to xrizer's native Metal host boundary.
#include "d3d_common.h"
#include "d3d11_capture.h"
#include "xrizer_guest_d3d.h"
#include "vx.h"
#include <stdlib.h>

typedef struct lease { d3d_texture *texture; void *metal; struct lease *next; } lease;
typedef struct {
    void *device, *queue;
    vx_xrizer_record_destination_fn record;
    void *record_context;
    uint64_t acquired, released, copied;
    lease *active;
    unsigned inflight;
    int invalid_release;
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
    if (b->active || b->inflight || b->invalid_release || b->acquired!=b->released) return -1;
    CFRelease(b->queue); CFRelease(b->device); free(b); *host=(XrizerMetalHost){0}; return 0;
}
