/* Owned native-ABI xrizer frontend preflight. No guest ABI or physical HMD. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include "apple_metal_host.h"
#include "frame_host.h"
#include "session_host.h"
#include "klepton_native.h"
#include "view_host.h"
#include "metal_host_bridge.h"
static PFN_xrEnumerateViewConfigurationViews provider_views;
static unsigned view_calls, session_polls, session_begins, session_ends, exit_requests, frame_waits, copies, acquired;
static XrResult last_view_result;
static unsigned view_configurations;
static int ready_bootstrap;
static KlNativeSessionEvent injected_event;
static XrResult view_configuration(void *ctx,KlNativeViewConfiguration *out) {
    (void)ctx; ++view_configurations;
    *out=(KlNativeViewConfiguration){.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE,.fov_mutable=XR_FALSE};
    for(unsigned i=0;i<2;++i)out->view[i]=(XrViewConfigurationView){.type=XR_TYPE_VIEW_CONFIGURATION_VIEW,
        .recommendedImageRectWidth=8,.maxImageRectWidth=8,.recommendedImageRectHeight=8,.maxImageRectHeight=8,
        .recommendedSwapchainSampleCount=1,.maxSwapchainSampleCount=1};
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL traced_views(XrInstance instance,XrSystemId system,XrViewConfigurationType type,
    uint32_t capacity,uint32_t *count,XrViewConfigurationView *views) {
    ++view_calls; XrResult result=provider_views(instance,system,type,capacity,count,views);
    last_view_result=result;
    printf("provider call: xrEnumerateViewConfigurationViews capacity=%u result=%d\n",capacity,result);
    return result;
}
static XrResult XRAPI_CALL traced_entry(XrInstance instance,const char *name,PFN_xrVoidFunction *out) {
    XrResult result=kl_native_get_instance_proc_addr(instance,name,out);
    if(result==XR_SUCCESS && !strcmp(name,"xrEnumerateViewConfigurationViews")) {
        provider_views=(PFN_xrEnumerateViewConfigurationViews)*out;
        *out=(PFN_xrVoidFunction)traced_views;
    }
    printf("provider resolve: %s result=%d\n",name,result);
    return result;
}
static XrResult availability(void *ctx) { (void)ctx; return XR_SUCCESS; }
static XrResult poll_host(void *ctx,KlNativeSessionEvent *event) {
    (void)ctx; ++session_polls;
    if(!injected_event.type)return XR_EVENT_UNAVAILABLE;
    *event=injected_event;injected_event=(KlNativeSessionEvent){0};return XR_SUCCESS;
}
static XrResult begin_host(void *ctx,XrTime *time) {
    (void)ctx;++session_begins;if(!ready_bootstrap)return XR_ERROR_RUNTIME_FAILURE;
    *time=20;return XR_SUCCESS;
}
static XrResult end_host(void *ctx,XrTime *time) {
    (void)ctx;++session_ends;if(!ready_bootstrap)return XR_ERROR_RUNTIME_FAILURE;
    assert(frame_waits==0 && acquired==0 && copies==0); /* No producer or reader work exists in this bootstrap. */
    *time=40;injected_event=(KlNativeSessionEvent){KL_NATIVE_SESSION_EXITING,41};return XR_SUCCESS;
}
static XrResult request_exit(void *ctx) {
    (void)ctx;++exit_requests;if(!ready_bootstrap)return XR_ERROR_RUNTIME_FAILURE;
    assert(!injected_event.type);injected_event=(KlNativeSessionEvent){KL_NATIVE_SESSION_STOPPING,30};return XR_SUCCESS;
}
static XrResult wait_host(void *ctx,KlNativeFrameSample *sample) { (void)ctx;(void)sample; ++frame_waits; return XR_ERROR_FUNCTION_UNSUPPORTED; }
static XrResult publish_host(void *ctx,const KlNativeFramePair *pair) { (void)ctx;(void)pair; return XR_ERROR_FUNCTION_UNSUPPORTED; }
static XrResult cancel_host(void *ctx,void *ticket) { (void)ctx;(void)ticket; return XR_ERROR_FUNCTION_UNSUPPORTED; }
static int32_t acquire_source(void *ctx,void *handle,XrizerMetalTexture *out) {
    (void)ctx;(void)handle; ++acquired; if(out)memset(out,0,sizeof(*out)); return -1;
}
static int32_t copy_source(void *ctx,const XrizerMetalCopy *copy) { (void)ctx;(void)copy; ++copies;return -1; }
static void release_source(void *ctx,void *lease) { (void)ctx;(void)lease; assert(!"no texture lease is issued by this preflight"); }
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    /* The runner confines xrizer's logger; direct artifact execution must do so too. */
    assert(getenv("XDG_STATE_HOME") && getenv("XDG_CONFIG_HOME"));
    ready_bootstrap=!strcmp(argv[2],"ready-bootstrap");
    const int have_views=ready_bootstrap || !strcmp(argv[2],"views-no-ready");
    if(!have_views && strcmp(argv[2],"missing-views"))return 2;
    setbuf(stdout,NULL);
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
        id<MTLCommandQueue> queue=[device newCommandQueue]; assert(queue);
        KlNativeMetalHost metal; assert(kl_apple_metal_host_create((__bridge void *)device,(__bridge void *)queue,&metal)==XR_SUCCESS);
        KlNativeImageSyncHost sync; assert(kl_apple_metal_image_sync(&metal,&sync)==XR_SUCCESS);
        KlNativeHost system={.version=1,.size=sizeof(system),.hmd_available=availability};
        KlNativeSessionHost session={.version=KL_NATIVE_SESSION_HOST_VERSION,.struct_size=sizeof(session),
            .poll_event=poll_host,.begin_session=begin_host,.end_session=end_host,.request_exit=request_exit};
        KlNativeFrameHost frame={KL_NATIVE_FRAME_HOST_VERSION,sizeof(frame),NULL,wait_host,publish_host,cancel_host};
        assert(kl_native_configure(&system)==XR_SUCCESS && kl_native_configure_metal(&metal)==XR_SUCCESS);
        assert(kl_native_configure_image_sync(&sync)==XR_SUCCESS && kl_native_configure_session(&session)==XR_SUCCESS && kl_native_configure_frame(&frame)==XR_SUCCESS);
        if(have_views) {
            /* These dimensions describe an actual owned offscreen allocation,
             * not headset recommendations inferred from hardware maxima. */
            KlNativeMetalImageInfo image={.format=MTLPixelFormatRGBA8Unorm,.width=8,.height=8,.array_size=2,
                .sample_count=1,.mip_count=1,.usage=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT};
            void *texture=NULL,*lease=NULL;
            assert(metal.create_image(metal.context,&image,&texture,&lease)==XR_SUCCESS && texture && lease);
            metal.release_image(metal.context,lease);
            KlNativeViewHost views={KL_NATIVE_VIEW_HOST_VERSION,sizeof(views),NULL,view_configuration};
            assert(kl_native_configure_views(&views)==XR_SUCCESS);
        }
        void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
        if(!library){fprintf(stderr,"%s\n",dlerror());return 1;}
        typedef int32_t(*configure_provider_fn)(PFN_xrGetInstanceProcAddr);
        typedef int32_t(*configure_metal_fn)(const XrizerMetalHost *);
        typedef void *(*factory_fn)(const char *,int *);
        typedef int(*init_fn)(void *,int,const char *);
        configure_provider_fn configure_provider=(configure_provider_fn)dlsym(library,"xrizer_configure_openxr_provider");
        configure_metal_fn configure_metal=(configure_metal_fn)dlsym(library,"xrizer_configure_metal_host");
        factory_fn factory=(factory_fn)dlsym(library,"VRClientCoreFactory"); assert(configure_provider && configure_metal && factory);
        assert(configure_provider(traced_entry)==0);
        XrizerMetalHost bridge={.abi_version=XRIZER_METAL_HOST_ABI_VERSION,.struct_size=sizeof(bridge),
            .device=(__bridge void *)device,.command_queue=(__bridge void *)queue,
            .acquire=acquire_source,.copy_complete=copy_source,.release=release_source};
        assert(configure_metal(&bridge)==0);
        int factory_error=-1;void *core=factory("IVRClientCore_003",&factory_error); assert(core && factory_error==0);
        init_fn init=*(init_fn *)*(void **)core; assert(init);
        if(ready_bootstrap)injected_event=(KlNativeSessionEvent){KL_NATIVE_SESSION_READY,10};
        int result=init(core,1,NULL);
        printf("actual xrizer native Init result=%d; view calls=%u; view result=%d; session polls=%u begins=%u; frame waits=%u; texture acquires=%u copies=%u\n",
            result,view_calls,last_view_result,session_polls,session_begins,frame_waits,acquired,copies);
        if(ready_bootstrap) {
            assert(result==0 && view_calls==2 && last_view_result==XR_SUCCESS && session_begins==1);
            typedef void *(*interface_fn)(void *,const char *,int *);
            typedef void (*size_fn)(void *,uint32_t *,uint32_t *);
            typedef void (*cleanup_fn)(void *);
            void **vtable=*(void ***)core;interface_fn get_interface=(interface_fn)vtable[3];
            int error=-1;void *system=get_interface(core,"IVRSystem_019",&error);assert(system && error==0);
            error=-1;void *compositor=get_interface(core,"IVRCompositor_022",&error);assert(compositor && error==0);
            uint32_t width=0,height=0;size_fn size=(size_fn)(*(void ***)system)[0];size(system,&width,&height);
            assert(width==8 && height==8);
            ((cleanup_fn)vtable[1])(core);
            assert(exit_requests==1 && session_ends==1 && !injected_event.type);
            printf("actual native System019 dimensions=%ux%u; Compositor022 acquired; Cleanup request_exit=%u end_ack=%u\n",width,height,exit_requests,session_ends);
        } else {
            assert(result==150);
            if(have_views)assert(view_calls==2 && last_view_result==XR_SUCCESS && view_configurations==2 && session_polls==1);
            else assert(view_calls==1 && last_view_result==XR_ERROR_FUNCTION_UNSUPPORTED && session_polls==0);
            assert(session_begins==0);
        }
        assert(frame_waits==0 && acquired==0 && copies==0);
        assert(kl_native_configure_frame(NULL)==XR_SUCCESS && kl_native_configure_session(NULL)==XR_SUCCESS);
        assert(kl_native_configure_views(NULL)==XR_SUCCESS);
        assert(kl_native_configure_image_sync(NULL)==XR_SUCCESS && kl_native_configure_metal(NULL)==XR_SUCCESS);
        assert(kl_apple_metal_host_destroy(&metal)==XR_SUCCESS);
        puts(ready_bootstrap ? "xrizer actual native frontend: Init, System019 dimensions, Compositor022 factory and real host-acknowledged Cleanup pass; no frame, guest ABI, headset or physical tracking claim" :
            have_views ? "xrizer actual native frontend: real owned view metadata and Metal session reach missing-READY refusal; no panic, session begin, GPU frame, guest ABI, headset or physical tracking claim" :
            "xrizer actual native frontend preflight: expected Init150 at real provider view-configuration refusal; no panic, session, GPU frame, guest ABI, headset or physical tracking claim");
        /* The registered bridge intentionally lives for the loaded library's process lifetime. */
    }
    return 0;
}
