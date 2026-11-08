/* Owned offscreen Metal fixture. Injected poses/lifecycle are not physical XR. */
#include "metal_frame_host.inc"
static XrResult availability(void *ctx) { (void)ctx; return XR_SUCCESS; }
static XrResult poll_host(void *ctx, KlNativeSessionEvent *out) {
    FrameHost *h=host(ctx); if (!h.event.type) return XR_EVENT_UNAVAILABLE;
    *out=h.event; h.event=(KlNativeSessionEvent){0}; return XR_SUCCESS;
}
static XrResult begin_host(void *ctx, XrTime *time) { *time=host(ctx).acknowledgement; return XR_SUCCESS; }
static XrResult end_host(void *ctx, XrTime *time) {
    FrameHost *h=host(ctx); assert(!h.outstanding);
    /* The fixture calls this only after every native reader is released and reset. */
    assert(vx_native_vr_destroy(h.frames)==0); h.frames=NULL;
    *time=h.acknowledgement; return XR_SUCCESS;
}
static XrResult wait_host(void *ctx, KlNativeFrameSample *out) {
    FrameHost *h=host(ctx); assert(!h.outstanding && h.sample.ticket);
    *out=h.sample; h.outstanding=out->ticket; ++h.waits; return XR_SUCCESS;
}
static XrResult cancel_host(void *ctx, void *ticket) {
    FrameHost *h=host(ctx); assert(ticket && h.outstanding==ticket);
    h.outstanding=NULL; ++h.cancels; return XR_SUCCESS;
}
#define GET(type, var, instance, name) \
    PFN_xrVoidFunction raw_##var=NULL; \
    assert(kl_native_get_instance_proc_addr(instance,name,&raw_##var)==XR_SUCCESS); \
    type var=(type)raw_##var; assert(var)
static XrSessionState poll_state(PFN_xrPollEvent poll, XrInstance instance) {
    XrEventDataBuffer b={ .type=XR_TYPE_EVENT_DATA_BUFFER };
    assert(poll(instance,&b)==XR_SUCCESS && b.type==XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED);
    return ((XrEventDataSessionStateChanged *)&b)->state;
}
static void write_array(KlNativeMetalHost *resources, FrameHost *h, void *raw, unsigned variant) {
    id<MTLTexture> texture=(__bridge id<MTLTexture>)raw;
    id<MTLBuffer> upload=[h.device newBufferWithLength:1536 options:MTLResourceStorageModeShared]; assert(upload);
    unsigned char *data=upload.contents; memset(data,0,1536);
    for (unsigned eye=0;eye<2;++eye) for(unsigned y=0;y<3;++y) for(unsigned x=0;x<4;++x) {
        unsigned char *p=data+eye*768+y*256+x*4;
        if (!variant) { p[0]=eye?0:255; p[1]=eye?255:0; }
        else { p[0]=eye?255:0; p[1]=eye?255:0; p[2]=eye?0:255; }
        p[3]=255;
    }
    id<MTLCommandBuffer> cb=[h.queue commandBuffer]; assert(cb);
    for (NSUInteger eye=0;eye<2;++eye) {
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=texture; pass.colorAttachments[0].slice=eye;
        pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0.25,0.25,0.25,1);
        id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass]; assert(enc); [enc endEncoding];
    }
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; assert(blit);
    for (NSUInteger eye=0;eye<2;++eye) [blit copyFromBuffer:upload sourceOffset:eye*768 sourceBytesPerRow:256 sourceBytesPerImage:768
        sourceSize:MTLSizeMake(4,3,1) toTexture:texture destinationSlice:eye destinationLevel:0 destinationOrigin:MTLOriginMake(2,1,0)];
    [blit endEncoding]; [cb commit];
    assert(kl_apple_metal_record_texture_writes(resources,raw,(__bridge void *)cb)==XR_SUCCESS);
}
static void check_pose(const vx_native_vr_frame *frame, const KlNativeFrameSample *sample, unsigned stage) {
    assert(frame->pose.frame_id==sample->frame_id && frame->pose.pose_id==sample->pose_id);
    assert(fabs(frame->pose.pose_time-(double)sample->predicted_display_time/1e9)<1e-9 && frame->pose.tracking_valid==1);
    const float origin[16]={0,0,-1,0, 0,1,0,0, 1,0,0,0, 1,2,3,1};
    for(unsigned i=0;i<16;++i) near(frame->pose.origin_from_head[i],origin[i]);
    for(unsigned eye=0;eye<2;++eye) {
        const float *m=frame->pose.head_from_eye[eye];
        const float expected[16]={0,0,1,0, 0,1,0,0, -1,0,0,0,
            stage?(-1.0f-eye*0.2f):-0.2f,stage?(6.0f+eye*0.2f):0,
            stage?(0.25f+eye*0.1f):(eye?0.04f:-0.04f),1};
        for(unsigned i=0;i<16;++i) near(m[i],expected[i]);
        near(frame->pose.frustum[eye][0],tanf(-.7f-eye*.03f));
        near(frame->pose.frustum[eye][1],tanf(.8f+eye*.02f));
        near(frame->pose.frustum[eye][2],-tanf(.9f)); near(frame->pose.frustum[eye][3],-tanf(-.6f));
    }
}
int main(void) {
    @autoreleasepool {
        FrameHost *h=[FrameHost new]; h.device=MTLCreateSystemDefaultDevice(); assert(h.device);
        h.queue=[h.device newCommandQueue]; assert(h.queue); h.frames=vx_native_vr_create(keep_texture,drop_texture); assert(h.frames);
        KlNativeMetalHost resources; assert(kl_apple_metal_host_create((__bridge void *)h.device,(__bridge void *)h.queue,&resources)==XR_SUCCESS);
        KlNativeImageSyncHost sync; assert(kl_apple_metal_image_sync(&resources,&sync)==XR_SUCCESS);
        void *context=(__bridge void *)h;
        KlNativeHost system={ .version=1,.size=sizeof(system),.context=context,.hmd_available=availability };
        KlNativeSessionHost session_host={.version=KL_NATIVE_SESSION_HOST_VERSION,.struct_size=sizeof(session_host),
            .context=context,.poll_event=poll_host,.begin_session=begin_host,.end_session=end_host};
        KlNativeFrameHost frame_host={KL_NATIVE_FRAME_HOST_VERSION,sizeof(frame_host),context,wait_host,publish_host,cancel_host};
        assert(kl_native_configure(&system)==XR_SUCCESS && kl_native_configure_metal(&resources)==XR_SUCCESS);
        assert(kl_native_configure_session(&session_host)==XR_SUCCESS && kl_native_configure_frame(&frame_host)==XR_SUCCESS);
        assert(kl_native_configure_image_sync(&sync)==XR_SUCCESS);
        GET(PFN_xrCreateInstance,create_instance,XR_NULL_HANDLE,"xrCreateInstance");
        const char *extension=XR_KHR_METAL_ENABLE_EXTENSION_NAME;
        XrInstanceCreateInfo ci={ .type=XR_TYPE_INSTANCE_CREATE_INFO,.enabledExtensionCount=1,.enabledExtensionNames=&extension };
        ci.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0); XrInstance instance;
        assert(create_instance(&ci,&instance)==XR_SUCCESS);
        GET(PFN_xrGetMetalGraphicsRequirementsKHR,requirements,instance,"xrGetMetalGraphicsRequirementsKHR");
        GET(PFN_xrCreateSession,create_session,instance,"xrCreateSession");
        GET(PFN_xrBeginSession,begin_session,instance,"xrBeginSession");
        GET(PFN_xrEndSession,end_session,instance,"xrEndSession");
        GET(PFN_xrPollEvent,poll,instance,"xrPollEvent");
        GET(PFN_xrCreateReferenceSpace,create_space,instance,"xrCreateReferenceSpace");
        GET(PFN_xrCreateSwapchain,create_swapchain,instance,"xrCreateSwapchain");
        GET(PFN_xrEnumerateSwapchainImages,images,instance,"xrEnumerateSwapchainImages");
        GET(PFN_xrAcquireSwapchainImage,acquire_image,instance,"xrAcquireSwapchainImage");
        GET(PFN_xrWaitSwapchainImage,wait_image,instance,"xrWaitSwapchainImage");
        GET(PFN_xrReleaseSwapchainImage,release_image,instance,"xrReleaseSwapchainImage");
        GET(PFN_xrWaitFrame,wait_frame,instance,"xrWaitFrame");
        GET(PFN_xrBeginFrame,begin_frame,instance,"xrBeginFrame");
        GET(PFN_xrEndFrame,end_frame,instance,"xrEndFrame");
        GET(PFN_xrDestroySwapchain,destroy_swapchain,instance,"xrDestroySwapchain");
        GET(PFN_xrDestroySession,destroy_session,instance,"xrDestroySession");
        GET(PFN_xrDestroyInstance,destroy_instance,instance,"xrDestroyInstance");
        XrGraphicsRequirementsMetalKHR req={.type=XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
        assert(requirements(instance,1,&req)==XR_SUCCESS && req.metalDevice==(__bridge void *)h.device);
        XrGraphicsBindingMetalKHR binding={.type=XR_TYPE_GRAPHICS_BINDING_METAL_KHR,.commandQueue=(__bridge void *)h.queue};
        XrSessionCreateInfo si={.type=XR_TYPE_SESSION_CREATE_INFO,.next=&binding,.systemId=1}; XrSession session;
        assert(create_session(instance,&si,&session)==XR_SUCCESS);
        XrTime start=monotonic_ns(); h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_READY,start};
        assert(poll_state(poll,instance)==XR_SESSION_STATE_READY); h.acknowledgement=start+1;
        XrSessionBeginInfo bi={.type=XR_TYPE_SESSION_BEGIN_INFO,.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
        assert(begin_session(session,&bi)==XR_SUCCESS && poll_state(poll,instance)==XR_SESSION_STATE_SYNCHRONIZED);
        XrReferenceSpaceCreateInfo ri={.type=XR_TYPE_REFERENCE_SPACE_CREATE_INFO,.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_LOCAL,.poseInReferenceSpace.orientation.w=1};
        XrSpace local,stage; assert(create_space(session,&ri,&local)==XR_SUCCESS);
        ri.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_STAGE; assert(create_space(session,&ri,&stage)==XR_SUCCESS);
        XrSwapchainCreateInfo sci={.type=XR_TYPE_SWAPCHAIN_CREATE_INFO,.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT|XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT|XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT,
            .format=MTLPixelFormatRGBA8Unorm,.sampleCount=1,.width=8,.height=8,.faceCount=1,.arraySize=2,.mipCount=1};
        XrSwapchain swap; assert(create_swapchain(session,&sci,&swap)==XR_SUCCESS);
        XrSwapchainImageMetalKHR imgs[3]={{.type=XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR},{.type=XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR},{.type=XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR}};
        uint32_t count=0; assert(images(swap,3,&count,(XrSwapchainImageBaseHeader *)imgs)==XR_SUCCESS && count==3);
        unsigned tickets[6]={0}; vx_native_vr_frame held={0}; uint32_t first_image=99;
        for(unsigned n=1;n<=4;++n) {
            @autoreleasepool {
                const unsigned is_stage=n%2==0,variant=n==4;
                h.sample=(KlNativeFrameSample){.ticket=&tickets[n],.frame_id=100+n,.pose_id=200+n,
                    .predicted_display_time=start+(XrTime)n*INT64_C(10000000),.predicted_display_period=INT64_C(10000000),.should_render=XR_TRUE,
                    .head_location_flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT|XR_SPACE_LOCATION_POSITION_TRACKED_BIT,
                    .local_from_head={.orientation={0,.7071067811865475f,0,.7071067811865475f},.position={1,2,3}},
                    .head_from_eye={{.orientation.w=1,.position.x=-.03f},{.orientation.w=1,.position.x=.03f}},
                    .fov={{-.5f,.5f,.5f,-.5f},{-.5f,.5f,.5f,-.5f}},
                    .stage_valid=XR_TRUE,.local_from_stage={.orientation={0,1,0,0},.position={4,5,6}}};
                XrFrameState fs={.type=XR_TYPE_FRAME_STATE}; assert(wait_frame(session,NULL,&fs)==XR_SUCCESS && fs.shouldRender);
                assert(begin_frame(session,NULL)==XR_SUCCESS);
                uint32_t index; assert(acquire_image(swap,NULL,&index)==XR_SUCCESS);
                if(n==1)first_image=index; if(n==4)assert(index==first_image);
                XrSwapchainImageWaitInfo wi={.type=XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO,.timeout=XR_INFINITE_DURATION};
                assert(wait_image(swap,&wi)==XR_SUCCESS);
                if(n==1) assert(release_image(swap,NULL)==XR_ERROR_CALL_ORDER_INVALID);
                write_array(&resources,h,imgs[index].texture,variant);
                assert(release_image(swap,NULL)==XR_SUCCESS);
                XrCompositionLayerProjectionView views[2]; memset(views,0,sizeof views);
                for(unsigned eye=0;eye<2;++eye) {
                    views[eye].type=XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
                    views[eye].pose=is_stage?(XrPosef){.orientation={0,1,0,0},.position={2.75f-eye*.1f,3+eye*.2f,2-eye*.2f}}:
                        (XrPosef){.orientation.w=1,.position={1+(eye?.04f:-.04f),2,3.2f}};
                    views[eye].fov=(XrFovf){-.7f-eye*.03f,.8f+eye*.02f,.9f,-.6f};
                    views[eye].subImage=(XrSwapchainSubImage){.swapchain=swap,.imageRect={{2,1},{4,3}},.imageArrayIndex=eye};
                }
                XrCompositionLayerProjection projection={.type=XR_TYPE_COMPOSITION_LAYER_PROJECTION,.space=is_stage?stage:local,.viewCount=2,.views=views};
                const XrCompositionLayerBaseHeader *layer=(const XrCompositionLayerBaseHeader *)&projection;
                XrFrameEndInfo ei={.type=XR_TYPE_FRAME_END_INFO,.displayTime=fs.predictedDisplayTime,.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE,.layerCount=1,.layers=&layer};
                if(n==1) {
                    h.failAfterFirstEye=YES; assert(end_frame(session,&ei)==XR_ERROR_RUNTIME_FAILURE);
                    vx_native_vr_frame absent; assert(vx_native_vr_acquire(h.frames,&absent)==-1 && h.outstanding==h.sample.ticket);
                }
                assert(end_frame(session,&ei)==XR_SUCCESS && !h.outstanding && h.publishes==n);
                vx_native_vr_frame frame; assert(vx_native_vr_acquire(h.frames,&frame)==0);
                KlNativeFrameSample sample=h.sample;
                check_pixels(h,&frame,variant); check_pose(&frame,&sample,is_stage);
                assert(frame.eye[0].resource!=imgs[index].texture && frame.eye[1].resource!=imgs[index].texture);
                if(n==1) held=frame;
                else assert(vx_native_vr_release(h.frames,frame.lease)==0);
            }
        }
        /* Provider index 0 was overwritten blue/yellow; retained frame 1 stays red/green. */
        check_pixels(h,&held,0); assert(vx_native_vr_release(h.frames,held.lease)==0);
        vx_native_vr_frame latest; assert(vx_native_vr_acquire(h.frames,&latest)==0); check_pixels(h,&latest,1);
        assert(vx_native_vr_destroy(h.frames)==-1);
        assert(destroy_swapchain(swap)==XR_SUCCESS);
        /* Swapchain leases are gone while a native queue reader owns its copies. */
        check_pixels(h,&latest,1); assert(vx_native_vr_release(h.frames,latest.lease)==0);
        vx_native_vr_frame repeat; assert(vx_native_vr_acquire(h.frames,&repeat)==0);
        assert(repeat.pose.frame_id==104 && repeat.pose.pose_id==204); check_pixels(h,&repeat,1);
        assert(vx_native_vr_release(h.frames,repeat.lease)==0); vx_native_vr_reset(h.frames);
        KlNativeFrameSample empty=h.sample;
        empty.ticket=&tickets[5]; empty.frame_id=105; empty.pose_id=205;
        empty.predicted_display_time=start+INT64_C(50000000);
        empty.should_render=XR_FALSE; empty.head_location_flags=0; h.sample=empty;
        XrFrameState skipped={.type=XR_TYPE_FRAME_STATE};
        assert(wait_frame(session,NULL,&skipped)==XR_SUCCESS && !skipped.shouldRender);
        assert(begin_frame(session,NULL)==XR_SUCCESS);
        XrFrameEndInfo no_layers={.type=XR_TYPE_FRAME_END_INFO,.displayTime=skipped.predictedDisplayTime,
            .environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE};
        assert(end_frame(session,&no_layers)==XR_SUCCESS && !h.outstanding && h.cancels==1 && h.publishes==4);
        vx_native_vr_frame absent; assert(vx_native_vr_acquire(h.frames,&absent)==-1);
        h.event=(KlNativeSessionEvent){KL_NATIVE_SESSION_STOPPING,start+INT64_C(60000000)};
        assert(poll_state(poll,instance)==XR_SESSION_STATE_STOPPING); h.acknowledgement=start+INT64_C(60000001);
        assert(end_session(session)==XR_SUCCESS && poll_state(poll,instance)==XR_SESSION_STATE_IDLE);
        assert(destroy_session(session)==XR_SUCCESS && destroy_instance(instance)==XR_SUCCESS);
        assert(kl_native_configure_frame(NULL)==XR_SUCCESS && kl_native_configure_image_sync(NULL)==XR_SUCCESS);
        assert(kl_native_configure_session(NULL)==XR_SUCCESS && kl_native_configure_metal(NULL)==XR_SUCCESS);
        assert(kl_apple_metal_host_destroy(&resources)==XR_SUCCESS && retained==released && h.waits==5 && h.publishes==4 && h.cancels==1);
        puts("klepton Metal frame fixture: four real GPU stereo pairs, cropped array copies, LOCAL/STAGE render transforms, frame/pose/FOV identity, partial-publication rollback, image reuse and provider-image teardown reader safety pass");
        puts("subject: owned offscreen native fixture; injected lifecycle/tracking only; no xrizer, Windows guest, headset, physical controller or Skyrim claim");
    }
    return 0;
}
