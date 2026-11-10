// Internal native VR frame exchange. No graphics API or guest interface is implied.
#ifndef VX_NATIVE_VR_H
#define VX_NATIVE_VR_H
#include <stdint.h>
#define VX_NATIVE_VR_ABI_VERSION 1
#ifdef __cplusplus
extern "C" {
#endif

typedef struct vx_native_vr vx_native_vr;
typedef uint64_t vx_native_vr_handle;
// Matrices are column-major, multiply column vectors, and use a right-handed space
// (x right, y up, z backward); translations are in metres. Each name gives the
// destination_from_source transform. Frustum is the raw signed OpenVR tangents: left, right, top, bottom.
typedef struct {
    uint64_t frame_id, pose_id;
    double pose_time;
    uint32_t tracking_valid; // zero when tracking is unavailable
    float origin_from_head[16], head_from_eye[2][16], frustum[2][4];
} vx_native_vr_pose;
typedef enum {
    VX_NATIVE_VR_COLOR_LINEAR = 1,
    VX_NATIVE_VR_COLOR_SRGB = 2
} vx_native_vr_color_space;
typedef struct {
    void *resource;
    uint32_t width, height, format, sample_count; // format is a nonzero backend-defined identifier
    vx_native_vr_color_space color_space;
    float u_min, v_min, u_max, v_max; // normalized bounds
} vx_native_vr_eye;
typedef struct {
    vx_native_vr_handle handle;
    uint64_t lease;
    vx_native_vr_pose pose;
    vx_native_vr_eye eye[2];
} vx_native_vr_frame;

// Callbacks retain/release one reference per accepted eye; they must not call back into the queue.
// All operations are thread-safe. A successful submit must be followed by exactly one complete,
// even after reset; complete means the GPU no longer uses that eye's resource.
vx_native_vr *vx_native_vr_create(void (*retain)(void *), void (*release)(void *));
// Returns -1 while any GPU completion or reader lease is outstanding; otherwise destroys the queue.
// The caller must exclude concurrent calls during a successful destroy.
int vx_native_vr_destroy(vx_native_vr *q);
int vx_native_vr_begin(vx_native_vr *q, const vx_native_vr_pose *pose, vx_native_vr_handle *handle);
int vx_native_vr_submit(vx_native_vr *q, vx_native_vr_handle handle, unsigned eye,
                        uint64_t frame_id, uint64_t pose_id, const vx_native_vr_eye *image);
int vx_native_vr_complete(vx_native_vr *q, vx_native_vr_handle handle, unsigned eye);
// Acquires the newest published pair, or fails if its slot has since been reused. The returned snapshot and resources stay valid until
// exactly one release of its unique lease. A frame permits one outstanding acquisition at a time.
int vx_native_vr_acquire(vx_native_vr *q, vx_native_vr_frame *frame);
int vx_native_vr_release(vx_native_vr *q, uint64_t lease);
/* Shared readers (the xros immersive compositor): several frames in flight may hold the newest pair at once; the lease id is the
 * slot's and each acquire_shared needs one release_shared. The exclusive pair above is unchanged. */
int vx_native_vr_acquire_shared(vx_native_vr *q, vx_native_vr_frame *frame);
int vx_native_vr_release_shared(vx_native_vr *q, uint64_t lease);
// Cancel one frame; its leases and submitted GPU work drain normally. Duplicate or stale handles fail.
int vx_native_vr_cancel(vx_native_vr *q, vx_native_vr_handle handle);
// Cancel all frames. Existing reader leases and GPU work remain valid until released/completed.
void vx_native_vr_reset(vx_native_vr *q);
#ifdef __cplusplus
}
#endif
#endif
