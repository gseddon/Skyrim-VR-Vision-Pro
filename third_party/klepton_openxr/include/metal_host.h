/* Klepton-derived provider native Metal resource boundary, MIT; see LICENSE. */
#ifndef KL_NATIVE_METAL_HOST_H
#define KL_NATIVE_METAL_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>

#define KL_NATIVE_METAL_HOST_VERSION 1u
/* All pointers are native host ABI, never guest-callable pointers. Host owns
 * device and queue and keeps them alive, unchanged, until all sessions and
 * swapchains are destroyed. They must match xrizer's XrizerMetalHost device
 * and queue. Callbacks are serialized by the provider unless documented
 * otherwise; they must not call into the provider synchronously. */
typedef struct KlNativeMetalImageInfo {
    int64_t format; /* MTLPixelFormat, not VkFormat or DXGI_FORMAT */
    uint32_t width, height, array_size, sample_count, mip_count;
    XrSwapchainUsageFlags usage;
} KlNativeMetalImageInfo;

typedef struct KlNativeMetalHost {
    uint32_t version, struct_size;
    void *context;
    /* Both results borrowed, non-null. Return success only when queue.device
     * is device and both are usable for the provider's lifetime. */
    XrResult (*get_graphics)(void *context, void **device, void **command_queue);
    /* Standard capacity/count pattern. Count is actual supported formats;
     * insufficient capacity returns XR_ERROR_SIZE_INSUFFICIENT. */
    XrResult (*enumerate_formats)(void *context, uint32_t capacity,
                                  uint32_t *count, int64_t *formats);
    /* On success, return native MTLTexture and an independently retained,
     * non-null host lease. On failure, transfer no lease. Only configurations
     * actually supported by this device and usage may succeed. */
    XrResult (*create_image)(void *context, const KlNativeMetalImageInfo *info,
                             void **texture, void **lease);
    /* Called exactly once per successful create_image, after the provider no
     * longer uses this lease. The host releases its reference. Any compositor
     * reader must have taken its own strong texture reference before publish;
     * its lifetime drains independently of this provider lease. */
    void (*release_image)(void *context, void *lease);
} KlNativeMetalHost;

/* Install a copied callback table before creating an instance; pass NULL to
 * disable Metal. The callback context and returned objects remain host-owned. */
XrResult kl_native_configure_metal(const KlNativeMetalHost *host);

/* Frame publication and completion deliberately not yet defined: waiting on
 * this queue alone cannot prove prior writes on a different D3D producer queue
 * completed. The producer-to-copy bridge must establish explicit cross-queue
 * ordering or prove a shared queue before any frame is published. Cancellation
 * must drain GPU/reader ownership and never publish an incomplete frame. */
#endif
