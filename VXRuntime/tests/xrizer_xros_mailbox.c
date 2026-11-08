#include "xrizer_xros_mailbox.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
static KlNativeFrameSample sample(uint64_t id) {
    return (KlNativeFrameSample){.frame_id=id,.pose_id=100+id,.predicted_display_time=(XrTime)id*100,
        .predicted_display_period=10,.should_render=XR_TRUE};
}
static void *waiter(void *context) {
    KlNativeFrameSample out = {0};
    assert(vx_xros_mailbox_wait(context, 1000, &out) == XR_ERROR_SESSION_LOST);
    return NULL;
}
int main(void) {
    vx_xros_frame_mailbox *m = vx_xros_mailbox_create(); assert(m);
    KlNativeFrameSample a = sample(1), b = sample(2), c = sample(3), out = {0};
    assert(vx_xros_mailbox_offer(m,&a)==0 && vx_xros_mailbox_offer(m,&b)==0);
    assert(vx_xros_mailbox_offer(m,&a)==-1);
    assert(vx_xros_mailbox_wait(m,100,&out)==XR_SUCCESS && out.frame_id==2 && out.pose_id==102 && out.ticket);
    assert(vx_xros_mailbox_matches(m,&out));
    KlNativeFrameSample wrong=out; wrong.pose_id++;
    assert(!vx_xros_mailbox_matches(m,&wrong));
    void *first = out.ticket;
    assert(vx_xros_mailbox_wait(m,100,&out)==XR_ERROR_CALL_ORDER_INVALID);
    assert(vx_xros_mailbox_offer(m,&c)==0);
    assert(vx_xros_mailbox_finish(m,(void *)(uintptr_t)999)==-1);
    assert(vx_xros_mailbox_finish(m,first)==0 && vx_xros_mailbox_finish(m,first)==-1);
    assert(!vx_xros_mailbox_matches(m,&out));
    assert(vx_xros_mailbox_wait(m,100,&out)==XR_SUCCESS && out.frame_id==3 && out.ticket!=first);
    assert(vx_xros_mailbox_finish(m,first)==-1);
    vx_xros_mailbox_stop(m);
    assert(vx_xros_mailbox_destroy(m)==-1);
    assert(vx_xros_mailbox_finish(m,out.ticket)==0 && vx_xros_mailbox_destroy(m)==0);
    m=vx_xros_mailbox_create(); assert(m);
    assert(vx_xros_mailbox_offer(m,&a)==0);
    vx_xros_mailbox_invalidate(m);
    memset(&out,0x5a,sizeof out); KlNativeFrameSample original=out;
    assert(vx_xros_mailbox_wait(m,1,&out)==XR_ERROR_RUNTIME_FAILURE && !memcmp(&out,&original,sizeof out));
    assert(vx_xros_mailbox_offer(m,&a)==-1); /* invalidation never rewinds identity */
    assert(vx_xros_mailbox_offer(m,&b)==0);
    assert(vx_xros_mailbox_wait(m,100,&out)==XR_SUCCESS && out.frame_id==2);
    vx_xros_mailbox_invalidate(m); assert(vx_xros_mailbox_matches(m,&out));
    assert(vx_xros_mailbox_finish(m,out.ticket)==0);
    pthread_t thread; assert(!pthread_create(&thread,NULL,waiter,m));
    vx_xros_mailbox_stop(m); assert(!pthread_join(thread,NULL));
    assert(vx_xros_mailbox_offer(m,&a)==-1 && vx_xros_mailbox_destroy(m)==0);
    puts("XR compositor mailbox: pass; injected producer, no GPU or headset");
    return 0;
}
