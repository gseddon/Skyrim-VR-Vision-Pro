/* xrizer Darwin port host boundary; GPL-3.0-or-later, like xrizer.
 * Used by the explicit owned-test Apple compositor route. */
#ifndef XRIZER_METAL_HOST_BRIDGE_H
#define XRIZER_METAL_HOST_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

#define XRIZER_METAL_HOST_ABI_VERSION 1u
/* Pointers are native host pointers. A guest handle is an opaque token and must
 * never be dereferenced by xrizer. On successful acquire the host transfers one
 * lease to xrizer; release is called exactly once, including validation/copy
 * failure. On failure, acquire transfers no lease. */
typedef struct XrizerMetalTexture {
    void *texture; /* borrowed MTLTexture, valid while lease is held */
    void *device;  /* borrowed MTLDevice identity */
    void *lease;   /* non-null host-owned resource retention token */
    int64_t format; /* MTLPixelFormat */
    uint32_t width, height, sample_count;
} XrizerMetalTexture;

/* Request and source pointers are borrowed only for copy_complete. The host
 * keeps the table, context, device and queue valid and unchanged while used;
 * callers serialize access unless the callbacks explicitly support concurrency. */
typedef struct XrizerMetalCopy {
    const XrizerMetalTexture *source;
    void *destination; /* provider-owned MTLTexture */
    uint32_t eye, x, y, width, height;
    uint32_t color_space; /* OpenVR: 0 auto, 1 gamma, 2 linear */
} XrizerMetalCopy;

typedef struct XrizerMetalHost {
    uint32_t abi_version, struct_size;
    void *context;
    void *device; /* required MTLDevice identity */
    void *command_queue; /* required MTLCommandQueue */
    int32_t (*acquire)(void *context, void *guest_handle, XrizerMetalTexture *out);
    /* Returns 0 only after producer writes are ordered before the copy, the
     * copy is GPU-complete and the source is no longer in use. A failure must
     * likewise leave no untracked GPU work using the borrowed source or
     * destination: drain it, or retain independent references and register
     * its completion with the image-sync host before returning. Must reject
     * unsupported formats, color conversions, destination devices/layers,
     * and copy failures. No async-success return. */
    int32_t (*copy_complete)(void *context, const XrizerMetalCopy *copy);
    void (*release)(void *context, void *lease);
} XrizerMetalHost;
/* Configure once, before xrizer initialization. Copies this table; context,
 * device, queue and callback code stay valid for process lifetime. xrizer
 * serializes callbacks; callbacks must not synchronously re-enter xrizer.
 * Returns 0 on success, -1 for invalid or already configured table. */
int32_t xrizer_configure_metal_host(const XrizerMetalHost *host);
#endif
