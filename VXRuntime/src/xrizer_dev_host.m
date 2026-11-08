/* Experimental offscreen Mac host, never a physical tracking/presentation claim. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <time.h>
#include "vx.h"
#include "xrizer_dev_host.h"
#include "xrizer_openvr_exports.h"
#include "xrizer_guest_d3d.h"
#include "native_vr.h"
#include "klepton_native.h"
#include "view_host.h"
#include "session_host.h"
#include "frame_host.h"
#include "input_host.h"
#include "apple_metal_host.h"

@interface VXDevXRHost : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic) KlNativeMetalHost metal;
@property(nonatomic) XrizerMetalHost source;
@property(nonatomic) vx_native_vr *frames;
@property(nonatomic) void *library;
@property(nonatomic) KlNativeSessionEvent event;
@property(nonatomic) KlNativeFrameSample sample;
@property(nonatomic) XrTime inputTime;
@property(nonatomic) uint64_t nextFrame;
@property(nonatomic) unsigned width, height;
@property(nonatomic) BOOL outstanding;
#ifdef VXRT_XRIZER_DEV_AUDIT
@property(nonatomic) BOOL audit;
@property(nonatomic) unsigned published, acquired, released, begins, exits, ends;
@property(nonatomic) uint64_t auditFrame, auditPose;
#endif
@end
@implementation VXDevXRHost
@end
static VXDevXRHost *dev_host;
static XrTime now_ns(void) { struct timespec t; if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0; return (XrTime)t.tv_sec * INT64_C(1000000000) + t.tv_nsec; }
static VXDevXRHost *host(void *p) { return (__bridge VXDevXRHost *)p; }
static void keep(void *p) { if (p) CFRetain(p); }
static void drop(void *p) { if (p) CFRelease(p); }
static XrResult available(void *p) { return p ? XR_SUCCESS : XR_ERROR_RUNTIME_FAILURE; }
static XrResult views(void *p, KlNativeViewConfiguration *out) {
    VXDevXRHost *h=host(p); if (!h || !out) return XR_ERROR_VALIDATION_FAILURE;
    *out=(KlNativeViewConfiguration){.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE,.fov_mutable=XR_FALSE};
    for (unsigned i=0;i<2;i++) out->view[i]=(XrViewConfigurationView){.type=XR_TYPE_VIEW_CONFIGURATION_VIEW,
        .recommendedImageRectWidth=h.width,.maxImageRectWidth=h.width,.recommendedImageRectHeight=h.height,
        .maxImageRectHeight=h.height,.recommendedSwapchainSampleCount=1,.maxSwapchainSampleCount=1};
    return XR_SUCCESS;
}
static XrResult poll_event(void *p,KlNativeSessionEvent *out) {
    VXDevXRHost *h=host(p); if (!h || !out) return XR_ERROR_VALIDATION_FAILURE;
    if (!h.event.type) return XR_EVENT_UNAVAILABLE;
    *out=h.event; h.event=(KlNativeSessionEvent){0};
    if (out->type==KL_NATIVE_SESSION_VISIBLE) h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_FOCUSED,now_ns()};
    return XR_SUCCESS;
}
static XrResult begin_session(void *p,XrTime *out) {
    VXDevXRHost *h=host(p); if (!h || !out || h.event.type || !(*out=now_ns())) return XR_ERROR_RUNTIME_FAILURE;
    h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_VISIBLE,*out};
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) ++h.begins;
#endif
    vx_log("xrizer dev host: synthetic session begun"); return XR_SUCCESS;
}
static XrResult request_exit(void *p) {
    VXDevXRHost *h=host(p); XrTime t=now_ns();
    if (!h || !t || h.outstanding) return XR_ERROR_RUNTIME_FAILURE;
    /* An immediate shutdown may supersede an unconsumed synthetic focus event. */
    h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_STOPPING,t};
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) ++h.exits;
#endif
    vx_log("xrizer dev host: synthetic session exit requested"); return XR_SUCCESS;
}
static XrResult end_session(void *p,XrTime *out) {
    VXDevXRHost *h=host(p); XrTime t=now_ns();
    if (!h || !out || !t || h.outstanding || h.event.type || !h.frames) return XR_ERROR_RUNTIME_FAILURE;
    vx_native_vr_reset(h.frames);
    if (vx_native_vr_destroy(h.frames)) return XR_ERROR_RUNTIME_FAILURE;
    h.frames=NULL; *out=t; h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_EXITING,t};
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) ++h.ends;
#endif
    vx_log("xrizer dev host: session ended with frame queue drained"); return XR_SUCCESS;
}
static XrResult input(void *p,KlNativeInputSample *out) {
    VXDevXRHost *h=host(p); if (!h || !out || !h.inputTime) return XR_ERROR_RUNTIME_FAILURE;
    *out=(KlNativeInputSample){.sample_id=1,.sample_time=h.inputTime,.hand_connected={XR_FALSE,XR_FALSE}}; return XR_SUCCESS;
}
static XrResult wait_frame(void *p,KlNativeFrameSample *out) {
    VXDevXRHost *h=host(p); if (!h || !out || h.outstanding) return XR_ERROR_RUNTIME_FAILURE;
    struct timespec delay={0,11111111};
    while (nanosleep(&delay,&delay)) if (errno!=EINTR) return XR_ERROR_RUNTIME_FAILURE;
    XrTime t=now_ns(); if (!t || h.nextFrame==UINT64_MAX) return XR_ERROR_RUNTIME_FAILURE;
    uint64_t id=++h.nextFrame;
    *out=(KlNativeFrameSample){.ticket=(__bridge void *)h,.frame_id=id,.pose_id=id,.predicted_display_time=t+INT64_C(11111111),
        .predicted_display_period=INT64_C(11111111),.should_render=XR_TRUE,
        .head_location_flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT,
        .local_from_head={.orientation={0,0,0,1},.position={0,1.6f,0}},
        .head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},
        .fov={{-.785398f,.785398f,.785398f,-.785398f},{-.785398f,.785398f,.785398f,-.785398f}}};
    h.sample=*out; h.outstanding=YES;
    if (id<=10 || id%120==0) vx_log("xrizer dev host: synthetic sample frame %llu pose %llu predicted_ns %lld",(unsigned long long)id,(unsigned long long)id,(long long)out->predicted_display_time);
    return XR_SUCCESS;
}
static XrResult cancel_frame(void *p,void *ticket) {
    VXDevXRHost *h=host(p); if (!h || !h.outstanding || ticket!=(__bridge void *)h) return XR_ERROR_RUNTIME_FAILURE;
    vx_log("xrizer dev host: cancelled frame %llu pose %llu",(unsigned long long)h.sample.frame_id,(unsigned long long)h.sample.pose_id);
    h.outstanding=NO; return XR_SUCCESS;
}
static int record_destination(void *p,void *texture,void *cb) {
    VXDevXRHost *h=host(p); KlNativeMetalHost metal=h.metal;
    return kl_apple_metal_record_texture_writes(&metal,texture,cb)==XR_SUCCESS ? 0 : -1;
}
static void *factory(void *p,int *error) {
    VXDevXRHost *h=host(p); void *(*fn)(const char *,int *)=h.library ? dlsym(h.library,"VRClientCoreFactory") : NULL;
    if (!fn) { if (error) *error=100; return NULL; }
    return fn("IVRClientCore_003",error);
}
static void pose_matrix(XrPosef p,float m[16]) {
    float x=p.orientation.x,y=p.orientation.y,z=p.orientation.z,w=p.orientation.w;
    const float v[16]={1-2*y*y-2*z*z,2*x*y+2*w*z,2*x*z-2*w*y,0,2*x*y-2*w*z,1-2*x*x-2*z*z,2*y*z+2*w*x,0,
        2*x*z+2*w*y,2*y*z-2*w*x,1-2*x*x-2*y*y,0,p.position.x,p.position.y,p.position.z,1};
    memcpy(m,v,sizeof v);
}
#include "pose_math.h"
static XrResult publish(void *p,const KlNativeFramePair *pair) {
    VXDevXRHost *h=host(p);
    KlNativeFrameSample sample=h ? h.sample : (KlNativeFrameSample){0};
    if (!h || !pair || !h.frames || !h.outstanding || pair->sample.ticket!=(__bridge void *)h ||
        pair->sample.frame_id!=h.sample.frame_id || pair->sample.pose_id!=h.sample.pose_id ||
        pair->sample.predicted_display_time!=h.sample.predicted_display_time ||
        pair->sample.head_location_flags!=h.sample.head_location_flags ||
        memcmp(&pair->sample.local_from_head,&sample.local_from_head,sizeof sample.local_from_head) ||
        memcmp(pair->sample.head_from_eye,sample.head_from_eye,sizeof sample.head_from_eye) ||
        memcmp(pair->sample.fov,sample.fov,sizeof sample.fov)) return XR_ERROR_RUNTIME_FAILURE;
    id<MTLTexture> copies[2]={nil,nil};
    id<MTLCommandBuffer> cb=[h.queue commandBuffer]; if (!cb) return XR_ERROR_RUNTIME_FAILURE;
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; if (!blit) return XR_ERROR_RUNTIME_FAILURE;
    for (unsigned i=0;i<2;i++) {
        const KlNativeFrameEye *e=&pair->eye[i]; id<MTLTexture> src=(__bridge id<MTLTexture>)e->texture;
        if (!src || src.device!=h.device || src.pixelFormat!=MTLPixelFormatRGBA8Unorm || e->format!=(int64_t)src.pixelFormat || !e->image_lease || e->rect.offset.x<0 || e->rect.offset.y<0 ||
            e->rect.extent.width<=0 || e->rect.extent.height<=0 || e->array_layer>=src.arrayLength ||
            (NSUInteger)e->rect.offset.x+(NSUInteger)e->rect.extent.width>src.width ||
            (NSUInteger)e->rect.offset.y+(NSUInteger)e->rect.extent.height>src.height || src.sampleCount!=1) {
            [blit endEncoding]; return XR_ERROR_RUNTIME_FAILURE;
        }
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
            width:(NSUInteger)e->rect.extent.width height:(NSUInteger)e->rect.extent.height mipmapped:NO];
        d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageShaderRead;
        copies[i]=[h.device newTextureWithDescriptor:d]; if (!copies[i]) { [blit endEncoding]; return XR_ERROR_OUT_OF_MEMORY; }
        [blit copyFromTexture:src sourceSlice:e->array_layer sourceLevel:0 sourceOrigin:MTLOriginMake(e->rect.offset.x,e->rect.offset.y,0)
            sourceSize:MTLSizeMake(e->rect.extent.width,e->rect.extent.height,1) toTexture:copies[i]
            destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    }
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted || cb.error) return XR_ERROR_RUNTIME_FAILURE;
    vx_native_vr_pose pose={.frame_id=pair->sample.frame_id,.pose_id=pair->sample.pose_id,
        .pose_time=(double)pair->sample.predicted_display_time/1e9,
        .tracking_valid=(pair->sample.head_location_flags & (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)) ==
                        (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)};
    pose_matrix(pair->sample.local_from_head,pose.origin_from_head);
    for (unsigned i=0;i<2;i++) {
        pose_matrix(kl_native_pose_relative(pair->sample.local_from_head,pair->eye[i].local_from_render_eye),pose.head_from_eye[i]);
        XrFovf f=pair->eye[i].fov; pose.frustum[i][0]=tanf(f.angleLeft); pose.frustum[i][1]=tanf(f.angleRight);
        pose.frustum[i][2]=-tanf(f.angleUp); pose.frustum[i][3]=-tanf(f.angleDown);
    }
    vx_native_vr_handle frame=0; unsigned submitted=0, completed=0;
    if (vx_native_vr_begin(h.frames,&pose,&frame)) return XR_ERROR_RUNTIME_FAILURE;
    for (unsigned i=0;i<2;i++) {
        vx_native_vr_eye eye={.resource=(__bridge void *)copies[i],.width=(uint32_t)copies[i].width,
            .height=(uint32_t)copies[i].height,.format=(uint32_t)copies[i].pixelFormat,.sample_count=1,
            .color_space=VX_NATIVE_VR_COLOR_LINEAR,.u_max=1,.v_max=1};
        if (vx_native_vr_submit(h.frames,frame,i,pose.frame_id,pose.pose_id,&eye)) goto failed;
        submitted|=1u<<i;
    }
    for (unsigned i=0;i<2;i++) { if (vx_native_vr_complete(h.frames,frame,i)) goto failed; completed|=1u<<i; }
#ifdef VXRT_XRIZER_DEV_AUDIT
    if (h.audit) {
        ++h.published; h.outstanding=NO;
        vx_log("xrizer dev audit: published frame %llu pose %llu",(unsigned long long)pose.frame_id,(unsigned long long)pose.pose_id);
        return XR_SUCCESS;
    }
#endif
    vx_native_vr_frame read;
    if (vx_native_vr_acquire(h.frames,&read)) { vx_native_vr_reset(h.frames); h.outstanding=NO; return XR_SUCCESS; }
    vx_log("xrizer dev host: offscreen fresh pair frame %llu pose %llu (%ux%u, %ux%u), no display",(unsigned long long)pose.frame_id,
        (unsigned long long)pose.pose_id,read.eye[0].width,read.eye[0].height,read.eye[1].width,read.eye[1].height);
    if (vx_native_vr_release(h.frames,read.lease)) return XR_ERROR_RUNTIME_FAILURE;
    vx_native_vr_reset(h.frames); h.outstanding=NO; return XR_SUCCESS;
failed:
    (void)vx_native_vr_cancel(h.frames,frame);
    for (unsigned i=0;i<2;i++) if ((submitted & (1u<<i)) && !(completed & (1u<<i))) (void)vx_native_vr_complete(h.frames,frame,i);
    return XR_ERROR_RUNTIME_FAILURE;
}
int vx_xrizer_dev_host_start(const char *path,unsigned width,unsigned height) {
    if (dev_host || !path || path[0]!='/' || !width || !height || width>4096 || height>4096 ||
        !getenv("XDG_STATE_HOME") || !getenv("XDG_CONFIG_HOME") || !getenv("XDG_CACHE_HOME") || !getenv("XDG_DATA_HOME")) return -1;
    @autoreleasepool {
        VXDevXRHost *h=[VXDevXRHost new]; dev_host=h; /* Keep any installed contexts alive on failure. */
#ifdef VXRT_XRIZER_DEV_AUDIT
        h.audit=getenv("VXRT_XRIZER_DEV_AUDIT") && !strcmp(getenv("VXRT_XRIZER_DEV_AUDIT"),"1");
#endif
        h.width=width; h.height=height; h.device=MTLCreateSystemDefaultDevice(); h.queue=[h.device newCommandQueue];
        h.inputTime=now_ns(); h.frames=vx_native_vr_create(keep,drop);
        if (!h.device || !h.queue || !h.inputTime || !h.frames) return -1;
        KlNativeMetalHost metal;
        if (kl_apple_metal_host_create((__bridge void *)h.device,(__bridge void *)h.queue,&metal)!=XR_SUCCESS) return -1;
        h.metal=metal; KlNativeImageSyncHost sync;
        if (kl_apple_metal_image_sync(&metal,&sync)!=XR_SUCCESS) return -1;
        void *ctx=(__bridge void *)h;
        KlNativeHost system={.version=1,.size=sizeof(system),.context=ctx,.hmd_available=available};
        KlNativeViewHost view={KL_NATIVE_VIEW_HOST_VERSION,sizeof(view),ctx,views};
        KlNativeSessionHost session={KL_NATIVE_SESSION_HOST_VERSION,sizeof(session),ctx,poll_event,begin_session,end_session,request_exit};
        KlNativeFrameHost frame={KL_NATIVE_FRAME_HOST_VERSION,sizeof(frame),ctx,wait_frame,publish,cancel_frame};
        KlNativeInputHost inputHost={KL_NATIVE_INPUT_HOST_VERSION,sizeof(inputHost),ctx,input};
        if (kl_native_configure(&system)!=XR_SUCCESS || kl_native_configure_views(&view)!=XR_SUCCESS ||
            kl_native_configure_metal(&metal)!=XR_SUCCESS || kl_native_configure_image_sync(&sync)!=XR_SUCCESS ||
            kl_native_configure_session(&session)!=XR_SUCCESS || kl_native_configure_frame(&frame)!=XR_SUCCESS ||
            kl_native_configure_input(&inputHost)!=XR_SUCCESS) return -1;
        XrizerMetalHost source;
        if (vx_xrizer_guest_d3d_create((__bridge void *)h.device,(__bridge void *)h.queue,record_destination,ctx,&source)) return -1;
        h.source=source; h.library=dlopen(path,RTLD_NOW|RTLD_LOCAL); if (!h.library) return -1;
        int32_t (*provider)(PFN_xrGetInstanceProcAddr)=dlsym(h.library,"xrizer_configure_openxr_provider");
        int32_t (*graphics)(const XrizerMetalHost *)=dlsym(h.library,"xrizer_configure_metal_host");
        if (!provider || !graphics || !dlsym(h.library,"VRClientCoreFactory") ||
            provider(kl_native_get_instance_proc_addr) || graphics(&source)) return -1;
        h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_READY,now_ns()};
        if (!h.event.time || vx_xrizer_openvr_configure(factory,ctx)) return -1;
        vx_log("xrizer dev host: offscreen synthetic stationary head, disconnected controllers, %ux%u, CLOCK_MONOTONIC; no physical tracking or display",width,height);
        return 0;
    }
}
#ifdef VXRT_XRIZER_DEV_AUDIT
int vx_xrizer_dev_audit_acquire(vx_native_vr_frame *out) {
    VXDevXRHost *h=dev_host;
    if (!h || !h.audit || !h.frames || !out || h.acquired!=h.released || h.published!=h.acquired+1) return -1;
    if (vx_native_vr_acquire(h.frames,out)) return -1;
    ++h.acquired;
    int valid=out->pose.frame_id==h.sample.frame_id && out->pose.pose_id==h.sample.pose_id &&
        out->pose.frame_id>h.auditFrame && out->pose.pose_id>h.auditPose;
    if (!valid) { (void)vx_native_vr_release(h.frames,out->lease); ++h.released; return -1; }
    h.auditFrame=out->pose.frame_id; h.auditPose=out->pose.pose_id;
    return 0;
}
int vx_xrizer_dev_audit_release(uint64_t lease) {
    VXDevXRHost *h=dev_host;
    if (!h || !h.audit || !h.frames || h.acquired!=h.released+1 || vx_native_vr_release(h.frames,lease)) return -1;
    ++h.released; vx_native_vr_reset(h.frames); return 0;
}
int vx_xrizer_dev_audit_finish(void) {
    VXDevXRHost *h=dev_host; uint64_t acquired=0,released=0,copied=0;
    XrizerMetalHost source=h ? h.source : (XrizerMetalHost){0};
    if (!h || !h.audit || h.frames || h.outstanding || h.published!=2 || h.acquired!=2 || h.released!=2 ||
        h.begins!=1 || h.exits!=1 || h.ends!=1 || vx_xrizer_guest_d3d_counts(&source,&acquired,&released,&copied) ||
        acquired!=released || copied!=4) return -1;
    vx_log("xrizer dev audit: drained pairs %u reader leases %u/%u source leases %llu/%llu copies %llu lifecycle %u/%u/%u",
        h.published,h.acquired,h.released,(unsigned long long)acquired,(unsigned long long)released,(unsigned long long)copied,h.begins,h.exits,h.ends);
    return 0;
}
#endif
