/* Native frame, pose, and publication contract; MIT, see ../LICENSE. */
#ifndef KL_NATIVE_FRAME_HOST_H
#define KL_NATIVE_FRAME_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
#define KL_NATIVE_FRAME_HOST_VERSION 1u
/* All XrTime values are monotonic nanoseconds in one explicitly calibrated
 * clock shared by lifecycle events, predictions, locate and publication.
 * Apple platform time conversion must be measured/defined by the host; do
 * not cast values from an unrelated clock or claim tracking based on HMD
 * presence. IDs are host-origin, nonzero and identify distinct producer frames
 * and pose samples. A compositor repeat keeps the original IDs. */
typedef struct KlNativeFrameSample {
    void *ticket; /* non-null host-owned cancellation token, independent of IDs */
    uint64_t frame_id, pose_id;
    XrTime predicted_display_time;
    XrDuration predicted_display_period;
    XrBool32 should_render;
    /* XrSpaceLocationFlags apply to local_from_head and propagated eyes. */
    XrSpaceLocationFlags head_location_flags;
    XrPosef local_from_head;
    XrPosef head_from_eye[2];
    XrFovf fov[2]; /* OpenXR radians, ordered left/right/up/down */
    XrBool32 stage_valid;
    XrPosef local_from_stage; /* supplied only when stage_valid; never inferred */
} KlNativeFrameSample;

/* Borrowed until publish_pair returns. The provider has completed GPU writes
 * and retains each image lease while preparing this call. Format is an actual
 * MTLPixelFormat. local_from_render_eye is computed from the pose submitted in
 * the projection layer's declared space, not substituted by a newer pose. */
typedef struct KlNativeFrameEye {
    void *texture;     /* native id<MTLTexture>, borrowed for the callback */
    void *image_lease; /* provider-owned, live, borrowed for the callback */
    int64_t format;
    uint32_t array_layer;
    XrRect2Di rect;
    XrPosef local_from_render_eye;
    XrFovf fov;
} KlNativeFrameEye;
typedef struct KlNativeFramePair {
    KlNativeFrameSample sample; /* exact latched sample, never a newer pose */
    KlNativeFrameEye eye[2]; /* index 0 left, index 1 right */
    /* Adapter derives head_from_eye as inverse(sample.local_from_head) times
     * eye.local_from_render_eye; carry submitted eye FOVs and sample flags/time. */
} KlNativeFramePair;

/* Callbacks and context are native host ABI, serialized, valid through session
 * destruction and may not synchronously reenter the provider. */
typedef struct KlNativeFrameHost {
    uint32_t version, struct_size;
    void *context;
    /* Wait for a genuine host frame opportunity, returning a single consistent
     * sample and a non-null cancellation ticket. Do not return success for timeout/failure. Tracking flags remain
     * clear when unavailable. On success the host owns an outstanding frame
     * ticket until exactly one accepted publish_pair or cancel_frame call. */
    XrResult (*wait_frame)(void *context, KlNativeFrameSample *sample);
    /* Publish atomically, only after all producer/copy writes completed. Before
     * returning success the host must acquire its OWN strong references for both
     * eyes and submit one matching frame/pose pair. Reader refs outlive and are
     * independent of the provider's swapchain leases; drain via native_vr queue
     * release. A failure takes no refs and publishes nothing. */
    XrResult (*publish_pair)(void *context, const KlNativeFramePair *pair);
    /* Consume a waited ticket without publishing. Return success only when all
     * associated producer/reader work is safely drained; errors leave ticket
     * ownership outstanding for retry. Never label an old frame as fresh. */
    XrResult (*cancel_frame)(void *context, void *ticket);
} KlNativeFrameHost;
XrResult kl_native_configure_frame(const KlNativeFrameHost *host);
#endif
