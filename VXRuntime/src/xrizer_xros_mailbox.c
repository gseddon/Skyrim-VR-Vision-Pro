#include "xrizer_xros_mailbox.h"
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct vx_xros_frame_mailbox {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    KlNativeFrameSample pending;
    KlNativeFrameSample claimed;
    uint64_t last_frame;
    XrTime last_time;
    uintptr_t next_ticket, outstanding;
    unsigned has_pending, stopped, waiters;
};
vx_xros_frame_mailbox *vx_xros_mailbox_create(void) {
    vx_xros_frame_mailbox *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    if (pthread_mutex_init(&m->lock, NULL)) { free(m); return NULL; }
    if (pthread_cond_init(&m->ready, NULL)) { pthread_mutex_destroy(&m->lock); free(m); return NULL; }
    return m;
}
int vx_xros_mailbox_offer(vx_xros_frame_mailbox *m, const KlNativeFrameSample *s) {
    if (!m || !s || s->ticket || !s->frame_id || !s->pose_id || s->predicted_display_time <= 0 ||
        s->predicted_display_period <= 0 || s->should_render > XR_TRUE || s->stage_valid > XR_TRUE) return -1;
    pthread_mutex_lock(&m->lock);
    int ok = !m->stopped && s->frame_id > m->last_frame && s->predicted_display_time > m->last_time;
    if (ok) { m->pending = *s; m->has_pending = 1; m->last_frame = s->frame_id; m->last_time = s->predicted_display_time; pthread_cond_signal(&m->ready); }
    pthread_mutex_unlock(&m->lock);
    return ok ? 0 : -1;
}
XrResult vx_xros_mailbox_wait(vx_xros_frame_mailbox *m, uint32_t timeout_ms, KlNativeFrameSample *out) {
    if (!m || !out || !timeout_ms || timeout_ms > 60000) return XR_ERROR_VALIDATION_FAILURE;
    struct timespec deadline;
    if (clock_gettime(CLOCK_MONOTONIC, &deadline)) return XR_ERROR_RUNTIME_FAILURE;
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { ++deadline.tv_sec; deadline.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&m->lock);
    if (m->outstanding || m->waiters) { pthread_mutex_unlock(&m->lock); return XR_ERROR_CALL_ORDER_INVALID; }
    ++m->waiters;
    int rc = 0;
    while (!m->has_pending && !m->stopped && rc == 0) {
        struct timespec now, remaining;
        if (clock_gettime(CLOCK_MONOTONIC,&now)) { rc=EINVAL; break; }
        remaining.tv_sec=deadline.tv_sec-now.tv_sec;
        remaining.tv_nsec=deadline.tv_nsec-now.tv_nsec;
        if (remaining.tv_nsec<0) { --remaining.tv_sec; remaining.tv_nsec+=1000000000L; }
        if (remaining.tv_sec<0 || (!remaining.tv_sec && !remaining.tv_nsec)) { rc=ETIMEDOUT; break; }
#ifdef __APPLE__
        rc=pthread_cond_timedwait_relative_np(&m->ready,&m->lock,&remaining);
#else
        struct timespec absolute;
        if (clock_gettime(CLOCK_REALTIME,&absolute)) { rc=EINVAL; break; }
        absolute.tv_sec+=remaining.tv_sec; absolute.tv_nsec+=remaining.tv_nsec;
        if (absolute.tv_nsec>=1000000000L) { ++absolute.tv_sec; absolute.tv_nsec-=1000000000L; }
        rc=pthread_cond_timedwait(&m->ready,&m->lock,&absolute);
#endif
    }
    XrResult result = XR_ERROR_RUNTIME_FAILURE;
    if (m->stopped) result = XR_ERROR_SESSION_LOST;
    else if (rc == 0 && m->has_pending && m->next_ticket != UINTPTR_MAX) {
        m->outstanding = ++m->next_ticket;
        *out = m->pending;
        out->ticket = (void *)m->outstanding;
        m->claimed = *out;
        m->has_pending = 0;
        result = XR_SUCCESS;
    }
    --m->waiters;
    pthread_mutex_unlock(&m->lock);
    return result;
}
int vx_xros_mailbox_matches(vx_xros_frame_mailbox *m, const KlNativeFrameSample *s) {
    if (!m || !s || !s->ticket) return 0;
    pthread_mutex_lock(&m->lock);
    const KlNativeFrameSample *c = &m->claimed;
    int ok = m->outstanding == (uintptr_t)s->ticket && c->frame_id == s->frame_id && c->pose_id == s->pose_id &&
        c->predicted_display_time == s->predicted_display_time && c->predicted_display_period == s->predicted_display_period &&
        c->should_render == s->should_render && c->head_location_flags == s->head_location_flags && c->stage_valid == s->stage_valid &&
        !memcmp(&c->local_from_head,&s->local_from_head,sizeof c->local_from_head) &&
        !memcmp(c->head_from_eye,s->head_from_eye,sizeof c->head_from_eye) &&
        !memcmp(c->fov,s->fov,sizeof c->fov) &&
        !memcmp(&c->local_from_stage,&s->local_from_stage,sizeof c->local_from_stage);
    pthread_mutex_unlock(&m->lock);
    return ok;
}
int vx_xros_mailbox_finish(vx_xros_frame_mailbox *m, void *ticket) {
    if (!m || !ticket) return -1;
    pthread_mutex_lock(&m->lock);
    int ok = m->outstanding == (uintptr_t)ticket;
    if (ok) m->outstanding = 0;
    pthread_mutex_unlock(&m->lock);
    return ok ? 0 : -1;
}
void vx_xros_mailbox_invalidate(vx_xros_frame_mailbox *m) {
    if (!m) return;
    pthread_mutex_lock(&m->lock); m->has_pending = 0; pthread_mutex_unlock(&m->lock);
}
void vx_xros_mailbox_stop(vx_xros_frame_mailbox *m) {
    if (!m) return;
    pthread_mutex_lock(&m->lock); m->stopped = 1; m->has_pending = 0; pthread_cond_broadcast(&m->ready); pthread_mutex_unlock(&m->lock);
}
int vx_xros_mailbox_drained(vx_xros_frame_mailbox *m) {
    if (!m) return 0;
    pthread_mutex_lock(&m->lock);
    int ok = m->stopped && !m->outstanding && !m->waiters;
    pthread_mutex_unlock(&m->lock);
    return ok;
}
int vx_xros_mailbox_destroy(vx_xros_frame_mailbox *m) {
    if (!m) return -1;
    pthread_mutex_lock(&m->lock);
    int ok = m->stopped && !m->outstanding && !m->waiters;
    pthread_mutex_unlock(&m->lock);
    if (!ok) return -1;
    pthread_cond_destroy(&m->ready); pthread_mutex_destroy(&m->lock); free(m); return 0;
}
