/* Owned CPU-only provider/host contract test. Fake Objective-C Metal objects
 * are never used to allocate a real GPU resource or publish an eye pair. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "xrizer_xros_host.h"
#define XR_USE_GRAPHICS_API_METAL 1
#include <openxr/openxr_platform.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
@interface FakeDevice : NSObject
@end
@implementation FakeDevice
- (BOOL)supportsTextureSampleCount:(NSUInteger)n { return n==1; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor { (void)descriptor; return [NSObject new]; }
@end
@interface FakeQueue : NSObject
@property(nonatomic,strong) id device;
@end
@implementation FakeQueue
@end
static PFN_xrGetInstanceProcAddr captured;
static vx_xros_xrizer_factory installed;
static void *installed_context;
static int32_t provider(PFN_xrGetInstanceProcAddr p) { captured=p; return p ? 0 : -1; }
static int32_t graphics(const XrizerMetalHost *p) { return p ? 0 : -1; }
static void *core_factory(const char *name,int *error) { if (error) *error=0; return !strcmp(name,"IVRClientCore_003") ? (void *)1 : NULL; }
static int install(vx_xros_xrizer_factory f,void *ctx) { installed=f; installed_context=ctx; return f && ctx ? 0 : -1; }
static int32_t source_acquire(void *c,void *h,XrizerMetalTexture *o) { (void)c;(void)h;(void)o; return -1; }
static int32_t source_copy(void *c,const XrizerMetalCopy *r) { (void)c;(void)r; return -1; }
static void source_release(void *c,void *t) { (void)c;(void)t; }
static XrResult begin(void *c,XrTime *t) { (void)c; *t=20; return XR_SUCCESS; }
static XrResult end(void *c,XrTime *t) { (void)c; *t=40; return XR_SUCCESS; }
static XrResult request(void *c) { (void)c; return XR_SUCCESS; }
static int connected;
static XrResult input(void *c,KlNativeInputSample *s) { (void)c; *s=(KlNativeInputSample){.sample_id=1,.sample_time=21,.hand_connected={(XrBool32)connected,XR_FALSE}}; return XR_SUCCESS; }
#define GET(type,var,name) PFN_xrVoidFunction raw_##var=NULL; assert(captured(instance,name,&raw_##var)==XR_SUCCESS && raw_##var); type var=(type)raw_##var
static XrSessionState poll_state(PFN_xrPollEvent fn,XrInstance instance) {
    XrEventDataBuffer b={.type=XR_TYPE_EVENT_DATA_BUFFER}; assert(fn(instance,&b)==XR_SUCCESS);
    return ((XrEventDataSessionStateChanged *)&b)->state;
}
int main(void) {
    @autoreleasepool {
        FakeDevice *device=[FakeDevice new]; FakeQueue *queue=[FakeQueue new]; queue.device=device;
        void *d=(__bridge void *)device,*q=(__bridge void *)queue;
        vx_xros_xrizer_platform p={VX_XROS_XRIZER_API_VERSION,sizeof(p),NULL,begin,end,request,input};
        vx_xros_xrizer_host *h=vx_xros_xrizer_create(VX_XROS_XRIZER_INJECTED_TEST,d,q,&p); assert(h);
        assert(!vx_xros_xrizer_create(VX_XROS_XRIZER_PLATFORM,d,q,&p));
        vx_xros_xrizer_static_api api={VX_XROS_XRIZER_API_VERSION,sizeof(api),provider,graphics,core_factory,install};
        XrizerMetalHost source={.abi_version=1,.struct_size=sizeof(source),.device=d,.command_queue=q,
            .acquire=source_acquire,.copy_complete=source_copy,.release=source_release};
        source.device=q; assert(vx_xros_xrizer_register(h,&api,&source)==-1); source.device=d;
        assert(vx_xros_xrizer_register(h,&api,&source)==0 && captured && installed);
        assert(vx_xros_xrizer_register(h,&api,&source)==-1);
        int err=-1; assert(installed(installed_context,&err)==(void *)1 && !err);
        KlNativeViewConfiguration view={.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE};
        for (int i=0;i<2;i++) view.view[i]=(XrViewConfigurationView){.type=XR_TYPE_VIEW_CONFIGURATION_VIEW,
            .recommendedImageRectWidth=8,.maxImageRectWidth=8,.recommendedImageRectHeight=8,.maxImageRectHeight=8,
            .recommendedSwapchainSampleCount=1,.maxSwapchainSampleCount=1};
        PFN_xrVoidFunction raw=NULL; assert(captured(XR_NULL_HANDLE,"xrCreateInstance",&raw)==XR_SUCCESS);
        PFN_xrCreateInstance create=(PFN_xrCreateInstance)raw;
        const char *extension=XR_KHR_METAL_ENABLE_EXTENSION_NAME;
        XrInstanceCreateInfo ci={.type=XR_TYPE_INSTANCE_CREATE_INFO,.enabledExtensionCount=1,.enabledExtensionNames=&extension};
        ci.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0);
        XrInstance instance; assert(create(&ci,&instance)==XR_SUCCESS);
        GET(PFN_xrGetSystem,get_system,"xrGetSystem");
        XrSystemGetInfo system_info={.type=XR_TYPE_SYSTEM_GET_INFO,.formFactor=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
        XrSystemId system_id=0; assert(get_system(instance,&system_info,&system_id)==XR_ERROR_FORM_FACTOR_UNAVAILABLE);
        assert(vx_xros_xrizer_surface(h,1,&view)==0 && get_system(instance,&system_info,&system_id)==XR_SUCCESS);
        GET(PFN_xrGetMetalGraphicsRequirementsKHR,requirements,"xrGetMetalGraphicsRequirementsKHR");
        GET(PFN_xrCreateSession,new_session,"xrCreateSession"); GET(PFN_xrDestroySession,destroy_session,"xrDestroySession");
        GET(PFN_xrDestroyInstance,destroy_instance,"xrDestroyInstance"); GET(PFN_xrPollEvent,poll,"xrPollEvent");
        GET(PFN_xrBeginSession,begin_xr,"xrBeginSession"); GET(PFN_xrEndSession,end_xr,"xrEndSession");
        GET(PFN_xrRequestExitSession,exit_xr,"xrRequestExitSession"); GET(PFN_xrWaitFrame,wait_xr,"xrWaitFrame");
        GET(PFN_xrBeginFrame,begin_frame,"xrBeginFrame"); GET(PFN_xrEndFrame,end_frame,"xrEndFrame");
        GET(PFN_xrCreateActionSet,create_set,"xrCreateActionSet");
        GET(PFN_xrAttachSessionActionSets,attach,"xrAttachSessionActionSets"); GET(PFN_xrSyncActions,sync,"xrSyncActions");
        XrGraphicsRequirementsMetalKHR req={.type=XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
        assert(requirements(instance,1,&req)==XR_SUCCESS && req.metalDevice==d);
        XrGraphicsBindingMetalKHR binding={.type=XR_TYPE_GRAPHICS_BINDING_METAL_KHR,.commandQueue=q};
        XrSessionCreateInfo si={.type=XR_TYPE_SESSION_CREATE_INFO,.next=&binding,.systemId=1};
        XrSession session; assert(new_session(instance,&si,&session)==XR_SUCCESS);
        assert(vx_xros_xrizer_event(h,(KlNativeSessionEvent){KL_NATIVE_SESSION_READY,10})==0);
        assert(poll_state(poll,instance)==XR_SESSION_STATE_READY);
        XrSessionBeginInfo bi={.type=XR_TYPE_SESSION_BEGIN_INFO,.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
        assert(begin_xr(session,&bi)==XR_SUCCESS && poll_state(poll,instance)==XR_SESSION_STATE_SYNCHRONIZED);
        assert(vx_xros_xrizer_event(h,(KlNativeSessionEvent){KL_NATIVE_SESSION_VISIBLE,21})==0);
        assert(vx_xros_xrizer_event(h,(KlNativeSessionEvent){KL_NATIVE_SESSION_FOCUSED,19})==-1);
        assert(vx_xros_xrizer_event(h,(KlNativeSessionEvent){KL_NATIVE_SESSION_FOCUSED,22})==0);
        assert(poll_state(poll,instance)==XR_SESSION_STATE_VISIBLE && poll_state(poll,instance)==XR_SESSION_STATE_FOCUSED);
        XrActionSetCreateInfo ac={.type=XR_TYPE_ACTION_SET_CREATE_INFO}; strcpy(ac.actionSetName,"fixture"); strcpy(ac.localizedActionSetName,"Fixture");
        XrActionSet set; assert(create_set(instance,&ac,&set)==XR_SUCCESS);
        XrSessionActionSetsAttachInfo ai={.type=XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO,.countActionSets=1,.actionSets=&set};
        assert(attach(session,&ai)==XR_SUCCESS);
        XrActiveActionSet active={.actionSet=set}; XrActionsSyncInfo sync_info={.type=XR_TYPE_ACTIONS_SYNC_INFO,.countActiveActionSets=1,.activeActionSets=&active};
        assert(sync(session,&sync_info)==XR_SUCCESS);
        connected=1; assert(sync(session,&sync_info)==XR_ERROR_FEATURE_UNSUPPORTED);
        connected=0; assert(sync(session,&sync_info)==XR_SUCCESS);
        KlNativeFrameSample sample={.frame_id=1,.pose_id=2,.predicted_display_time=100,.predicted_display_period=10,
            .should_render=XR_TRUE,.head_location_flags=XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_ORIENTATION_VALID_BIT,
            .local_from_head={.orientation.w=1},.head_from_eye={{.orientation.w=1},{.orientation.w=1}},
            .fov={{-.8f,.8f,.8f,-.8f},{-.8f,.8f,.8f,-.8f}}};
        assert(vx_xros_xrizer_offer(h,&sample)==0);
        XrFrameState state={.type=XR_TYPE_FRAME_STATE}; assert(wait_xr(session,NULL,&state)==XR_SUCCESS && state.predictedDisplayTime==100);
        assert(begin_frame(session,NULL)==XR_SUCCESS);
        XrFrameEndInfo fi={.type=XR_TYPE_FRAME_END_INFO,.displayTime=100,.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE};
        assert(end_frame(session,&fi)==XR_SUCCESS);
        assert(exit_xr(session)==XR_SUCCESS);
        assert(vx_xros_xrizer_event(h,(KlNativeSessionEvent){KL_NATIVE_SESSION_STOPPING,30})==0);
        assert(poll_state(poll,instance)==XR_SESSION_STATE_STOPPING);
        assert(end_xr(session)==XR_SUCCESS && poll_state(poll,instance)==XR_SESSION_STATE_IDLE);
        assert(vx_xros_xrizer_event(h,(KlNativeSessionEvent){KL_NATIVE_SESSION_EXITING,41})==0);
        assert(poll_state(poll,instance)==XR_SESSION_STATE_EXITING);
        assert(destroy_session(session)==XR_SUCCESS && destroy_instance(instance)==XR_SUCCESS);
        assert(vx_xros_xrizer_retire(h)==0 && vx_xros_xrizer_retire(h)==-1);
        assert(vx_xros_xrizer_offer(h,&sample)==-1);
        puts("XR static host/provider lifecycle: pass; fake Metal, injected events, no GPU or headset");
    }
    return 0;
}
