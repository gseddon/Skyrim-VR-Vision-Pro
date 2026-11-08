/* Thread-safe boundary between one Apple compositor producer and xrWaitFrame. */
#ifndef VX_XRIZER_XROS_MAILBOX_H
#define VX_XRIZER_XROS_MAILBOX_H
#include <stdint.h>
#include "frame_host.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct vx_xros_frame_mailbox vx_xros_frame_mailbox;
vx_xros_frame_mailbox *vx_xros_mailbox_create(void);
/* An unclaimed sample may be replaced by a newer one; no claimed ticket is
 * overwritten. `sample->ticket` must be NULL: the mailbox allocates a unique
 * opaque token when the provider claims it. IDs and predicted time are host
 * observations, never generated or inferred here. */
int vx_xros_mailbox_offer(vx_xros_frame_mailbox *, const KlNativeFrameSample *sample);
/* Wait is bounded, and returns XR_ERROR_SESSION_LOST on stop and
 * XR_ERROR_RUNTIME_FAILURE on timeout; no ticket is returned on error. */
XrResult vx_xros_mailbox_wait(vx_xros_frame_mailbox *, uint32_t timeout_ms, KlNativeFrameSample *out);
/* Validate the token and all latched frame/pose metadata before publication. */
int vx_xros_mailbox_matches(vx_xros_frame_mailbox *, const KlNativeFrameSample *sample);
/* A successful publish or cancellation consumes the exact outstanding token.
 * A failed publish/cancellation must not call this function. */
int vx_xros_mailbox_finish(vx_xros_frame_mailbox *, void *ticket);
/* Drops an unclaimed sample on surface loss; claimed tickets remain owned. */
void vx_xros_mailbox_invalidate(vx_xros_frame_mailbox *);
/* Stop wakes waiters and discards only unclaimed samples. An outstanding ticket
 * remains owned until explicit finish; destroy fails while waiters/tickets exist. */
void vx_xros_mailbox_stop(vx_xros_frame_mailbox *);
/* True only after stop, with no outstanding ticket or blocked waiter. */
int vx_xros_mailbox_drained(vx_xros_frame_mailbox *);
int vx_xros_mailbox_destroy(vx_xros_frame_mailbox *);
#ifdef __cplusplus
}
#endif
#endif
