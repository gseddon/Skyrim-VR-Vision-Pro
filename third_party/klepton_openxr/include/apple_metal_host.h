/* Local native Apple resource adapter, MIT; see LICENSE. */
#ifndef KL_APPLE_METAL_HOST_H
#define KL_APPLE_METAL_HOST_H
#include "metal_host.h"
#include "image_sync_host.h"

/* Native MTLDevice / MTLCommandQueue objects, borrowed on entry and retained
 * on success. Destroy provider objects before destroying this adapter. */
XrResult kl_apple_metal_host_create(void *device, void *queue, KlNativeMetalHost *out);
/* Refuses while provider image leases remain. Reader resources must already
 * have their own references; this adapter does not track compositor readers. */
XrResult kl_apple_metal_host_destroy(KlNativeMetalHost *host);
/* Initial producer adapter: records an already committed command buffer from
 * this host's queue. A future D3D copy bridge must separately order its source
 * producer before this copy; unrelated-queue completion is not inferred. */
XrResult kl_apple_metal_record_texture_writes(KlNativeMetalHost *host, void *texture, void *command_buffer);
/* Only for a publisher that copies into independent display resources before
 * returning, so compositor readers never access these provider images. */
XrResult kl_apple_metal_image_sync(KlNativeMetalHost *host, KlNativeImageSyncHost *out);
#endif
