/* Native image synchronization boundary; MIT, see ../LICENSE. */
#ifndef KL_NATIVE_IMAGE_SYNC_HOST_H
#define KL_NATIVE_IMAGE_SYNC_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
#define KL_NATIVE_IMAGE_SYNC_HOST_VERSION 1u
/* Image lease is the live provider-owned host lease from create_image, never
 * a released/stale token. Callbacks are serialized and cannot reenter the
 * provider. They must not publish, retain, or release the provider's lease. */
typedef struct KlNativeImageSyncHost {
    uint32_t version, struct_size;
    void *context;
    /* Return XR_SUCCESS only when prior GPU users and all compositor readers
     * of this image have relinquished it. XR_TIMEOUT_EXPIRED leaves acquisition
     * intact; negative errors leave state unchanged. */
    XrResult (*wait_available)(void *context, void *image_lease, XrDuration timeout);
    /* Return XR_SUCCESS only after every write into the image has completed,
     * including source-producer to copy dependencies. A session queue wait is
     * not sufficient for a different producer queue: use explicit completion
     * tokens/events or prove a shared queue. Error leaves state unchanged. */
    XrResult (*complete_writes)(void *context, void *image_lease);
} KlNativeImageSyncHost;
XrResult kl_native_configure_image_sync(const KlNativeImageSyncHost *host);
#endif
