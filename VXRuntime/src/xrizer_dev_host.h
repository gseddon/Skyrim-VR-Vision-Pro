#ifndef VX_XRIZER_DEV_HOST_H
#define VX_XRIZER_DEV_HOST_H
/* Explicit Mac offscreen development host. It injects a stationary synthetic
 * head and disconnected controllers, not physical tracking or presentation.
 * Call before guest startup; the path must identify the actual xrizer dylib.
 * Configured contexts stay alive through process exit. */
int vx_xrizer_dev_host_start(const char *xrizer_library, unsigned width, unsigned height);
#ifdef VXRT_XRIZER_DEV_AUDIT
#include "native_vr.h"
/* Owned fixture only; the normal development host consumes offscreen pairs. */
int vx_xrizer_dev_audit_acquire(vx_native_vr_frame *out);
int vx_xrizer_dev_audit_release(uint64_t lease);
int vx_xrizer_dev_audit_finish(void);
int vx_xrizer_dev_audit_preframe(void);
#endif
#endif
