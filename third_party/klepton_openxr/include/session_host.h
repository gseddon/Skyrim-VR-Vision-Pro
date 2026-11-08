/* Native session lifecycle contract; MIT, see ../LICENSE. */
#ifndef KL_NATIVE_SESSION_HOST_H
#define KL_NATIVE_SESSION_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
#define KL_NATIVE_SESSION_HOST_VERSION 1u
/* Events describe real host immersive state, not HMD availability. */
typedef enum KlNativeSessionEventType {
    KL_NATIVE_SESSION_READY = 1,
    KL_NATIVE_SESSION_VISIBLE = 2,
    KL_NATIVE_SESSION_FOCUSED = 3,
    KL_NATIVE_SESSION_STOPPING = 4,
    KL_NATIVE_SESSION_LOSS = 5,
    KL_NATIVE_SESSION_EXITING = 6
} KlNativeSessionEventType;
typedef struct KlNativeSessionEvent { KlNativeSessionEventType type; XrTime time; } KlNativeSessionEvent;
/* All callbacks use native ABI, are serialized, and must not reenter provider.
 * Callback/context lifetime extends through session destruction. poll_event
 * returns XR_EVENT_UNAVAILABLE when empty; event.time is positive and
 * monotonic in the same clock as future predicted display times. begin/end
 * return actual platform acknowledgement and timestamp. end may return
 * success only after all producer GPU work and host reader leases have drained;
 * failures leave provider state unchanged and must never claim completion. */
typedef struct KlNativeSessionHost {
    uint32_t version, struct_size;
    void *context;
    XrResult (*poll_event)(void *context, KlNativeSessionEvent *event);
    XrResult (*begin_session)(void *context, XrTime *ack_time);
    XrResult (*end_session)(void *context, XrTime *ack_time);
    /* Optional. Success acknowledges a request only; STOPPING and later
     * EXITING still require actual host poll_event transitions. */
    XrResult (*request_exit)(void *context);
} KlNativeSessionHost;
XrResult kl_native_configure_session(const KlNativeSessionHost *host);
#endif
