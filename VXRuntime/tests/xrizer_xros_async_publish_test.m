/* CPU-only mock of Metal completion for the non-blocking eye-pair submit (default; VXRT_XR_SYNC_SUBMIT unset).
 * Fake command buffers complete only when the test says so, so in-flight behaviour is deterministic.
 * No GPU pixels, no headset: this checks ordering, ownership and counters of the host, nothing about rendering. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include "../src/xrizer_xros_host.m"
@interface FakeTexture : NSObject
@property(nonatomic,strong) id device;
@property(nonatomic) MTLPixelFormat pixelFormat;
@property(nonatomic) MTLTextureType textureType;
@property(nonatomic) NSUInteger width,height,arrayLength,sampleCount;
@end
@implementation FakeTexture
@end
@interface FakeBlit : NSObject
@property(nonatomic) unsigned copies;
@end
@implementation FakeBlit
- (void)copyFromTexture:(id)source sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size toTexture:(id)target destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dest {
    (void)source;(void)slice;(void)level;(void)origin;(void)size;(void)target;(void)ds;(void)dl;(void)dest; ++_copies;
}
- (void)endEncoding {}
@end
@interface FakeBuffer : NSObject
@property(nonatomic) MTLCommandBufferStatus status;
@property(nonatomic,strong) NSError *error;
@property(nonatomic,strong) FakeBlit *blit;
@property(nonatomic) BOOL fail, hold, committed;
@property(nonatomic) double GPUStartTime, GPUEndTime;
@property(nonatomic,strong) NSMutableArray *handlers;
@end
@implementation FakeBuffer
- (id)blitCommandEncoder { self.blit=[FakeBlit new]; return self.blit; }
- (void)addCompletedHandler:(void (^)(id))h { if (!self.handlers) self.handlers=[NSMutableArray new]; [self.handlers addObject:[h copy]]; }
- (void)finish {
    self.status=self.fail ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted;
    if (self.fail) self.error=[NSError errorWithDomain:@"fake" code:1 userInfo:nil]; else { self.GPUStartTime=1; self.GPUEndTime=2; }
    for (void (^h)(id) in self.handlers) h(self);
}
- (void)commit { self.committed=YES; if (!self.hold) [self finish]; }
@end
@interface FakeDevice2 : NSObject
@end
@implementation FakeDevice2
- (BOOL)supportsTextureSampleCount:(NSUInteger)n { return n==1; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    FakeTexture *t=[FakeTexture new]; t.device=self; t.pixelFormat=d.pixelFormat; t.textureType=d.textureType;
    t.width=d.width; t.height=d.height; t.arrayLength=d.arrayLength; t.sampleCount=d.sampleCount; return t;
}
@end
@interface FakeQueue2 : NSObject
@property(nonatomic,strong) id device;
@property(nonatomic) BOOL fail, hold;
@property(nonatomic,strong) NSMutableArray *pending;
@end
@implementation FakeQueue2
- (id)commandBuffer {
    FakeBuffer *b=[FakeBuffer new]; b.fail=self.fail; b.hold=self.hold;
    if (!self.pending) self.pending=[NSMutableArray new];
    if (self.hold) [self.pending addObject:b];
    return b;
}
@end
static XrResult begin(void *p,XrTime *t) {(void)p;*t=1;return XR_SUCCESS;}
static XrResult end(void *p,XrTime *t) {(void)p;*t=2;return XR_SUCCESS;}
static XrResult request(void *p) {(void)p;return XR_SUCCESS;}
static XrResult input(void *p,KlNativeInputSample *s) {(void)p;*s=(KlNativeInputSample){.sample_id=1,.sample_time=1};return XR_SUCCESS;}
static FakeDevice2 *device; static FakeQueue2 *queue; static vx_xros_xrizer_host *h; static FakeTexture *src;
static KlNativeFramePair next_pair(uint64_t id) {
    KlNativeFrameSample sample={.frame_id=id,.pose_id=id+100,.predicted_display_time=(XrTime)id*10,.predicted_display_period=10,
        .should_render=XR_TRUE,.head_location_flags=XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_ORIENTATION_VALID_BIT,
        .local_from_head={.orientation.w=1},.head_from_eye={{.orientation.w=1},{.orientation.w=1}},
        .fov={{-.8f,.8f,.8f,-.8f},{-.8f,.8f,.8f,-.8f}}};
    assert(vx_xros_xrizer_offer(h,&sample)==0 && wait_frame(h,&sample)==XR_SUCCESS);
    KlNativeFramePair pair={.sample=sample};
    for (unsigned i=0;i<2;++i) pair.eye[i]=(KlNativeFrameEye){.texture=(__bridge void *)src,.image_lease=(void *)(uintptr_t)(i+1),
        .format=MTLPixelFormatRGBA8Unorm,.array_layer=i,.rect={{2,1},{4,3}},.local_from_render_eye={.orientation.w=1},.fov=sample.fov[i]};
    return pair;
}
static void finish_one(unsigned index) { FakeBuffer *b=queue.pending[index]; [b finish]; }
static volatile int thread_done;
static void *run_publish(void *arg) { KlNativeFramePair *pr=arg; assert(publish_pair(h,pr)==XR_SUCCESS); thread_done=1; return NULL; }
static void *run_retire(void *arg) { (void)arg; thread_done=(vx_xros_xrizer_retire(h)==0)?1:-1; return NULL; }
static int acquire_id(uint64_t expect_frame) {
    vx_native_vr_frame f; if (vx_xros_xrizer_acquire(h,&f)) return -1;
    if (f.pose.frame_id!=expect_frame) fprintf(stderr,"expected %llu got %llu pose %llu\n",(unsigned long long)expect_frame,(unsigned long long)f.pose.frame_id,(unsigned long long)f.pose.pose_id);
    assert(f.pose.frame_id==expect_frame && f.pose.pose_id==expect_frame+100);
    assert(vx_xros_xrizer_release(h,f.lease)==0); return 0;
}
static uint64_t latest_frame(void) {   /* the pair a presenter would read now (a repeat of the newest published pair), 0 if none */
    vx_native_vr_frame f; if (vx_xros_xrizer_acquire(h,&f)) return 0;
    uint64_t id=f.pose.frame_id; assert(vx_xros_xrizer_release(h,f.lease)==0); return id;
}
static void wait_ms(int ms) { usleep(ms*1000); }
int main(void) {
    @autoreleasepool {
        assert(!getenv("VXRT_XR_SYNC_SUBMIT"));
        device=[FakeDevice2 new]; queue=[FakeQueue2 new]; queue.device=device;
        vx_xros_xrizer_platform p={VX_XROS_XRIZER_API_VERSION,sizeof(p),NULL,begin,end,request,input};
        h=vx_xros_xrizer_create(VX_XROS_XRIZER_INJECTED_TEST,(__bridge void *)device,(__bridge void *)queue,&p); assert(h && h->ring);
        KlNativeViewConfiguration view={.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE};
        assert(vx_xros_xrizer_surface(h,1,&view)==0);
        src=[FakeTexture new];src.device=device;src.pixelFormat=MTLPixelFormatRGBA8Unorm;src.textureType=MTLTextureType2DArray;
        src.width=8;src.height=8;src.arrayLength=2;src.sampleCount=1;

        /* 1. Two pairs in flight: submit returns before the GPU finishes; nothing is published until completion. */
        queue.hold=YES;
        KlNativeFramePair a=next_pair(10); assert(publish_pair(h,&a)==XR_SUCCESS);
        assert(queue.pending.count==1 && ((FakeBuffer *)queue.pending[0]).blit.copies==2);
        assert(acquire_id(10)==-1);   /* the copy has not completed: old imagery must not be labelled as this frame */
        KlNativeFramePair b=next_pair(11); assert(publish_pair(h,&b)==XR_SUCCESS);
        assert(queue.pending.count==2 && vx_eye_ring_inflight(h->ring)==2 && acquire_id(11)==-1);
        /* 2. The bound: a third submit blocks (and is counted) until a copy completes. */
        KlNativeFramePair c=next_pair(12); pthread_t th; thread_done=0;
        pthread_create(&th,NULL,run_publish,&c); wait_ms(150);
        assert(!thread_done && queue.pending.count==2 && h->ring->blocked==1);
        finish_one(0);   /* frame 10 completes: it publishes, and the blocked submit proceeds */
        pthread_join(th,NULL); assert(thread_done==1 && queue.pending.count==3 && h->ring->max_seen==2);
        assert(acquire_id(10)==0);
        finish_one(1); finish_one(2);
        assert(acquire_id(12)==0 && vx_eye_ring_inflight(h->ring)==0);   /* newest completed pair, with its own pose */
        assert(h->last_published==12);
        /* 3. Completions arrive out of order: the older frame is dropped, never shown after the newer. */
        [queue.pending removeAllObjects];
        KlNativeFramePair d=next_pair(13); assert(publish_pair(h,&d)==XR_SUCCESS);
        KlNativeFramePair e=next_pair(14); assert(publish_pair(h,&e)==XR_SUCCESS);
        finish_one(1); finish_one(0);
        assert(h->last_published==14 && h->discarded==1 && acquire_id(14)==0);
        /* 4. A cancelled frame: a waited ticket cancelled without publishing leaves nothing in flight. */
        [queue.pending removeAllObjects];
        KlNativeFramePair f=next_pair(15); assert(cancel_frame(h,f.sample.ticket)==XR_SUCCESS);
        assert(vx_eye_ring_inflight(h->ring)==0 && queue.pending.count==0 && latest_frame()==14 && h->last_published==14);
        /* 5. A failed command buffer publishes nothing, and the next frame still works. */
        queue.hold=NO; queue.fail=YES;
        KlNativeFramePair g=next_pair(16); assert(publish_pair(h,&g)==XR_SUCCESS);
        assert(h->ring->failed==1 && h->last_published==14 && latest_frame()==14 && vx_eye_ring_inflight(h->ring)==0);
        queue.fail=NO;
        KlNativeFramePair g2=next_pair(17); assert(publish_pair(h,&g2)==XR_SUCCESS && acquire_id(17)==0);
        /* 6. Pool reuse: the slots are recycled, not allocated per pair (steady state: no new textures). */
        uint64_t allocs0=h->ring->allocs;
        for (uint64_t id=20;id<40;id++) { KlNativeFramePair q=next_pair(id); assert(publish_pair(h,&q)==XR_SUCCESS); assert(acquire_id(id)==0); }
        assert(h->ring->allocs==allocs0 && h->ring->nslots<=6);   /* steady state allocates nothing */
        /* 7. A pair whose validation fails takes no slot and consumes no ticket. */
        KlNativeFramePair bad=next_pair(40); bad.eye[1].rect.extent.width=100;
        assert(publish_pair(h,&bad)==XR_ERROR_RUNTIME_FAILURE && vx_eye_ring_inflight(h->ring)==0);
        bad.eye[1].rect.extent.width=4; assert(publish_pair(h,&bad)==XR_SUCCESS && acquire_id(40)==0);
        /* 8. Teardown with a copy pending: retire waits for it, the late completion publishes nothing, the host retires. */
        queue.hold=YES; [queue.pending removeAllObjects];
        KlNativeFramePair t=next_pair(41); assert(publish_pair(h,&t)==XR_SUCCESS);
        thread_done=0; pthread_create(&th,NULL,run_retire,NULL); wait_ms(150);
        assert(!thread_done);   /* drain is waiting on the GPU */
        uint64_t before=h->last_published; finish_one(0); pthread_join(th,NULL);
        assert(thread_done==1 && h->last_published==before && vx_eye_ring_inflight(h->ring)==0);
        vx_native_vr_frame none; assert(vx_xros_xrizer_acquire(h,&none)==-1);
        puts("XR host async submit mock: pass; 2 in flight, bound blocks+counts, out-of-order drop, cancel, failed cb unpublished, pool reuse, retire drains");
    }
    return 0;
}
