#include "native_vr.h"
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    vx_native_vr_frame frame;
    unsigned submitted, completed, readers;
    int cancelled, published;
    uint64_t lease;
} slot;
struct vx_native_vr {
    pthread_mutex_t lock;
    void (*retain)(void *), (*release)(void *);
    uint64_t next_handle, next_lease, newest_published;
    slot slots[3];
};
static void clear(vx_native_vr *q, slot *s) {
    for (unsigned i = 0; i < 2; i++) if (s->submitted & (1u << i)) q->release(s->frame.eye[i].resource);
    memset(s, 0, sizeof *s);
}
static slot *find(vx_native_vr *q, vx_native_vr_handle h) {
    if (!h) return NULL;
    for (unsigned i = 0; i < 3; i++) if (q->slots[i].frame.handle == h) return &q->slots[i];
    return NULL;
}
static int drained(const slot *s) { return s->submitted == s->completed && !s->readers; }
static void collect(vx_native_vr *q, slot *s) { if (s->cancelled && drained(s)) clear(q, s); }
vx_native_vr *vx_native_vr_create(void (*retain)(void *), void (*release)(void *)) {
    if (!retain || !release) return NULL;
    vx_native_vr *q = calloc(1, sizeof *q);
    if (!q) return NULL;
    if (pthread_mutex_init(&q->lock, NULL)) { free(q); return NULL; }
    q->retain = retain; q->release = release;
    return q;
}
int vx_native_vr_destroy(vx_native_vr *q) {
    if (!q) return -1;
    pthread_mutex_lock(&q->lock);
    for (unsigned i = 0; i < 3; i++) if (!drained(&q->slots[i])) { pthread_mutex_unlock(&q->lock); return -1; }
    for (unsigned i = 0; i < 3; i++) clear(q, &q->slots[i]);
    pthread_mutex_unlock(&q->lock);
    pthread_mutex_destroy(&q->lock); free(q); return 0;
}
static int valid_pose(const vx_native_vr_pose *p) {
    if (!p || !isfinite(p->pose_time)) return 0;
    for (unsigned i = 0; i < 16; i++) if (!isfinite(p->origin_from_head[i])) return 0;
    for (unsigned eye = 0; eye < 2; eye++) {
        for (unsigned i = 0; i < 16; i++) if (!isfinite(p->head_from_eye[eye][i])) return 0;
        for (unsigned i = 0; i < 4; i++) if (!isfinite(p->frustum[eye][i])) return 0;
    }
    return 1;
}
int vx_native_vr_begin(vx_native_vr *q, const vx_native_vr_pose *pose, vx_native_vr_handle *handle) {
    if (!q || !valid_pose(pose) || !handle) return -1;
    pthread_mutex_lock(&q->lock);
    slot *s = NULL;
    for (unsigned i = 0; i < 3; i++) if (!q->slots[i].frame.handle) { s = &q->slots[i]; break; }
    if (!s) for (unsigned i = 0; i < 3; i++) {
        slot *p = &q->slots[i];
        if (p->published && drained(p) && (!s || p->frame.handle < s->frame.handle)) s = p;
    }
    // Never reuse a handle, including after reset; exhaustion is a permanent refusal.
    if (!s || q->next_handle == UINT64_MAX) { pthread_mutex_unlock(&q->lock); return -1; }
    if (s->frame.handle) clear(q, s);
    s->frame.handle = ++q->next_handle; s->frame.pose = *pose; *handle = s->frame.handle;
    pthread_mutex_unlock(&q->lock); return 0;
}
static int valid(const vx_native_vr_eye *e) {
    return e && e->resource && e->width && e->height && e->format && e->sample_count &&
           (e->color_space == VX_NATIVE_VR_COLOR_LINEAR || e->color_space == VX_NATIVE_VR_COLOR_SRGB) &&
           isfinite(e->u_min) && isfinite(e->v_min) && isfinite(e->u_max) && isfinite(e->v_max) &&
           e->u_min >= 0 && e->v_min >= 0 && e->u_max <= 1 && e->v_max <= 1 &&
           e->u_min < e->u_max && e->v_min < e->v_max;
}
int vx_native_vr_submit(vx_native_vr *q, vx_native_vr_handle h, unsigned eye, uint64_t frame_id,
                        uint64_t pose_id, const vx_native_vr_eye *image) {
    if (!q || eye > 1 || !valid(image)) return -1;
    pthread_mutex_lock(&q->lock);
    slot *s = find(q, h); unsigned bit = 1u << eye;
    if (!s || s->cancelled || (s->submitted & bit) || s->frame.pose.frame_id != frame_id || s->frame.pose.pose_id != pose_id) {
        pthread_mutex_unlock(&q->lock); return -1;
    }
    if (s->submitted) {
        vx_native_vr_eye *other = &s->frame.eye[1 - eye];
        if (other->width != image->width || other->height != image->height || other->format != image->format ||
            other->sample_count != image->sample_count || other->color_space != image->color_space) {
            pthread_mutex_unlock(&q->lock); return -1;
        }
    }
    q->retain(image->resource); s->frame.eye[eye] = *image; s->submitted |= bit;
    pthread_mutex_unlock(&q->lock); return 0;
}
int vx_native_vr_complete(vx_native_vr *q, vx_native_vr_handle h, unsigned eye) {
    if (!q || eye > 1) return -1;
    pthread_mutex_lock(&q->lock); slot *s = find(q, h); unsigned bit = 1u << eye;
    if (!s || !(s->submitted & bit) || (s->completed & bit)) { pthread_mutex_unlock(&q->lock); return -1; }
    s->completed |= bit;
    if (!s->cancelled && s->submitted == 3 && s->completed == 3) {
        if (h > q->newest_published) { s->published = 1; q->newest_published = h; }
        else s->cancelled = 1;
    }
    collect(q, s); pthread_mutex_unlock(&q->lock); return 0;
}
int vx_native_vr_acquire(vx_native_vr *q, vx_native_vr_frame *frame) {
    if (!q || !frame) return -1;
    pthread_mutex_lock(&q->lock); slot *s = NULL;
    for (unsigned i = 0; i < 3; i++) {
        slot *p = &q->slots[i];
        if (p->published && !p->cancelled && p->frame.handle == q->newest_published) s = p;
    }
    if (!s || s->readers || q->next_lease == UINT64_MAX) { pthread_mutex_unlock(&q->lock); return -1; }
    s->readers = 1; s->lease = ++q->next_lease; *frame = s->frame; frame->lease = s->lease;
    pthread_mutex_unlock(&q->lock); return 0;
}
int vx_native_vr_acquire_shared(vx_native_vr *q, vx_native_vr_frame *frame) {
    if (!q || !frame) return -1;
    pthread_mutex_lock(&q->lock); slot *s = NULL;
    for (unsigned i = 0; i < 3; i++) {
        slot *p = &q->slots[i];
        if (p->published && !p->cancelled && p->frame.handle == q->newest_published) s = p;
    }
    if (!s || (!s->readers && q->next_lease == UINT64_MAX) || s->readers == UINT_MAX) { pthread_mutex_unlock(&q->lock); return -1; }
    if (!s->readers) s->lease = ++q->next_lease;
    ++s->readers; *frame = s->frame; frame->lease = s->lease;
    pthread_mutex_unlock(&q->lock); return 0;
}
int vx_native_vr_release_shared(vx_native_vr *q, uint64_t lease) {
    if (!q) return -1;
    pthread_mutex_lock(&q->lock); slot *s = NULL;
    for (unsigned i = 0; i < 3; i++) if (lease && q->slots[i].lease == lease) { s = &q->slots[i]; break; }
    if (!s || !s->readers) { pthread_mutex_unlock(&q->lock); return -1; }
    if (--s->readers == 0) { s->lease = 0; collect(q, s); }
    pthread_mutex_unlock(&q->lock); return 0;
}
int vx_native_vr_release(vx_native_vr *q, uint64_t lease) {
    if (!q) return -1;
    pthread_mutex_lock(&q->lock); slot *s = NULL;
    for (unsigned i = 0; i < 3; i++) if (lease && q->slots[i].lease == lease) { s = &q->slots[i]; break; }
    if (!s || !s->readers) { pthread_mutex_unlock(&q->lock); return -1; }
    s->readers = 0; s->lease = 0; collect(q, s); pthread_mutex_unlock(&q->lock); return 0;
}
int vx_native_vr_cancel(vx_native_vr *q, vx_native_vr_handle h) {
    if (!q) return -1;
    pthread_mutex_lock(&q->lock); slot *s = find(q, h);
    if (!s || s->cancelled) { pthread_mutex_unlock(&q->lock); return -1; }
    s->cancelled = 1; collect(q, s);
    pthread_mutex_unlock(&q->lock); return 0;
}
void vx_native_vr_reset(vx_native_vr *q) {
    if (!q) return;
    pthread_mutex_lock(&q->lock);
    for (unsigned i = 0; i < 3; i++) if (q->slots[i].frame.handle) { q->slots[i].cancelled = 1; collect(q, &q->slots[i]); }
    pthread_mutex_unlock(&q->lock);
}
