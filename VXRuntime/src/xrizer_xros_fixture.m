/* Owned simulator fixture only: one existing compositor, injected head/input. */
#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR && !defined(VX_XROS_FIXTURE_SCAN)
#error "xrizer xros fixture is simulator-only"
#endif
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "xrizer_xros_fixture.h"
#include "xrizer_xros_optics.h"
#include "xrizer_xros_fixture_guest.h"
#include "xrizer_xros_host.h"
#include "xrizer_guest_d3d.h"
#include "xrizer_openvr_exports.h"
extern int32_t xrizer_configure_openxr_provider(PFN_xrGetInstanceProcAddr);
extern int32_t xrizer_configure_metal_host(const XrizerMetalHost *);
extern void *VRClientCoreFactory(const char *, int *);
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready_cond=PTHREAD_COND_INITIALIZER;
static vx_xros_xrizer_host *host;
static XrizerMetalHost source;
static id<MTLDevice> fixture_device;
static id<MTLCommandQueue> fixture_queue;
static uint64_t last_verified_frame;
void vx_log(const char *, ...);
static int ready, failed, draining, stopping;
static unsigned readers, begin_count, end_count, exit_count;
static uint64_t sample_id, frame_id, geometry_id;
/* Bounded history of accepted injected offers; protected by lock. */
static uint64_t offered_ids[1024];
static XrTime last_prediction, last_event;
static XrTime now_ns(void) { struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t))return 0; return (XrTime)t.tv_sec*INT64_C(1000000000)+t.tv_nsec; }
static XrTime event_time_locked(void) { XrTime t=now_ns(); if(t<=last_event)t=last_event+1;last_event=t;return t; }
static XrTime event_time(void) { pthread_mutex_lock(&lock);XrTime t=event_time_locked();pthread_mutex_unlock(&lock);return t; }
static XrResult begin(void *ctx,XrTime *time) {
    (void)ctx; pthread_mutex_lock(&lock);
    if(failed) { pthread_mutex_unlock(&lock); return XR_ERROR_SESSION_LOST; }
    ++begin_count; *time=event_time_locked();
    int error=vx_xros_xrizer_event(host,(KlNativeSessionEvent){KL_NATIVE_SESSION_VISIBLE,event_time_locked()}) ||
              vx_xros_xrizer_event(host,(KlNativeSessionEvent){KL_NATIVE_SESSION_FOCUSED,event_time_locked()});
    pthread_mutex_unlock(&lock);return error ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS;
}
static XrResult end(void *ctx,XrTime *time) {
    (void)ctx; *time=event_time(); ++end_count;
    return vx_xros_xrizer_event(host,(KlNativeSessionEvent){KL_NATIVE_SESSION_EXITING,event_time()}) ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS;
}
static XrResult request_exit(void *ctx) {
    (void)ctx; pthread_mutex_lock(&lock); ++exit_count; int error=0;
    if(!stopping) { error=vx_xros_xrizer_event(host,(KlNativeSessionEvent){KL_NATIVE_SESSION_STOPPING,event_time_locked()}); if(!error)stopping=1; }
    pthread_mutex_unlock(&lock);return error ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS;
}
static XrResult input(void *ctx,KlNativeInputSample *sample) {
    (void)ctx; pthread_mutex_lock(&lock); uint64_t id=++sample_id; pthread_mutex_unlock(&lock);
    *sample=(KlNativeInputSample){.sample_id=id,.sample_time=now_ns(),.hand_connected={XR_FALSE,XR_FALSE}};
    return sample->sample_time>0 ? XR_SUCCESS : XR_ERROR_RUNTIME_FAILURE;
}
int vx_xros_fixture_enabled(void) { const char *v=getenv("VXRT_XRIZER_XROS_FIXTURE"); return v && !strcmp(v,"1"); }
int vx_xros_fixture_start(void *device,void *queue) {
    if(!vx_xros_fixture_enabled() || !device || !queue)return -1;
    pthread_mutex_lock(&lock); int used=host || failed; pthread_mutex_unlock(&lock); if(used)return -1;
    vx_xros_xrizer_platform platform={VX_XROS_XRIZER_API_VERSION,sizeof(platform),NULL,begin,end,request_exit,input};
    vx_xros_xrizer_host *created=vx_xros_xrizer_create(VX_XROS_XRIZER_INJECTED_TEST,device,queue,&platform);
    if(!created || vx_xrizer_guest_d3d_create(device,queue,vx_xros_xrizer_record_destination,created,&source))goto fail;
    host=created; fixture_device=(__bridge id<MTLDevice>)device; fixture_queue=(__bridge id<MTLCommandQueue>)queue;
    vx_xros_xrizer_static_api api={VX_XROS_XRIZER_API_VERSION,sizeof(api),xrizer_configure_openxr_provider,
        xrizer_configure_metal_host,VRClientCoreFactory,vx_xrizer_openvr_configure};
    if(vx_xros_xrizer_register(created,&api,&source))goto fail;
    return 0;
fail:
    pthread_mutex_lock(&lock);failed=1;pthread_cond_broadcast(&ready_cond);pthread_mutex_unlock(&lock);return -1;
}
int vx_xros_fixture_offer(uint32_t width,uint32_t height,const float eyes[32],const float tangents[8],double prediction) {
    if(!width || !height || !eyes || !tangents || !isfinite(prediction) || prediction<=0 || prediction>(double)INT64_MAX/1e9)return -1;
    XrTime predicted=(XrTime)(prediction*1e9);
    KlNativeViewGeometry geometry={.version=KL_NATIVE_VIEW_GEOMETRY_VERSION,.struct_size=sizeof(geometry)};
    float orientation[2][4], position[2][3], fov[2][4];
    if(vx_xros_optics_from_tangents(eyes,tangents,orientation,position,fov))return -1;
    for(unsigned i=0;i<2;i++) {
        geometry.head_from_eye[i].orientation=(XrQuaternionf){orientation[i][0],orientation[i][1],orientation[i][2],orientation[i][3]};
        geometry.head_from_eye[i].position=(XrVector3f){position[i][0],position[i][1],position[i][2]};
        geometry.fov[i]=(XrFovf){fov[i][0],fov[i][1],fov[i][2],fov[i][3]};
    }
    KlNativeViewConfiguration view={.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE};
    for(unsigned i=0;i<2;i++)view.view[i]=(XrViewConfigurationView){.type=XR_TYPE_VIEW_CONFIGURATION_VIEW,
        .recommendedImageRectWidth=width,.maxImageRectWidth=width,.recommendedImageRectHeight=height,.maxImageRectHeight=height,
        .recommendedSwapchainSampleCount=1,.maxSwapchainSampleCount=1};
    pthread_mutex_lock(&lock);
    if(!host || failed || (last_prediction && predicted<=last_prediction)) { pthread_mutex_unlock(&lock);return -1; }
    geometry.geometry_id=++geometry_id;
    if(vx_xros_xrizer_surface(host,1,&view) || vx_xros_xrizer_geometry(host,&geometry)) { pthread_mutex_unlock(&lock);return -1; }
    if(!ready) {
        if(vx_xros_xrizer_event(host,(KlNativeSessionEvent){KL_NATIVE_SESSION_READY,event_time_locked()})) { pthread_mutex_unlock(&lock);return -1; }
        ready=1;pthread_cond_broadcast(&ready_cond);
    }
    XrTime previous=last_prediction;last_prediction=predicted;
    if(!previous) { pthread_mutex_unlock(&lock);return 0; }
    uint64_t id=++frame_id;
    KlNativeFrameSample sample={.frame_id=id,.pose_id=id,.predicted_display_time=predicted,
        .predicted_display_period=predicted-previous,.should_render=XR_TRUE,
        .head_location_flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT,
        .local_from_head={.orientation={0,0,0,1}}};
    memcpy(sample.head_from_eye,geometry.head_from_eye,sizeof sample.head_from_eye);memcpy(sample.fov,geometry.fov,sizeof sample.fov);
    int result=vx_xros_xrizer_offer(host,&sample);
    if(!result)offered_ids[id % 1024]=id;
    pthread_mutex_unlock(&lock);return result;
}
int vx_xros_fixture_surface_lost(void) {
    pthread_mutex_lock(&lock);
    if(failed){pthread_mutex_unlock(&lock);return -1;}
    failed=1;ready=0;draining=1;int send=host && begin_count && !stopping;int error=0;
    if(host)error=vx_xros_xrizer_surface(host,0,NULL);
    if(!error && send) { error=vx_xros_xrizer_event(host,(KlNativeSessionEvent){KL_NATIVE_SESSION_STOPPING,event_time_locked()});if(!error)stopping=1; }
    pthread_cond_broadcast(&ready_cond);pthread_mutex_unlock(&lock);
    vx_log("xrizer xros fixture: compositor surface lost; one-way stop, resume unavailable");
    return error ? -1 : 0;
}
int WINAPI vx_xros_fixture_inject_loss(void) { return vx_xros_fixture_surface_lost(); }
int vx_xros_fixture_wait_ready(void) {
    struct timespec deadline;if(clock_gettime(CLOCK_REALTIME,&deadline))return -1;deadline.tv_sec+=30;
    pthread_mutex_lock(&lock);int rc=0;while(!ready && !failed && !rc)rc=pthread_cond_timedwait(&ready_cond,&lock,&deadline);
    int ok=ready && !failed;pthread_mutex_unlock(&lock);return ok?0:-1;
}
int vx_xros_fixture_acquire(vx_native_vr_frame *frame) {
    pthread_mutex_lock(&lock);int r=host && !draining ? vx_xros_xrizer_acquire(host,frame) : -1;
    if(!r)++readers;pthread_mutex_unlock(&lock);return r;
}
int vx_xros_fixture_release(uint64_t lease) {
    pthread_mutex_lock(&lock);int r=host && readers ? vx_xros_xrizer_release(host,lease) : -1;
    if(!r){--readers;pthread_cond_broadcast(&ready_cond);}pthread_mutex_unlock(&lock);return r;
}
int WINAPI vx_xros_fixture_prepare_shutdown(void) {
    struct timespec deadline;if(clock_gettime(CLOCK_REALTIME,&deadline))return -1;deadline.tv_sec+=5;
    pthread_mutex_lock(&lock);draining=1;int rc=0;while(readers && !rc)rc=pthread_cond_timedwait(&ready_cond,&lock,&deadline);
    int ok=!readers;pthread_mutex_unlock(&lock);return ok?0:-1;
}
int WINAPI vx_xros_fixture_verify_shutdown(void) {
    uint64_t acquired=0,released=0,copied=0;
    float eyes[32]={0};for(unsigned eye=0;eye<2;eye++)for(unsigned i=0;i<4;i++)eyes[eye*16+i*5]=1;
    const float tangents[8]={-1,1,-1,1,-1,1,-1,1};
    int resumed=vx_xros_fixture_offer(8,8,eyes,tangents,(double)now_ns()/1e9+10);
    int ok=begin_count==1 && end_count==1 && exit_count==1 && resumed==-1 &&
        !vx_xrizer_guest_d3d_counts(&source,&acquired,&released,&copied) && acquired==released && copied==4;
    vx_log("xrizer xros fixture: drain lifecycle=%u/%u/%u source leases=%llu/%llu copies=%llu resume=%d %s",
        begin_count,exit_count,end_count,(unsigned long long)acquired,(unsigned long long)released,(unsigned long long)copied,resumed,ok?"pass":"fail");
    return ok?0:-1;
}

/* Reads back the adapter's completed source pair, not a compositor drawable. */
int WINAPI vx_xros_fixture_verify_pair(unsigned variant) {
    if(variant>1 || !fixture_device || !fixture_queue)return -1;
    vx_native_vr_frame frame={0}; int acquired=0;
    for(unsigned n=0;n<3000;n++) {
        if(!vx_xros_fixture_acquire(&frame)) {
            if(frame.pose.frame_id>last_verified_frame){acquired=1;break;}
            (void)vx_xros_fixture_release(frame.lease);
        }
        usleep(1000);
    }
    if(!acquired)return -1;
    pthread_mutex_lock(&lock);
    int offered=frame.pose.frame_id && offered_ids[frame.pose.frame_id % 1024]==frame.pose.frame_id;
    pthread_mutex_unlock(&lock);
    /* Equality is specific to this fixture's injected sample, not a production invariant. */
    int ok=frame.pose.tracking_valid && offered && frame.pose.pose_id==frame.pose.frame_id;
    id<MTLBuffer> data=[fixture_device newBufferWithLength:1536 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[fixture_queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    if(!data || !cb || !blit)ok=0;
    if(ok) for(unsigned i=0;i<2;i++) {
        const vx_native_vr_eye *e=&frame.eye[i];id<MTLTexture> t=(__bridge id<MTLTexture>)e->resource;
        if(!t || e->width!=4 || e->height!=3 || e->format!=MTLPixelFormatRGBA8Unorm || t.device!=fixture_device){ok=0;break;}
        [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,3,1)
            toBuffer:data destinationOffset:i*768 destinationBytesPerRow:256 destinationBytesPerImage:768];
    }
    if(blit)[blit endEncoding];
    if(ok){[cb commit];[cb waitUntilCompleted];ok=cb.status==MTLCommandBufferStatusCompleted && !cb.error;}
    if(ok) for(unsigned i=0;i<2;i++)for(unsigned y=0;y<3;y++)for(unsigned x=0;x<4;x++) {
        const unsigned char *p=(const unsigned char *)data.contents+i*768+y*256+x*4;
        /* The submitted bounds crop starts at source (2,1); independent
         * coordinate expectations detect wrong origins as well as eye swaps. */
        unsigned source_x=x+2,source_y=y+1;
        if(p[0]!=40+variant*80+source_x*11+source_y*3 || p[1]!=20+i*130+source_x*3+source_y*2 ||
           p[2]!=30+variant*70+i*50+source_x+source_y || p[3]!=255)ok=0;
    }
    if(ok)last_verified_frame=frame.pose.frame_id;
    vx_log("xrizer xros fixture: provider pair %u frame=%llu pose=%llu readback=%s",variant,
        (unsigned long long)frame.pose.frame_id,(unsigned long long)frame.pose.pose_id,ok?"pass":"fail");
    if(vx_xros_fixture_release(frame.lease))ok=0;
    return ok?0:-1;
}
#ifdef __aarch64__
#include "thunks/xrizer_xros_fixture.m.inc"
#endif
