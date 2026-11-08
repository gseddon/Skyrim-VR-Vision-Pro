/* Shared owned-fixture Metal host helpers; no production host/physical tracking. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#ifdef __cplusplus
extern "C" {
#endif
#include "apple_metal_host.h"
#include "frame_host.h"
#include "session_host.h"
#include "klepton_native.h"
#include "pose_math.h"
#include "native_vr.h"
#define XR_USE_GRAPHICS_API_METAL 1
#include <openxr/openxr_platform.h>
#ifdef __cplusplus
}
#endif

static unsigned retained, released;
static void keep_texture(void *raw) { assert(raw); (void)CFBridgingRetain((__bridge id)raw); ++retained; }
static void drop_texture(void *raw) { assert(raw); (void)CFBridgingRelease(raw); ++released; }
static XrTime monotonic_ns(void) {
    struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (XrTime)t.tv_sec * INT64_C(1000000000) + t.tv_nsec;
}
static void near(float a, float b) { assert(isfinite(a) && fabsf(a-b) < 0.00002f); }
static void pose_matrix(XrPosef p, float m[16]) {
    const float x=p.orientation.x, y=p.orientation.y, z=p.orientation.z, w=p.orientation.w;
    const float v[16] = {1-2*y*y-2*z*z, 2*x*y+2*w*z, 2*x*z-2*w*y, 0,
        2*x*y-2*w*z, 1-2*x*x-2*z*z, 2*y*z+2*w*x, 0,
        2*x*z+2*w*y, 2*y*z-2*w*x, 1-2*x*x-2*y*y, 0,
        p.position.x,p.position.y,p.position.z,1};
    memcpy(m,v,sizeof v);
}
@interface FrameHost : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,assign) vx_native_vr *frames;
@property(nonatomic) KlNativeSessionEvent event;
@property(nonatomic) XrTime acknowledgement;
@property(nonatomic) KlNativeFrameSample sample;
@property(nonatomic) KlNativeFramePair lastPair;
@property(nonatomic) void *outstanding;
@property(nonatomic) unsigned waits, publishes, cancels;
@property(nonatomic) BOOL failAfterFirstEye;
@end
@implementation FrameHost
@end
static FrameHost *host(void *ctx) { return (__bridge FrameHost *)ctx; }
static vx_native_vr_pose native_pose(const KlNativeFramePair *pair) {
    vx_native_vr_pose p={ .frame_id=pair->sample.frame_id, .pose_id=pair->sample.pose_id,
        .pose_time=(double)pair->sample.predicted_display_time / 1e9 };
    const XrSpaceLocationFlags valid=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    p.tracking_valid=(pair->sample.head_location_flags & valid)==valid;
    pose_matrix(pair->sample.local_from_head,p.origin_from_head);
    for (unsigned eye=0;eye<2;++eye) {
        pose_matrix(kl_native_pose_relative(pair->sample.local_from_head,pair->eye[eye].local_from_render_eye),p.head_from_eye[eye]);
        XrFovf f=pair->eye[eye].fov;
        p.frustum[eye][0]=tanf(f.angleLeft); p.frustum[eye][1]=tanf(f.angleRight);
        p.frustum[eye][2]=-tanf(f.angleUp); p.frustum[eye][3]=-tanf(f.angleDown);
    }
    return p;
}
static XrResult publish_host(void *ctx, const KlNativeFramePair *pair) {
    FrameHost *h=host(ctx); assert(pair && pair->sample.ticket==h.outstanding);
    assert(pair->sample.frame_id==h.sample.frame_id && pair->sample.pose_id==h.sample.pose_id);
    assert(pair->sample.predicted_display_time==h.sample.predicted_display_time);
    assert(pair->sample.head_location_flags==h.sample.head_location_flags);
    /* The host takes independent copies before returning. No provider array image
     * can subsequently be handed to a reader or corrupt a repeated frame. */
    id<MTLTexture> copies[2];
    id<MTLCommandBuffer> cb=[h.queue commandBuffer]; if (!cb) return XR_ERROR_OUT_OF_MEMORY;
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; if (!blit) return XR_ERROR_RUNTIME_FAILURE;
    for (unsigned eye=0;eye<2;++eye) {
        const KlNativeFrameEye *e=&pair->eye[eye];
        id<MTLTexture> source=(__bridge id<MTLTexture>)e->texture;
        assert(source && source.device==h.device && e->image_lease && source.sampleCount==1);
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)e->format
            width:e->rect.extent.width height:e->rect.extent.height mipmapped:NO];
        d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageShaderRead;
        copies[eye]=[h.device newTextureWithDescriptor:d];
        if (!copies[eye]) { [blit endEncoding]; return XR_ERROR_OUT_OF_MEMORY; }
        [blit copyFromTexture:source sourceSlice:e->array_layer sourceLevel:0
            sourceOrigin:MTLOriginMake(e->rect.offset.x,e->rect.offset.y,0)
            sourceSize:MTLSizeMake(e->rect.extent.width,e->rect.extent.height,1)
            toTexture:copies[eye] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    }
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted || cb.error) return XR_ERROR_RUNTIME_FAILURE;
    vx_native_vr_pose pose=native_pose(pair); vx_native_vr_handle handle=0;
    if (vx_native_vr_begin(h.frames,&pose,&handle)) return XR_ERROR_RUNTIME_FAILURE;
    unsigned submitted=0;
    for (unsigned eye=0;eye<2;++eye) {
        vx_native_vr_eye image={ .resource=(__bridge void *)copies[eye], .width=(uint32_t)copies[eye].width,
            .height=(uint32_t)copies[eye].height, .format=(uint32_t)copies[eye].pixelFormat, .sample_count=1,
            .color_space=VX_NATIVE_VR_COLOR_LINEAR, .u_max=1,.v_max=1 };
        if (vx_native_vr_submit(h.frames,handle,eye,pose.frame_id,pose.pose_id,&image)) goto fail;
        submitted|=1u<<eye;
        if (h.failAfterFirstEye) { h.failAfterFirstEye=NO; goto fail; }
    }
    assert(vx_native_vr_complete(h.frames,handle,0)==0);
    assert(vx_native_vr_complete(h.frames,handle,1)==0);
    h.lastPair=*pair; h.outstanding=NULL; ++h.publishes;
    return XR_SUCCESS;
fail:
    assert(vx_native_vr_cancel(h.frames,handle)==0);
    for (unsigned eye=0;eye<2;++eye) if (submitted & (1u<<eye)) assert(vx_native_vr_complete(h.frames,handle,eye)==0);
    return XR_ERROR_RUNTIME_FAILURE;
}
static void check_pixels(FrameHost *h, const vx_native_vr_frame *frame, unsigned variant) {
    id<MTLBuffer> readback=[h.device newBufferWithLength:1536 options:MTLResourceStorageModeShared]; assert(readback);
    id<MTLCommandBuffer> cb=[h.queue commandBuffer]; id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; assert(blit);
    for(unsigned eye=0;eye<2;++eye) {
        const vx_native_vr_eye *e=&frame->eye[eye];
        id<MTLTexture> texture=(__bridge id<MTLTexture>)e->resource;
        assert(texture.textureType==MTLTextureType2D && texture.arrayLength==1 && e->width==4 && e->height==3);
        assert(e->format==MTLPixelFormatRGBA8Unorm && e->color_space==VX_NATIVE_VR_COLOR_LINEAR && e->sample_count==1);
        near(e->u_min,0); near(e->v_min,0); near(e->u_max,1); near(e->v_max,1);
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(4,3,1) toBuffer:readback destinationOffset:eye*768 destinationBytesPerRow:256 destinationBytesPerImage:768];
    }
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; assert(cb.status==MTLCommandBufferStatusCompleted && !cb.error);
    const unsigned char *data=(const unsigned char *)readback.contents;
    for(unsigned eye=0;eye<2;++eye) for(unsigned y=0;y<3;++y) for(unsigned x=0;x<4;++x) {
        const unsigned char *p=data+eye*768+y*256+x*4;
        assert(p[0]==(variant?(eye?255:0):(eye?0:255)));
        assert(p[1]==(eye?255:0)); assert(p[2]==(variant && !eye?255:0)); assert(p[3]==255);
    }
}
