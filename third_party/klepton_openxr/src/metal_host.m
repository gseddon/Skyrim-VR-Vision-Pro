/* Local Apple adapter for the Klepton-derived provider. MIT; see LICENSE. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "apple_metal_host.h"
#include <time.h>

@interface KLAppleMetalImage : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) id<MTLCommandBuffer> writes;
@end
@implementation KLAppleMetalImage
@end

@interface KLAppleMetalResources : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, KLAppleMetalImage *> *images;
@property(nonatomic) uint64_t nextLease;
@property(nonatomic, strong) NSArray<NSNumber *> *formats;
@end
@implementation KLAppleMetalResources
@end

static KLAppleMetalResources *resources(void *context) {
    return (__bridge KLAppleMetalResources *)context;
}

static XrResult graphics(void *context, void **device, void **queue) {
    if (!context || !device || !queue) return XR_ERROR_VALIDATION_FAILURE;
    KLAppleMetalResources *r = resources(context);
    if (!r.device || !r.queue || r.queue.device != r.device) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    *device = (__bridge void *)r.device;
    *queue = (__bridge void *)r.queue;
    return XR_SUCCESS;
}

static XrResult formats(void *context, uint32_t capacity, uint32_t *count, int64_t *out) {
    if (!context || !count) return XR_ERROR_VALIDATION_FAILURE;
    KLAppleMetalResources *r = resources(context);
    *count = (uint32_t)r.formats.count;
    if (!capacity) return XR_SUCCESS;
    if (capacity < *count) return XR_ERROR_SIZE_INSUFFICIENT;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    for (uint32_t i = 0; i < *count; ++i) out[i] = r.formats[i].longLongValue;
    return XR_SUCCESS;
}

static XrResult image(void *context, const KlNativeMetalImageInfo *info, void **texture, void **lease) {
    if (!context || !info || !texture || !lease) return XR_ERROR_VALIDATION_FAILURE;
    *texture = *lease = NULL;
    KLAppleMetalResources *r = resources(context);
    if (![r.formats containsObject:@(info->format)]) return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    const XrSwapchainUsageFlags allowed = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
        XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
    if (!info->usage || (info->usage & ~allowed) || info->sample_count != 1 || info->mip_count != 1 ||
        !info->array_size || info->array_size > 2) return XR_ERROR_FEATURE_UNSUPPORTED;
    /* This initial adapter supports a conservative 4K per-eye ceiling. Avoid
     * passing invalid/huge dimensions to Metal's process-aborting validation. */
    if (!info->width || !info->height || info->width > 4096 || info->height > 4096)
        return XR_ERROR_VALIDATION_FAILURE;
    if (!r.nextLease) return XR_ERROR_LIMIT_REACHED;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
    desc.textureType = info->array_size == 1 ? MTLTextureType2D : MTLTextureType2DArray;
    desc.pixelFormat = (MTLPixelFormat)info->format;
    desc.width = info->width;
    desc.height = info->height;
    desc.arrayLength = info->array_size;
    desc.mipmapLevelCount = 1;
    desc.sampleCount = 1;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageUnknown;
    if (info->usage & XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT) desc.usage |= MTLTextureUsageRenderTarget;
    if (info->usage & XR_SWAPCHAIN_USAGE_SAMPLED_BIT) desc.usage |= MTLTextureUsageShaderRead;
    id<MTLTexture> value = [r.device newTextureWithDescriptor:desc];
    if (!value) return XR_ERROR_OUT_OF_MEMORY;
    uint64_t token = r.nextLease++;
    KLAppleMetalImage *record = [KLAppleMetalImage new];
    record.texture = value;
    r.images[@(token)] = record;
    *texture = (__bridge void *)value;
    *lease = (void *)(uintptr_t)token;
    return XR_SUCCESS;
}

static void release_image(void *context, void *lease) {
    if (context && lease) [resources(context).images removeObjectForKey:@((uintptr_t)lease)];
}

XrResult kl_apple_metal_record_texture_writes(KlNativeMetalHost *host, void *texture, void *command_buffer) {
    if (!host || !host->context || !texture || !command_buffer) return XR_ERROR_VALIDATION_FAILURE;
    KLAppleMetalResources *r = resources(host->context);
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)command_buffer;
    if (cb.commandQueue != r.queue) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    if (cb.status < MTLCommandBufferStatusCommitted || cb.status == MTLCommandBufferStatusError)
        return XR_ERROR_RUNTIME_FAILURE;
    for (KLAppleMetalImage *entry in r.images.allValues) if ((__bridge void *)entry.texture == texture) {
        if (entry.writes && entry.writes.status != MTLCommandBufferStatusCompleted)
            return XR_ERROR_CALL_ORDER_INVALID;
        entry.writes = cb;
        return XR_SUCCESS;
    }
    return XR_ERROR_HANDLE_INVALID;
}

static XrResult wait_available(void *context, void *lease, XrDuration timeout) {
    if (!context || !lease || timeout < 0) return XR_ERROR_VALIDATION_FAILURE;
    KLAppleMetalImage *entry = resources(context).images[@((uintptr_t)lease)];
    if (!entry) return XR_ERROR_HANDLE_INVALID;
    struct timespec start;
    if (clock_gettime(CLOCK_MONOTONIC, &start)) return XR_ERROR_RUNTIME_FAILURE;
    while (entry.writes && entry.writes.status != MTLCommandBufferStatusCompleted) {
        if (entry.writes.status == MTLCommandBufferStatusError) return XR_ERROR_RUNTIME_FAILURE;
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now)) return XR_ERROR_RUNTIME_FAILURE;
        int64_t elapsed = (now.tv_sec - start.tv_sec) * INT64_C(1000000000) + now.tv_nsec - start.tv_nsec;
        if (elapsed >= timeout) return XR_TIMEOUT_EXPIRED;
        struct timespec delay = { .tv_nsec = 1000000 };
        nanosleep(&delay, NULL);
    }
    /* Display readers must use independent copies; provider images are not
     * handed directly to the compositor by this initial synchronous adapter. */
    entry.writes = nil; /* A completed prior acquisition cannot attest this one's writes. */
    return XR_SUCCESS;
}

static XrResult complete_writes(void *context, void *lease) {
    if (!context || !lease) return XR_ERROR_VALIDATION_FAILURE;
    KLAppleMetalImage *entry = resources(context).images[@((uintptr_t)lease)];
    if (!entry) return XR_ERROR_HANDLE_INVALID;
    if (!entry.writes) return XR_ERROR_CALL_ORDER_INVALID;
    [entry.writes waitUntilCompleted];
    return entry.writes.status == MTLCommandBufferStatusCompleted && !entry.writes.error ? XR_SUCCESS : XR_ERROR_RUNTIME_FAILURE;
}

XrResult kl_apple_metal_image_sync(KlNativeMetalHost *host, KlNativeImageSyncHost *out) {
    if (!host || !host->context || !out) return XR_ERROR_VALIDATION_FAILURE;
    *out = (KlNativeImageSyncHost){ .version = KL_NATIVE_IMAGE_SYNC_HOST_VERSION,
        .struct_size = sizeof(*out), .context = host->context, .wait_available = wait_available,
        .complete_writes = complete_writes };
    return XR_SUCCESS;
}

XrResult kl_apple_metal_host_create(void *device, void *queue, KlNativeMetalHost *out) {
    if (!device || !queue || !out) return XR_ERROR_VALIDATION_FAILURE;
    *out = (KlNativeMetalHost){0};
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    if (q.device != d || ![d supportsTextureSampleCount:1]) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    KLAppleMetalResources *r = [KLAppleMetalResources new];
    r.device = d;
    r.queue = q;
    r.images = [NSMutableDictionary new];
    r.nextLease = 1;
    NSMutableArray<NSNumber *> *supported = [NSMutableArray new];
    const MTLPixelFormat candidates[] = { MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB,
        MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB };
    for (unsigned i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:candidates[i]
            width:1 height:1 mipmapped:NO];
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        if ([d newTextureWithDescriptor:desc]) [supported addObject:@(candidates[i])];
    }
    if (!supported.count) return XR_ERROR_FEATURE_UNSUPPORTED;
    r.formats = supported;
    *out = (KlNativeMetalHost){ .version = KL_NATIVE_METAL_HOST_VERSION, .struct_size = sizeof(*out),
        .context = (__bridge_retained void *)r, .get_graphics = graphics, .enumerate_formats = formats,
        .create_image = image, .release_image = release_image };
    return XR_SUCCESS;
}

XrResult kl_apple_metal_host_destroy(KlNativeMetalHost *host) {
    if (!host || host->version != KL_NATIVE_METAL_HOST_VERSION || host->struct_size < sizeof(*host) || !host->context)
        return XR_ERROR_VALIDATION_FAILURE;
    if (resources(host->context).images.count) return XR_ERROR_CALL_ORDER_INVALID;
    (void)CFBridgingRelease(host->context);
    *host = (KlNativeMetalHost){0};
    return XR_SUCCESS;
}
