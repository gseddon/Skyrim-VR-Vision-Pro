/* Owned joined-AOT host support. Calls below remain native Darwin ABI. */
#include "xrizer_guest_host.h"
#include "openvr-1.0.17.h"
#include "metal_frame_host.inc"
#include <dlfcn.h>
extern "C" {
#include "view_host.h"
#include "input_host.h"
#include "metal_host_bridge.h"
}
@interface SourceEye : NSObject
@property(nonatomic,strong) id<MTLTexture> texture;
@property(nonatomic,strong) id<MTLCommandBuffer> producer;
@property(nonatomic) uint64_t frameID,poseID;
@property(nonatomic) void *token;
@end
@implementation SourceEye
@end
@interface StereoHost : FrameHost
@property(nonatomic) KlNativeMetalHost resources;
@property(nonatomic,strong) NSArray<SourceEye *> *sources;
@property(nonatomic) XrTime clockBase;
@property(nonatomic) unsigned begins,ends,exits,sourceAcquires,sourceReleases,sourceCopies;
@property(nonatomic) KlNativeImageSyncHost actualSync;
@end
@implementation StereoHost
@end
static unsigned ticket_tokens[8];
static unsigned sessions_created,sessions_destroyed,input_samples;
static unsigned image_acquires,image_waits,image_releases,copy_failures,write_failures,publish_failures;
static bool fail_wait_once,fail_copy_once,fail_write_once,fail_publish_once;
static XrSession original_session;
static PFN_xrCreateSession actual_create_session;
static PFN_xrDestroySession actual_destroy_session;
static PFN_xrAcquireSwapchainImage actual_acquire_image;
static PFN_xrWaitSwapchainImage actual_wait_image;
static PFN_xrReleaseSwapchainImage actual_release_image;
static XrResult XRAPI_CALL trace_acquire_image(XrSwapchain swap,const XrSwapchainImageAcquireInfo *info,uint32_t *index){
    ++image_acquires;return actual_acquire_image(swap,info,index);
}
static XrResult XRAPI_CALL trace_wait_image(XrSwapchain swap,const XrSwapchainImageWaitInfo *info){
    ++image_waits;if(fail_wait_once){fail_wait_once=false;puts("injected raw image wait timeout: acquisition remains outstanding");return XR_TIMEOUT_EXPIRED;}
    return actual_wait_image(swap,info);
}
static XrResult XRAPI_CALL trace_release_image(XrSwapchain swap,const XrSwapchainImageReleaseInfo *info){
    ++image_releases;return actual_release_image(swap,info);
}
static XrResult XRAPI_CALL trace_create_session(XrInstance instance,const XrSessionCreateInfo *info,XrSession *session){
    XrResult result=actual_create_session(instance,info,session);
    if(result==XR_SUCCESS){++sessions_created;assert(sessions_created==1);original_session=*session;}
    printf("provider session create: result=%d identity=%p\n",result,(void *)(result==XR_SUCCESS?*session:XR_NULL_HANDLE));return result;
}
static XrResult XRAPI_CALL trace_destroy_session(XrSession session){
    assert(session==original_session);XrResult result=actual_destroy_session(session);
    if(result==XR_SUCCESS)++sessions_destroyed;return result;
}
static XrResult XRAPI_CALL trace_entry(XrInstance instance,const char *name,PFN_xrVoidFunction *out){
    XrResult result=kl_native_get_instance_proc_addr(instance,name,out);
    if(result==XR_SUCCESS && !strcmp(name,"xrCreateSession")){actual_create_session=(PFN_xrCreateSession)*out;*out=(PFN_xrVoidFunction)trace_create_session;}
    if(result==XR_SUCCESS && !strcmp(name,"xrDestroySession")){actual_destroy_session=(PFN_xrDestroySession)*out;*out=(PFN_xrVoidFunction)trace_destroy_session;}
    if(result==XR_SUCCESS && !strcmp(name,"xrAcquireSwapchainImage")){actual_acquire_image=(PFN_xrAcquireSwapchainImage)*out;*out=(PFN_xrVoidFunction)trace_acquire_image;}
    if(result==XR_SUCCESS && !strcmp(name,"xrWaitSwapchainImage")){actual_wait_image=(PFN_xrWaitSwapchainImage)*out;*out=(PFN_xrVoidFunction)trace_wait_image;}
    if(result==XR_SUCCESS && !strcmp(name,"xrReleaseSwapchainImage")){actual_release_image=(PFN_xrReleaseSwapchainImage)*out;*out=(PFN_xrVoidFunction)trace_release_image;}
    return result;
}
static StereoHost *stereo(void *ctx){return (__bridge StereoHost *)ctx;}
static XrResult wait_available(void *ctx,void *lease,XrDuration timeout){
    KlNativeImageSyncHost original=stereo(ctx).actualSync;return original.wait_available(original.context,lease,timeout);
}
static XrResult complete_writes(void *ctx,void *lease){
    if(fail_write_once){fail_write_once=false;++write_failures;puts("injected producer completion failure: provider release refused");return XR_ERROR_RUNTIME_FAILURE;}
    KlNativeImageSyncHost original=stereo(ctx).actualSync;return original.complete_writes(original.context,lease);
}
static XrResult publish_pair(void *ctx,const KlNativeFramePair *pair){
    if(fail_publish_once){fail_publish_once=false;++publish_failures;puts("injected end-frame publication failure: frame ticket retained");return XR_ERROR_RUNTIME_FAILURE;}
    return publish_host(ctx,pair);
}
static XrResult available(void *ctx){(void)ctx;return XR_SUCCESS;}
static XrResult view_configuration(void *ctx,KlNativeViewConfiguration *out){
    (void)ctx;*out={.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE,.fov_mutable=XR_FALSE};
    for(unsigned i=0;i<2;++i)out->view[i]={.type=XR_TYPE_VIEW_CONFIGURATION_VIEW,.recommendedImageRectWidth=8,.maxImageRectWidth=8,
        .recommendedImageRectHeight=8,.maxImageRectHeight=8,.recommendedSwapchainSampleCount=1,.maxSwapchainSampleCount=1};
    return XR_SUCCESS;
}
static XrResult input_snapshot(void *ctx,KlNativeInputSample *sample){
    StereoHost *h=stereo(ctx); ++input_samples;
    *sample={.sample_id=1,.sample_time=h.clockBase+30,.hand_connected={XR_FALSE,XR_FALSE}}; return XR_SUCCESS;
}
static XrResult poll_host(void *ctx,KlNativeSessionEvent *event){
    StereoHost *h=stereo(ctx);if(!h.event.type)return XR_EVENT_UNAVAILABLE;
    *event=h.event;h.event={};
    if(event->type==KL_NATIVE_SESSION_VISIBLE) h.event={KL_NATIVE_SESSION_FOCUSED,h.clockBase+22};
    return XR_SUCCESS;
}
static XrResult begin_host(void *ctx,XrTime *time){StereoHost *h=stereo(ctx);++h.begins;*time=h.clockBase+20;h.event={KL_NATIVE_SESSION_VISIBLE,h.clockBase+21};return XR_SUCCESS;}
static XrResult request_exit(void *ctx){
    StereoHost *h=stereo(ctx);assert(!h.event.type && !h.outstanding);++h.exits;
    h.event={KL_NATIVE_SESSION_STOPPING,h.clockBase+INT64_C(100000000)};return XR_SUCCESS;
}
static XrResult end_host(void *ctx,XrTime *time){
    StereoHost *h=stereo(ctx);assert(!h.outstanding && vx_native_vr_destroy(h.frames)==0);h.frames=NULL;
    ++h.ends;*time=h.clockBase+INT64_C(100000001);
    h.event={KL_NATIVE_SESSION_EXITING,h.clockBase+INT64_C(100000002)};return XR_SUCCESS;
}
static XrResult wait_host(void *ctx,KlNativeFrameSample *sample){
    StereoHost *h=stereo(ctx);assert(!h.outstanding && h.waits<7);unsigned n=++h.waits;
    *sample={.ticket=&ticket_tokens[n],.frame_id=100+n,.pose_id=200+n,
        .predicted_display_time=h.clockBase+(XrTime)n*INT64_C(10000000),.predicted_display_period=INT64_C(10000000),.should_render=XR_TRUE,
        .head_location_flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT|XR_SPACE_LOCATION_POSITION_TRACKED_BIT,
        .local_from_head={.orientation={0,.7071067811865475f,0,.7071067811865475f},.position={1,2,3}},
        .head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},
        .fov={{-.7f,.8f,.9f,-.6f},{-.73f,.82f,.9f,-.6f}},.stage_valid=XR_TRUE,
        .local_from_stage={.orientation={0,1,0,0},.position={4,5,6}}};
    sample->local_from_head.position.x=(float)n;
    h.sample=*sample;h.outstanding=sample->ticket;
    printf("host sample: frame=%llu pose=%llu predicted_ns=%lld; latched before source GPU producer\n",
        (unsigned long long)sample->frame_id,(unsigned long long)sample->pose_id,(long long)sample->predicted_display_time);
    return XR_SUCCESS;
}
static XrResult cancel_host(void *ctx,void *ticket){
    StereoHost *h=stereo(ctx);assert(ticket && h.outstanding==ticket);h.outstanding=NULL;++h.cancels;return XR_SUCCESS;
}
static int32_t acquire_source(void *ctx,void *handle,XrizerMetalTexture *out){
    StereoHost *h=stereo(ctx);if(!out)return -1;*out={};
    for(SourceEye *source in h.sources)if(source.token==handle){
        assert(source.texture && source.producer && source.frameID==h.sample.frame_id && source.poseID==h.sample.pose_id);
        *out={.texture=(__bridge void *)source.texture,.device=(__bridge void *)h.device,.lease=(__bridge_retained void *)source,
            .format=(int64_t)source.texture.pixelFormat,.width=8,.height=8,.sample_count=1};
        ++h.sourceAcquires;return 0;
    }
    return -1;
}
static void release_source(void *ctx,void *lease){assert(lease);++stereo(ctx).sourceReleases;(void)CFBridgingRelease(lease);}
static int32_t copy_source(void *ctx,const XrizerMetalCopy *request){
    StereoHost *h=stereo(ctx);if(!request || !request->source || !request->source->lease || request->eye>1)return -1;
    SourceEye *source=(__bridge SourceEye *)request->source->lease;
    id<MTLTexture> dst=(__bridge id<MTLTexture>)request->destination;
    assert((__bridge void *)source.texture==request->source->texture && source.texture.device==h.device);
    assert(source.frameID==h.sample.frame_id && source.poseID==h.sample.pose_id);
    if(fail_copy_once){fail_copy_once=false;++copy_failures;puts("injected source copy failure: no target GPU copy submitted");return -1;}
    if(!dst || dst.device!=h.device || dst.textureType!=MTLTextureType2DArray || dst.arrayLength!=2 ||
        dst.pixelFormat!=MTLPixelFormatRGBA8Unorm || dst.sampleCount!=1 || request->color_space!=vr::ColorSpace_Linear ||
        request->x!=2 || request->y!=1 || request->width!=4 || request->height!=3)return -1;
    [source.producer waitUntilCompleted];
    if(source.producer.status!=MTLCommandBufferStatusCompleted || source.producer.error)return -1;
    id<MTLCommandBuffer> cb=[h.queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];if(!blit)return -1;
    [blit copyFromTexture:source.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(request->x,request->y,0)
        sourceSize:MTLSizeMake(request->width,request->height,1) toTexture:dst destinationSlice:request->eye
        destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];[cb commit];
    KlNativeMetalHost resources=h.resources;
    if(kl_apple_metal_record_texture_writes(&resources,request->destination,(__bridge void *)cb)!=XR_SUCCESS)return -1;
    [cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted || cb.error)return -1;
    ++h.sourceCopies;return 0;
}
static void produce_source(StereoHost *h,unsigned eye,unsigned variant){
    SourceEye *source=h.sources[eye];source.frameID=h.sample.frame_id;source.poseID=h.sample.pose_id;
    id<MTLBuffer> upload=[h.device newBufferWithLength:768 options:MTLResourceStorageModeShared];assert(upload);
    unsigned char *pixels=(unsigned char *)upload.contents;memset(pixels,0,768);
    for(unsigned y=0;y<3;++y)for(unsigned x=0;x<4;++x){
        unsigned char *p=pixels+y*256+x*4;p[0]=variant?(eye?255:0):(eye?0:255);p[1]=eye?255:0;p[2]=variant && !eye?255:0;p[3]=255;
    }
    id<MTLCommandBuffer> cb=[h.queue commandBuffer];assert(cb);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=source.texture;
    pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(.25,.25,.25,1);
    id<MTLRenderCommandEncoder> render=[cb renderCommandEncoderWithDescriptor:pass];assert(render);[render endEncoding];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];assert(blit);
    [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:768 sourceSize:MTLSizeMake(4,3,1)
        toTexture:source.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(2,1,0)];
    [blit endEncoding];[cb commit];source.producer=cb;
}
static void check_pair(StereoHost *h,const vx_native_vr_frame *frame,unsigned variant){
    check_pixels(h,frame,variant);KlNativeFrameSample sample=h.sample;
    assert(frame->pose.frame_id==sample.frame_id && frame->pose.pose_id==sample.pose_id && frame->pose.tracking_valid);
    assert(fabs(frame->pose.pose_time-(double)sample.predicted_display_time/1e9)<1e-9);
    const float origin[16]={0,0,-1,0,0,1,0,0,1,0,0,0,sample.local_from_head.position.x,2,3,1};
    for(unsigned i=0;i<16;++i)near(frame->pose.origin_from_head[i],origin[i]);
    for(unsigned eye=0;eye<2;++eye){
        const float expected[16]={1,0,0,0,0,1,0,0,0,0,1,0,eye?.032f:-.032f,0,0,1};
        for(unsigned i=0;i<16;++i)near(frame->pose.head_from_eye[eye][i],expected[i]);
        near(frame->pose.frustum[eye][0],tanf(eye?-.73f:-.7f));near(frame->pose.frustum[eye][1],tanf(eye?.82f:.8f));
        near(frame->pose.frustum[eye][2],-tanf(.9f));near(frame->pose.frustum[eye][3],-tanf(-.6f));
    }
}

struct vx_xrizer_guest_host { void *object; void *library; bool external; bool finished; };
static vx_xrizer_guest_host *joined;
static StereoHost *joined_object(vx_xrizer_guest_host *fixture){assert(fixture && fixture==joined && !fixture->finished);return stereo(fixture->object);}
int vx_xrizer_guest_host_create(const char *path,const XrizerMetalHost *external,vx_xrizer_guest_host **out){
    if(!path || !out || joined || !getenv("XDG_STATE_HOME") || !getenv("XDG_CONFIG_HOME"))return -1;
    *out=NULL;
    @autoreleasepool {
        StereoHost *h=[StereoHost new];
        h.device=external?(__bridge id<MTLDevice>)external->device:MTLCreateSystemDefaultDevice();
        h.queue=external?(__bridge id<MTLCommandQueue>)external->command_queue:[h.device newCommandQueue];
        if(!h.device || !h.queue || h.queue.device!=h.device)return -1;
        h.frames=vx_native_vr_create(keep_texture,drop_texture);assert(h.frames);h.clockBase=monotonic_ns();
        KlNativeMetalHost resources;assert(kl_apple_metal_host_create((__bridge void *)h.device,(__bridge void *)h.queue,&resources)==XR_SUCCESS);h.resources=resources;
        KlNativeImageSyncHost sync;assert(kl_apple_metal_image_sync(&resources,&sync)==XR_SUCCESS);h.actualSync=sync;
        void *ctx=(__bridge void *)h;
        KlNativeHost system={.version=1,.size=sizeof(system),.context=ctx,.hmd_available=available};
        KlNativeViewHost views={KL_NATIVE_VIEW_HOST_VERSION,sizeof(views),ctx,view_configuration};
        KlNativeSessionHost session={.version=KL_NATIVE_SESSION_HOST_VERSION,.struct_size=sizeof(session),.context=ctx,
            .poll_event=poll_host,.begin_session=begin_host,.end_session=end_host,.request_exit=request_exit};
        KlNativeFrameHost frames={KL_NATIVE_FRAME_HOST_VERSION,sizeof(frames),ctx,wait_host,publish_pair,cancel_host};
        KlNativeInputHost input={KL_NATIVE_INPUT_HOST_VERSION,sizeof(input),ctx,input_snapshot};
        assert(kl_native_configure_input(&input)==XR_SUCCESS);
        sync={KL_NATIVE_IMAGE_SYNC_HOST_VERSION,sizeof(sync),ctx,wait_available,complete_writes};
        assert(kl_native_configure(&system)==XR_SUCCESS && kl_native_configure_metal(&resources)==XR_SUCCESS && kl_native_configure_views(&views)==XR_SUCCESS);
        assert(kl_native_configure_session(&session)==XR_SUCCESS && kl_native_configure_image_sync(&sync)==XR_SUCCESS && kl_native_configure_frame(&frames)==XR_SUCCESS);
        if(!external){
            NSMutableArray<SourceEye *> *sources=[NSMutableArray new];static unsigned tokens[2];
            for(unsigned eye=0;eye<2;++eye){
                SourceEye *s=[SourceEye new];MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
                d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;s.texture=[h.device newTextureWithDescriptor:d];assert(s.texture);
                s.token=&tokens[eye];[sources addObject:s];
            }
            h.sources=sources;
        }
        h.event={KL_NATIVE_SESSION_READY,h.clockBase+10};
        void *library=dlopen(path,RTLD_NOW|RTLD_LOCAL);if(!library){fprintf(stderr,"%s\n",dlerror());abort();}
        auto configure_provider=(int32_t(*)(PFN_xrGetInstanceProcAddr))dlsym(library,"xrizer_configure_openxr_provider");
        auto configure_metal=(int32_t(*)(const XrizerMetalHost *))dlsym(library,"xrizer_configure_metal_host");
        assert(configure_provider && configure_metal && dlsym(library,"VRClientCoreFactory"));
        XrizerMetalHost bridge={.abi_version=1,.struct_size=sizeof(bridge),.context=ctx,.device=(__bridge void *)h.device,
            .command_queue=(__bridge void *)h.queue,.acquire=acquire_source,.copy_complete=copy_source,.release=release_source};
        if(external)bridge=*external;
        assert(configure_provider(trace_entry)==0 && configure_metal(&bridge)==0);
        joined=new vx_xrizer_guest_host{(__bridge_retained void *)h,library,external!=NULL,false};*out=joined;
        return 0;
    }
}
void *vx_xrizer_guest_host_factory(vx_xrizer_guest_host *fixture,const char *version,int *error){
    (void)joined_object(fixture);auto factory=(void *(*)(const char *,int *))dlsym(fixture->library,"VRClientCoreFactory");return factory(version,error);
}
void vx_xrizer_guest_host_get_stats(vx_xrizer_guest_host *fixture,vx_xrizer_guest_host_stats *out){
    StereoHost *h=joined_object(fixture);assert(out);
    *out={.waits=h.waits,.publishes=h.publishes,.cancels=h.cancels,.begins=h.begins,.exits=h.exits,.ends=h.ends,
        .sessions_created=sessions_created,.sessions_destroyed=sessions_destroyed,
        .source_acquires=h.sourceAcquires,.source_releases=h.sourceReleases,.source_copies=h.sourceCopies,.input_samples=input_samples,
        .frame_id=h.sample.frame_id,.pose_id=h.sample.pose_id,.predicted_display_time=h.sample.predicted_display_time,
        .outstanding=h.outstanding?1u:0u};
}
int vx_xrizer_guest_host_prepare_native(vx_xrizer_guest_host *fixture,uint32_t variant){
    StereoHost *h=joined_object(fixture);if(fixture->external || !h.outstanding || variant>1)return -1;
    for(unsigned eye=0;eye<2;++eye)produce_source(h,eye,variant);return 0;
}
void *vx_xrizer_guest_host_native_token(vx_xrizer_guest_host *fixture,uint32_t eye){
    StereoHost *h=joined_object(fixture);return !fixture->external && eye<2?h.sources[eye].token:NULL;
}
int vx_xrizer_guest_host_check_pair(vx_xrizer_guest_host *fixture,uint32_t variant){
    StereoHost *h=joined_object(fixture);if(!h.frames || variant>1)return -1;
    vx_native_vr_frame frame;if(vx_native_vr_acquire(h.frames,&frame))return -1;
    check_pair(h,&frame,variant);assert(vx_native_vr_release(h.frames,frame.lease)==0);
    vx_native_vr_reset(h.frames);return 0;
}
int vx_xrizer_guest_host_record_writes(vx_xrizer_guest_host *fixture,void *texture,void *command_buffer){
    StereoHost *h=joined_object(fixture);KlNativeMetalHost resources=h.resources;
    return kl_apple_metal_record_texture_writes(&resources,texture,command_buffer)==XR_SUCCESS?0:-1;
}
int vx_xrizer_guest_host_finish(vx_xrizer_guest_host *fixture){
    StereoHost *h=joined_object(fixture);
    if(h.outstanding || h.frames || h.begins!=1 || h.exits!=1 || h.ends!=1 || sessions_created!=1 || sessions_destroyed!=1 ||
        h.sourceAcquires!=h.sourceReleases || retained!=released)return -1;
    KlNativeMetalHost resources=h.resources;
    assert(kl_native_configure_input(NULL)==XR_SUCCESS && kl_native_configure_frame(NULL)==XR_SUCCESS && kl_native_configure_image_sync(NULL)==XR_SUCCESS && kl_native_configure_session(NULL)==XR_SUCCESS);
    assert(kl_native_configure_views(NULL)==XR_SUCCESS && kl_native_configure_metal(NULL)==XR_SUCCESS && kl_apple_metal_host_destroy(&resources)==XR_SUCCESS);
    fixture->finished=true;return 0;
}
