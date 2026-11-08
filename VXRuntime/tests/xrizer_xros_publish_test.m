/* CPU-only mock of Metal completion/retention; no GPU pixels are produced. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
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
@property(nonatomic) BOOL fail;
@end
@implementation FakeBuffer
- (id)blitCommandEncoder { self.blit=[FakeBlit new]; return self.blit; }
- (void)commit { self.status=self.fail ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted; }
- (void)waitUntilCompleted {}
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
@property(nonatomic) BOOL fail;
@property(nonatomic,strong) FakeBuffer *last;
@end
@implementation FakeQueue2
- (id)commandBuffer { self.last=[FakeBuffer new]; self.last.fail=self.fail; return self.last; }
@end
static XrResult begin(void *p,XrTime *t) {(void)p;*t=1;return XR_SUCCESS;}
static XrResult end(void *p,XrTime *t) {(void)p;*t=2;return XR_SUCCESS;}
static XrResult request(void *p) {(void)p;return XR_SUCCESS;}
static XrResult input(void *p,KlNativeInputSample *s) {(void)p;*s=(KlNativeInputSample){.sample_id=1,.sample_time=1};return XR_SUCCESS;}
int main(void) {
    @autoreleasepool {
        FakeDevice2 *device=[FakeDevice2 new]; FakeQueue2 *queue=[FakeQueue2 new]; queue.device=device;
        vx_xros_xrizer_platform p={VX_XROS_XRIZER_API_VERSION,sizeof(p),NULL,begin,end,request,input};
        vx_xros_xrizer_host *h=vx_xros_xrizer_create(VX_XROS_XRIZER_INJECTED_TEST,(__bridge void *)device,(__bridge void *)queue,&p); assert(h);
        KlNativeViewConfiguration view={.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE};
        assert(vx_xros_xrizer_surface(h,1,&view)==0);
        KlNativeFrameSample sample={.frame_id=10,.pose_id=20,.predicted_display_time=100,.predicted_display_period=10,
            .should_render=XR_TRUE,.head_location_flags=XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_ORIENTATION_VALID_BIT,
            .local_from_head={.orientation.w=1},.head_from_eye={{.orientation.w=1},{.orientation.w=1}},
            .fov={{-.8f,.8f,.8f,-.8f},{-.8f,.8f,.8f,-.8f}}};
        assert(vx_xros_xrizer_offer(h,&sample)==0 && wait_frame(h,&sample)==XR_SUCCESS);
        FakeTexture *src=[FakeTexture new];src.device=device;src.pixelFormat=MTLPixelFormatRGBA8Unorm;src.textureType=MTLTextureType2DArray;
        src.width=8;src.height=8;src.arrayLength=2;src.sampleCount=1;
        KlNativeFramePair pair={.sample=sample};
        for (unsigned i=0;i<2;++i) pair.eye[i]=(KlNativeFrameEye){.texture=(__bridge void *)src,.image_lease=(void *)(uintptr_t)(i+1),
            .format=MTLPixelFormatRGBA8Unorm,.array_layer=i,.rect={{2,1},{4,3}},.local_from_render_eye={.orientation.w=1},.fov=sample.fov[i]};
        KlNativeFramePair wrong=pair; wrong.sample.pose_id++;
        assert(publish_pair(h,&wrong)==XR_ERROR_HANDLE_INVALID);
        queue.fail=YES; assert(publish_pair(h,&pair)==XR_ERROR_RUNTIME_FAILURE);
        vx_native_vr_frame frame; assert(vx_xros_xrizer_acquire(h,&frame)==-1);
        queue.fail=NO; assert(publish_pair(h,&pair)==XR_SUCCESS && queue.last.blit.copies==2);
        assert(vx_xros_xrizer_acquire(h,&frame)==0 && frame.pose.frame_id==10 && frame.pose.pose_id==20 &&
               frame.eye[0].width==4 && frame.eye[0].height==3 && frame.eye[1].width==4 && frame.eye[1].height==3);
        uint64_t lease=frame.lease;
        assert(vx_xros_xrizer_acquire(h,&frame)==-1);
        assert(vx_xros_xrizer_release(h,lease)==0 && vx_xros_xrizer_release(h,lease)==-1);
        assert(vx_xros_xrizer_acquire(h,&frame)==0 && frame.pose.frame_id==10 && frame.pose.pose_id==20 && frame.lease!=lease);
        assert(vx_xros_xrizer_retire(h)==-1);
        vx_native_vr_frame blocked; assert(vx_xros_xrizer_acquire(h,&blocked)==-1);
        assert(vx_xros_xrizer_release(h,frame.lease)==0);
        assert(vx_xros_xrizer_retire(h)==0);
        puts("XR host mock pair: pass; fake Metal completion/leases, no GPU pixels or headset");
    }
    return 0;
}
