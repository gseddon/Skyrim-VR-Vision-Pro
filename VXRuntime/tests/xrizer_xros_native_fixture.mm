/* Owned native OpenVR caller with real Metal and injected producer; not a guest or headset. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "openvr-1.0.17.h"
extern "C" {
#include "xrizer_xros_host.h"
}
struct Context { vx_xros_xrizer_host *host; id<MTLDevice> device; id<MTLCommandQueue> queue; id<MTLTexture> eye[2]; unsigned acquired,released,copied,begins,ends,exits; XrTime base; };
static vx_xros_xrizer_factory installed; static void *installed_context;
static PFN_xrGetInstanceProcAddr actual_gipa;
static PFN_xrEndFrame actual_end_frame;
static PFN_xrLocateViews actual_locate_views;
static PFN_xrAcquireSwapchainImage actual_acquire_image;
static PFN_xrReleaseSwapchainImage actual_release_image;
static PFN_xrWaitFrame actual_wait_frame;
static PFN_xrBeginFrame actual_begin_frame;
static unsigned image_acquisitions,image_releases,waits,begins,ends,empty_ends;
static int32_t (*actual_configure_provider)(PFN_xrGetInstanceProcAddr);
static XrResult XRAPI_CALL traced_end_frame(XrSession session,const XrFrameEndInfo *info){
 XrResult r=actual_end_frame(session,info);++ends;if(info && !info->layerCount && r==XR_SUCCESS)++empty_ends;printf("xrEndFrame layers=%u result=%d\n",info?info->layerCount:0,r);return r;
}
static XrResult XRAPI_CALL traced_locate_views(XrSession session,const XrViewLocateInfo *info,XrViewState *state,uint32_t capacity,uint32_t *count,XrView *views){
 XrResult r=actual_locate_views(session,info,state,capacity,count,views);printf("xrLocateViews result=%d flags=%llu count=%u\n",r,(unsigned long long)(state && capacity && r==XR_SUCCESS?state->viewStateFlags:0),count?*count:0);return r;
}
static XrResult XRAPI_CALL traced_wait_frame(XrSession s,const XrFrameWaitInfo *i,XrFrameState *state){XrResult r=actual_wait_frame(s,i,state);++waits;printf("xrWaitFrame result=%d shouldRender=%u\n",r,r==XR_SUCCESS?state->shouldRender:0);return r;}
static XrResult XRAPI_CALL traced_begin_frame(XrSession s,const XrFrameBeginInfo *i){XrResult r=actual_begin_frame(s,i);++begins;printf("xrBeginFrame result=%d\n",r);return r;}
static XrResult XRAPI_CALL traced_acquire_image(XrSwapchain s,const XrSwapchainImageAcquireInfo *i,uint32_t *index){XrResult r=actual_acquire_image(s,i,index);if(r==XR_SUCCESS)++image_acquisitions;printf("xrAcquireSwapchainImage result=%d\n",r);return r;}
static XrResult XRAPI_CALL traced_release_image(XrSwapchain s,const XrSwapchainImageReleaseInfo *i){XrResult r=actual_release_image(s,i);if(r==XR_SUCCESS)++image_releases;printf("xrReleaseSwapchainImage result=%d\n",r);return r;}
static XrResult XRAPI_CALL traced_gipa(XrInstance instance,const char *name,PFN_xrVoidFunction *out){
 XrResult r=actual_gipa(instance,name,out);if(r==XR_SUCCESS && !strcmp(name,"xrEndFrame")){actual_end_frame=(PFN_xrEndFrame)*out;*out=(PFN_xrVoidFunction)traced_end_frame;}
 if(r==XR_SUCCESS && !strcmp(name,"xrLocateViews")){actual_locate_views=(PFN_xrLocateViews)*out;*out=(PFN_xrVoidFunction)traced_locate_views;}
 if(r==XR_SUCCESS && !strcmp(name,"xrWaitFrame")){actual_wait_frame=(PFN_xrWaitFrame)*out;*out=(PFN_xrVoidFunction)traced_wait_frame;}
 if(r==XR_SUCCESS && !strcmp(name,"xrBeginFrame")){actual_begin_frame=(PFN_xrBeginFrame)*out;*out=(PFN_xrVoidFunction)traced_begin_frame;}
 if(r==XR_SUCCESS && !strcmp(name,"xrAcquireSwapchainImage")){actual_acquire_image=(PFN_xrAcquireSwapchainImage)*out;*out=(PFN_xrVoidFunction)traced_acquire_image;}
 if(r==XR_SUCCESS && !strcmp(name,"xrReleaseSwapchainImage")){actual_release_image=(PFN_xrReleaseSwapchainImage)*out;*out=(PFN_xrVoidFunction)traced_release_image;}return r;
}
static int32_t configure_provider(PFN_xrGetInstanceProcAddr gipa){actual_gipa=gipa;return actual_configure_provider(traced_gipa);}
static int install(vx_xros_xrizer_factory f,void *c){installed=f;installed_context=c;return 0;}
static XrResult begin(void *p,XrTime *t){auto c=(Context *)p; ++c->begins;*t=c->base+20;return XR_SUCCESS;}
static XrResult end(void *p,XrTime *t){auto c=(Context *)p;++c->ends;*t=c->base+100000001;assert(vx_xros_xrizer_event(c->host,{KL_NATIVE_SESSION_EXITING,*t+1})==0);return XR_SUCCESS;}
static XrResult request(void *p){auto c=(Context *)p;++c->exits;assert(vx_xros_xrizer_event(c->host,{KL_NATIVE_SESSION_STOPPING,c->base+100000000})==0);return XR_SUCCESS;}
static XrResult input(void *p,KlNativeInputSample *s){auto c=(Context *)p;*s={.sample_id=1,.sample_time=c->base+21};return XR_SUCCESS;}
static int32_t acquire(void *p,void *token,XrizerMetalTexture *out){auto c=(Context *)p;for(unsigned i=0;i<2;++i)if(token==&c->eye[i]){id<MTLTexture> t=c->eye[i];*out={.texture=(__bridge void *)t,.device=(__bridge void *)c->device,.lease=(__bridge_retained void *)t,.format=(int64_t)t.pixelFormat,.width=8,.height=8,.sample_count=1};++c->acquired;return 0;}return -1;}
static void release(void *p,void *lease){auto c=(Context *)p;assert(lease);(void)CFBridgingRelease(lease);++c->released;}
static int32_t copy(void *p,const XrizerMetalCopy *r){auto c=(Context *)p;if(!r || !r->source || !r->source->lease || r->eye>1)return -1;
 id<MTLTexture> src=(__bridge id<MTLTexture>)r->source->texture,dst=(__bridge id<MTLTexture>)r->destination;
 if(!src || !dst || r->x!=2 || r->y!=1 || r->width!=4 || r->height!=3)return -1;
 id<MTLCommandBuffer> cb=[c->queue commandBuffer];id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];if(!b)return -1;
 [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(2,1,0) sourceSize:MTLSizeMake(4,3,1) toTexture:dst destinationSlice:r->eye destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
 [b endEncoding];[cb commit];if(vx_xros_xrizer_record_destination(c->host,r->destination,(__bridge void *)cb))return -1;
 [cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted || cb.error)return -1;++c->copied;return 0;}
static void pixels(Context *c,const vx_native_vr_frame &f,unsigned n){
 id<MTLBuffer> data=[c->device newBufferWithLength:1536 options:MTLResourceStorageModeShared];id<MTLCommandBuffer> cb=[c->queue commandBuffer];id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];assert(b);
 for(unsigned i=0;i<2;++i){assert(f.eye[i].width==4 && f.eye[i].height==3);id<MTLTexture> t=(__bridge id<MTLTexture>)f.eye[i].resource;[b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,3,1) toBuffer:data destinationOffset:i*768 destinationBytesPerRow:256 destinationBytesPerImage:768];}
 [b endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted && !cb.error);
 auto bytes=(unsigned char *)data.contents;for(unsigned i=0;i<2;++i)for(unsigned y=0;y<3;++y)for(unsigned x=0;x<4;++x){auto p=bytes+i*768+y*256+x*4;assert(p[0]==(n?20:200) && p[1]==(i?180:30) && p[2]==(n?150:40) && p[3]==255);}}
int main(int argc,char **argv){if(argc!=2)return 2;assert(getenv("XDG_STATE_HOME") && getenv("XDG_CONFIG_HOME"));setbuf(stdout,NULL);@autoreleasepool {
 Context *c=new Context{}; c->device=MTLCreateSystemDefaultDevice();assert(c->device);c->queue=[c->device newCommandQueue];assert(c->queue);struct timespec ts;assert(!clock_gettime(CLOCK_MONOTONIC,&ts));c->base=(XrTime)ts.tv_sec*1000000000+ts.tv_nsec;
 vx_xros_xrizer_platform platform={VX_XROS_XRIZER_API_VERSION,sizeof(platform),c,begin,end,request,input};c->host=vx_xros_xrizer_create(VX_XROS_XRIZER_INJECTED_TEST,(__bridge void *)c->device,(__bridge void *)c->queue,&platform);assert(c->host);
 void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s\n",dlerror());return 1;}
 actual_configure_provider=(int32_t(*)(PFN_xrGetInstanceProcAddr))dlsym(lib,"xrizer_configure_openxr_provider");assert(actual_configure_provider);
 vx_xros_xrizer_static_api api={VX_XROS_XRIZER_API_VERSION,sizeof(api),configure_provider,(int32_t(*)(const XrizerMetalHost *))dlsym(lib,"xrizer_configure_metal_host"),(void *(*)(const char *,int *))dlsym(lib,"VRClientCoreFactory"),install};
 XrizerMetalHost source={.abi_version=1,.struct_size=sizeof(source),.context=c,.device=(__bridge void *)c->device,.command_queue=(__bridge void *)c->queue,.acquire=acquire,.copy_complete=copy,.release=release};assert(vx_xros_xrizer_register(c->host,&api,&source)==0 && installed);
 KlNativeViewConfiguration views={.primary_stereo_supported=XR_TRUE,.opaque_supported=XR_TRUE};for(int i=0;i<2;i++)views.view[i]={.type=XR_TYPE_VIEW_CONFIGURATION_VIEW,.recommendedImageRectWidth=8,.maxImageRectWidth=8,.recommendedImageRectHeight=8,.maxImageRectHeight=8,.recommendedSwapchainSampleCount=1,.maxSwapchainSampleCount=1};
 KlNativeViewGeometry geometry={.version=1,.struct_size=sizeof(geometry),.geometry_id=1,.head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},.fov={{-.7f,.8f,.9f,-.6f},{-.73f,.82f,.9f,-.6f}}};
 assert(!vx_xros_xrizer_surface(c->host,1,&views) && !vx_xros_xrizer_geometry(c->host,&geometry));assert(!vx_xros_xrizer_event(c->host,{KL_NATIVE_SESSION_READY,c->base+10}));
 for(unsigned i=0;i<2;i++){MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;c->eye[i]=[c->device newTextureWithDescriptor:d];assert(c->eye[i]);}
 int error=-1;void *core=installed(installed_context,&error);assert(core && !error);void **v=*(void ***)core;auto init=(int(*)(void *,int,const char *))v[0];auto cleanup=(void(*)(void *))v[1];auto get=(void *(*)(void *,const char *,int *))v[3];assert(init(core,1,NULL)==0);
 auto comp=(vr::IVRCompositor *)get(core,vr::IVRCompositor_Version,&error);assert(comp && !error);
 comp->SetTrackingSpace(vr::TrackingUniverseSeated);assert(comp->GetTrackingSpace()==vr::TrackingUniverseSeated);
 puts("injected producer: explicit seated/local origin; stage unavailable");
 const vr::VRTextureBounds_t bounds={.25f,.125f,.75f,.5f};vx_native_vr_frame held={};
 for(unsigned n=0;n<2;n++) {KlNativeFrameSample sample={.frame_id=101+n,.pose_id=201+n,.predicted_display_time=c->base+(n+1)*10000000,.predicted_display_period=10000000,.should_render=XR_TRUE,.head_location_flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT,.local_from_head={.orientation={0,0,0,1}},.head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},.fov={{-.7f,.8f,.9f,-.6f},{-.73f,.82f,.9f,-.6f}}};assert(!vx_xros_xrizer_offer(c->host,&sample));assert(comp->WaitGetPoses(nullptr,0,nullptr,0)==vr::VRCompositorError_None);
  for(unsigned i=0;i<2;i++){unsigned char bytes[8*8*4];for(unsigned j=0;j<64;j++){bytes[j*4]=n?20:200;bytes[j*4+1]=i?180:30;bytes[j*4+2]=n?150:40;bytes[j*4+3]=255;}[c->eye[i] replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:bytes bytesPerRow:32];vr::Texture_t t={&c->eye[i],vr::TextureType_DirectX,vr::ColorSpace_Linear};assert(comp->Submit((vr::EVREye)i,&t,&bounds,vr::Submit_Default)==vr::VRCompositorError_None);}
  comp->PostPresentHandoff();vx_native_vr_frame f;assert(!vx_xros_xrizer_acquire(c->host,&f));assert(f.pose.frame_id==101+n && f.pose.pose_id==201+n);pixels(c,f,n);if(!n)held=f;else assert(!vx_xros_xrizer_release(c->host,f.lease));}
 pixels(c,held,0);assert(!vx_xros_xrizer_release(c->host,held.lease));vx_native_vr_frame repeat;assert(!vx_xros_xrizer_acquire(c->host,&repeat) && repeat.pose.frame_id==102 && repeat.pose.pose_id==202);pixels(c,repeat,1);assert(!vx_xros_xrizer_release(c->host,repeat.lease));
 unsigned prior_acquisitions=image_acquisitions,prior_releases=image_releases;
 for(unsigned n=0;n<2;n++) {
  KlNativeFrameSample cancel={.frame_id=103+n,.pose_id=203+n,.predicted_display_time=c->base+(3+n)*10000000,.predicted_display_period=10000000,.should_render=XR_FALSE,.head_location_flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT,.local_from_head={.orientation={0,0,0,1}},.head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},.fov={{-.7f,.8f,.9f,-.6f},{-.73f,.82f,.9f,-.6f}}};
  assert(!vx_xros_xrizer_offer(c->host,&cancel));assert(comp->WaitGetPoses(nullptr,0,nullptr,0)==vr::VRCompositorError_None);
  vr::Texture_t t={&c->eye[0],vr::TextureType_DirectX,vr::ColorSpace_Linear};assert(comp->Submit(vr::Eye_Left,&t,&bounds,vr::Submit_Default)==vr::VRCompositorError_RequestFailed);
  comp->PostPresentHandoff();
  assert(image_acquisitions==prior_acquisitions && image_releases==prior_releases && empty_ends==n+1);
  assert(!vx_xros_xrizer_acquire(c->host,&repeat) && repeat.pose.frame_id==102 && repeat.pose.pose_id==202);assert(!vx_xros_xrizer_release(c->host,repeat.lease));
 }
 assert(waits==4 && begins==4 && ends==4 && empty_ends==2);
 cleanup(core);assert(c->begins==1 && c->ends==1 && c->exits==1 && c->acquired==c->released && c->copied==4);assert(!vx_xros_xrizer_retire(c->host));puts("actual native xrizer + xros host: two injected Metal pairs, pixel/ID/lease/repeat, no-render cancellation and cleanup pass; no guest or headset claim");
 }return 0;}
