/* Owned joined-AOT fixture support; native host ABI, never a guest ABI table. */
#ifndef VX_XRIZER_GUEST_HOST_H
#define VX_XRIZER_GUEST_HOST_H
#include <stdint.h>
#include "metal_host_bridge.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct vx_xrizer_guest_host vx_xrizer_guest_host;
typedef struct vx_xrizer_guest_host_stats {
    uint32_t waits, publishes, cancels, begins, exits, ends;
    uint32_t sessions_created, sessions_destroyed, source_acquires, source_releases, source_copies;
    uint64_t frame_id, pose_id;
    int64_t predicted_display_time;
    uint32_t outstanding;
} vx_xrizer_guest_host_stats;
/* Configure real provider and xrizer, but do not initialize ClientCore. A NULL
 * source table selects owned native MTL tokens; it does not prove D3D11 handles.
 * External callbacks must use the supplied real device/queue and record every
 * committed destination write through record_writes before returning success.
 * Process-isolated singleton; context/table/library intentionally live to exit. */
int vx_xrizer_guest_host_create(const char *library, const XrizerMetalHost *sources, vx_xrizer_guest_host **out);
void *vx_xrizer_guest_host_factory(vx_xrizer_guest_host *, const char *version, int *error);
void vx_xrizer_guest_host_get_stats(vx_xrizer_guest_host *, vx_xrizer_guest_host_stats *);
/* Call after WaitGetPoses(0) has latched a sample. These encode actual GPU work. */
int vx_xrizer_guest_host_prepare_native(vx_xrizer_guest_host *, uint32_t variant);
void *vx_xrizer_guest_host_native_token(vx_xrizer_guest_host *, uint32_t eye);
/* Performs real GPU readback and exact frame/pose/FOV/pixel assertions; releases
 * its queue reader. Requires the fixture's 4x3 crop from (2,1) in 8x8 RGBA8. */
int vx_xrizer_guest_host_check_pair(vx_xrizer_guest_host *, uint32_t variant);
/* For external producer callbacks: committed same-queue Metal command buffer. */
int vx_xrizer_guest_host_record_writes(vx_xrizer_guest_host *, void *texture, void *command_buffer);
/* Guest must call actual Cleanup first, with no pending frame/image/readers.
 * Verifies drained lifecycle, unregisters host tables, destroys Metal host. */
int vx_xrizer_guest_host_finish(vx_xrizer_guest_host *);
#ifdef __cplusplus
}
#endif
#endif
