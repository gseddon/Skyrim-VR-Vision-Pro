#ifndef VX_XRIZER_GUEST_D3D_H
#define VX_XRIZER_GUEST_D3D_H
#include "metal_host_bridge.h"
/* Provider device and queue predate the guest D3D device. The caller keeps the
 * returned table/context until xrizer is cleaned up and all callbacks drain.
 * record_destination registers the committed copy with provider image sync.
 * D3D resource mutation (including replacement), immediate-context recording, callbacks and destruction must be serialized by the caller. */
typedef int (*vx_xrizer_record_destination_fn)(void *context, void *texture, void *command_buffer);
int vx_xrizer_guest_d3d_create(void *device, void *queue, vx_xrizer_record_destination_fn record_destination,
                               void *record_context, XrizerMetalHost *out);
int vx_xrizer_guest_d3d_counts(const XrizerMetalHost *host, uint64_t *acquired, uint64_t *released, uint64_t *copied);
/* Returns -1 while leases/callbacks are outstanding or a lifetime violation was seen. */
int vx_xrizer_guest_d3d_destroy(XrizerMetalHost *host);
#endif
