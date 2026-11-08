/* Static xrizer / Klepton host boundary for the existing Apple compositor. */
#ifndef VX_XRIZER_XROS_HOST_H
#define VX_XRIZER_XROS_HOST_H
#include <stdint.h>
#include "native_vr.h"
#include "klepton_native.h"
#include "view_host.h"
#include "session_host.h"
#include "frame_host.h"
#include "input_host.h"
#include "metal_host_bridge.h"
#ifdef __cplusplus
extern "C" {
#endif
#define VX_XROS_XRIZER_API_VERSION 1u
typedef struct vx_xros_xrizer_host vx_xros_xrizer_host;
typedef void *(*vx_xros_xrizer_factory)(void *context, int *error);
typedef struct vx_xros_xrizer_static_api {
    uint32_t version, size;
    int32_t (*configure_provider)(PFN_xrGetInstanceProcAddr);
    int32_t (*configure_metal)(const XrizerMetalHost *);
    void *(*client_core_factory)(const char *, int *);
    int (*install_factory)(vx_xros_xrizer_factory, void *);
} vx_xros_xrizer_static_api;
typedef enum vx_xros_xrizer_mode { VX_XROS_XRIZER_PLATFORM = 1, VX_XROS_XRIZER_INJECTED_TEST = 2 } vx_xros_xrizer_mode;
/* Platform callbacks acknowledge real lifecycle/drain and observed input.
 * The injected mode is explicitly selected only by owned fixtures. These are
 * native-ABI callbacks, serialized and forbidden to synchronously reenter the
 * provider. All callback contexts, device and queue remain live process-wide. */
typedef struct vx_xros_xrizer_platform {
    uint32_t version, size;
    void *context;
    XrResult (*begin)(void *, XrTime *);
    XrResult (*end)(void *, XrTime *);
    XrResult (*request_exit)(void *);
    XrResult (*sample_input)(void *, KlNativeInputSample *);
} vx_xros_xrizer_platform;
/* Explicitly invoked opt-in; no default host is configured. The queue must
 * belong to the device. At most one host can be registered per process. */
vx_xros_xrizer_host *vx_xros_xrizer_create(vx_xros_xrizer_mode, void *device, void *queue,
                                           const vx_xros_xrizer_platform *);
/* Passed to A's source bridge to record a completed destination copy. */
int vx_xros_xrizer_record_destination(void *context, void *texture, void *command_buffer);
/* Call after caller creates the D3D source host. Static APIs and callback
 * contexts are pinned for process lifetime even if a partial registration
 * fails; no retry or unregister is promised. */
int vx_xros_xrizer_register(vx_xros_xrizer_host *, const vx_xros_xrizer_static_api *, const XrizerMetalHost *source);
/* Producer calls are explicit: real surface readiness, calibrated views,
 * lifecycle events and host samples come from the existing compositor. */
int vx_xros_xrizer_surface(vx_xros_xrizer_host *, int ready, const KlNativeViewConfiguration *views);
int vx_xros_xrizer_event(vx_xros_xrizer_host *, KlNativeSessionEvent event);
int vx_xros_xrizer_offer(vx_xros_xrizer_host *, const KlNativeFrameSample *sample);
/* Presenter acquires/relinquishes its own reader lease; exactly one release per
 * success, after display GPU completion. Repeats retain the original IDs. */
int vx_xros_xrizer_acquire(vx_xros_xrizer_host *, vx_native_vr_frame *out);
int vx_xros_xrizer_release(vx_xros_xrizer_host *, uint64_t lease);
/* Caller must first destroy provider session/instance and exclude concurrent
 * provider callbacks and producer submissions. Refuse while a ticket, copy or
 * reader lease remains. Retires; never frees process-lifetime callback context
 * or permits re-registration. */
int vx_xros_xrizer_retire(vx_xros_xrizer_host *);
#ifdef __cplusplus
}
#endif
#endif
