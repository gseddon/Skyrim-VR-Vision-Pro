/* Native provider adapter: static symbols, one Apple compositor producer. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "xrizer_xros_host.h"
#include "xrizer_xros_optics.h"
#include "xrizer_xros_mailbox.h"
#include "apple_metal_host.h"
#include "image_sync_host.h"
#include "pose_math.h"

#define EVENT_CAPACITY 16
struct vx_xros_xrizer_host {
    pthread_mutex_t lock;
    vx_xros_xrizer_mode mode;
    vx_xros_xrizer_platform platform;
    vx_xros_xrizer_static_api api;
    KlNativeMetalHost metal;
    KlNativeImageSyncHost sync;
    KlNativeViewConfiguration views;
    KlNativeViewGeometry geometry;
    unsigned geometry_available;
    KlNativeSessionEvent events[EVENT_CAPACITY];
    unsigned event_head, event_count, surface_ready, attempted, registered, retiring, retired;
    unsigned readers, publishing;
    XrTime last_event_time;
    vx_native_vr *frames;
    vx_xros_frame_mailbox *mailbox;
    void *device, *queue;
};
static pthread_mutex_t singleton_lock = PTHREAD_MUTEX_INITIALIZER;
static vx_xros_xrizer_host *singleton;
static void keep(void *p) { if (p) CFRetain(p); }
static void drop(void *p) { if (p) CFRelease(p); }
static XrResult available(void *ctx) {
    vx_xros_xrizer_host *h=ctx; pthread_mutex_lock(&h->lock);
    int ready=h->surface_ready && !h->retiring && !h->retired; pthread_mutex_unlock(&h->lock);
    return ready ? XR_SUCCESS : XR_ERROR_FORM_FACTOR_UNAVAILABLE;
}
static XrResult get_views(void *ctx, KlNativeViewConfiguration *out) {
    vx_xros_xrizer_host *h=ctx; if (!out) return XR_ERROR_VALIDATION_FAILURE;
    pthread_mutex_lock(&h->lock); int ready=h->surface_ready && !h->retiring && !h->retired; if (ready) *out=h->views; pthread_mutex_unlock(&h->lock);
    return ready ? XR_SUCCESS : XR_ERROR_FORM_FACTOR_UNAVAILABLE;
}
static XrResult get_geometry(void *ctx, KlNativeViewGeometry *out) {
    vx_xros_xrizer_host *h=ctx; if (!out) return XR_ERROR_VALIDATION_FAILURE;
    pthread_mutex_lock(&h->lock);
    int ready=h->surface_ready && h->geometry_available && !h->retiring && !h->retired;
    if (ready) *out=h->geometry;
    pthread_mutex_unlock(&h->lock);
    return ready ? XR_SUCCESS : XR_ERROR_FORM_FACTOR_UNAVAILABLE;
}
static XrResult poll_event(void *ctx, KlNativeSessionEvent *out) {
    vx_xros_xrizer_host *h=ctx; if (!out) return XR_ERROR_VALIDATION_FAILURE;
    pthread_mutex_lock(&h->lock);
    if (!h->event_count) { pthread_mutex_unlock(&h->lock); return XR_EVENT_UNAVAILABLE; }
    *out=h->events[h->event_head]; h->event_head=(h->event_head+1)%EVENT_CAPACITY; --h->event_count;
    pthread_mutex_unlock(&h->lock); return XR_SUCCESS;
}
static XrResult begin_session(void *ctx, XrTime *time) {
    vx_xros_xrizer_host *h=ctx; return h->platform.begin(h->platform.context,time);
}
static XrResult end_session(void *ctx, XrTime *time) {
    vx_xros_xrizer_host *h=ctx;
    pthread_mutex_lock(&h->lock);
    int clear = !h->readers && !h->publishing && vx_xros_mailbox_drained(h->mailbox);
    if (clear) vx_native_vr_reset(h->frames);
    pthread_mutex_unlock(&h->lock);
    if (!clear) return XR_ERROR_CALL_ORDER_INVALID;
    return h->platform.end(h->platform.context,time);
}
static XrResult request_exit(void *ctx) {
    vx_xros_xrizer_host *h=ctx; return h->platform.request_exit(h->platform.context);
}
static XrResult sample_input(void *ctx, KlNativeInputSample *sample) {
    vx_xros_xrizer_host *h=ctx;
    if (!sample) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result=h->platform.sample_input(h->platform.context,sample);
    if (result != XR_SUCCESS) return result;
    if (sample->hand_connected[0] != XR_FALSE || sample->hand_connected[1] != XR_FALSE) return XR_ERROR_FEATURE_UNSUPPORTED;
    return XR_SUCCESS;
}
static XrResult sample_input3(void *ctx, KlNativeInputSample3 *sample) {
    vx_xros_xrizer_host *h=ctx;
    if (!sample) return XR_ERROR_VALIDATION_FAILURE;
    return h->platform.sample_input3(h->platform.context,sample);
}
static XrResult wait_frame(void *ctx, KlNativeFrameSample *sample) {
    return vx_xros_mailbox_wait(((vx_xros_xrizer_host *)ctx)->mailbox, 2000, sample);
}
static XrResult cancel_frame(void *ctx, void *ticket) {
    return vx_xros_mailbox_finish(((vx_xros_xrizer_host *)ctx)->mailbox,ticket) ? XR_ERROR_HANDLE_INVALID : XR_SUCCESS;
}
static void pose_matrix(XrPosef p, float m[16]) {
    vx_xros_pose_matrix(p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w, p.position.x, p.position.y, p.position.z, m);
}
static XrResult publish_pair(void *ctx, const KlNativeFramePair *pair) {
    vx_xros_xrizer_host *h=ctx; if (!pair || !pair->sample.ticket) return XR_ERROR_VALIDATION_FAILURE;
    if (!vx_xros_mailbox_matches(h->mailbox,&pair->sample)) return XR_ERROR_HANDLE_INVALID;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired || h->publishing) { pthread_mutex_unlock(&h->lock); return XR_ERROR_CALL_ORDER_INVALID; }
    h->publishing=1; pthread_mutex_unlock(&h->lock);
    XrResult result=XR_ERROR_RUNTIME_FAILURE;
    @autoreleasepool {
        id<MTLTexture> copies[2]={nil,nil};
        id<MTLCommandBuffer> cb=[(__bridge id<MTLCommandQueue>)h->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        if (!cb || !blit) goto done;
        for (unsigned i=0;i<2;i++) {
            const KlNativeFrameEye *e=&pair->eye[i]; id<MTLTexture> src=(__bridge id<MTLTexture>)e->texture;
            if (!src || src.device!=(__bridge id<MTLDevice>)h->device || !e->image_lease || src.sampleCount!=1 ||
                src.textureType!=MTLTextureType2DArray || src.pixelFormat!=(MTLPixelFormat)e->format ||
                (src.pixelFormat!=MTLPixelFormatRGBA8Unorm && src.pixelFormat!=MTLPixelFormatBGRA8Unorm &&
                 src.pixelFormat!=MTLPixelFormatRGBA8Unorm_sRGB && src.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB) ||
                e->array_layer>=src.arrayLength || e->rect.offset.x<0 || e->rect.offset.y<0 || e->rect.extent.width<=0 || e->rect.extent.height<=0 ||
                (NSUInteger)e->rect.offset.x+(NSUInteger)e->rect.extent.width>src.width ||
                (NSUInteger)e->rect.offset.y+(NSUInteger)e->rect.extent.height>src.height) { [blit endEncoding]; goto done; }
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                width:(NSUInteger)e->rect.extent.width height:(NSUInteger)e->rect.extent.height mipmapped:NO];
            d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageShaderRead;
            copies[i]=[(__bridge id<MTLDevice>)h->device newTextureWithDescriptor:d];
            if (!copies[i]) { [blit endEncoding]; result=XR_ERROR_OUT_OF_MEMORY; goto done; }
            [blit copyFromTexture:src sourceSlice:e->array_layer sourceLevel:0 sourceOrigin:MTLOriginMake(e->rect.offset.x,e->rect.offset.y,0)
                sourceSize:MTLSizeMake(e->rect.extent.width,e->rect.extent.height,1) toTexture:copies[i]
                destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        }
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status!=MTLCommandBufferStatusCompleted || cb.error) goto done;
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
        pthread_mutex_lock(&h->lock);
        if (vx_native_vr_begin(h->frames,&pose,&frame)) { pthread_mutex_unlock(&h->lock); goto done; }
        for (unsigned i=0;i<2;i++) {
            MTLPixelFormat f=copies[i].pixelFormat;
            vx_native_vr_eye eye={.resource=(__bridge void *)copies[i],.width=(uint32_t)copies[i].width,
                .height=(uint32_t)copies[i].height,.format=(uint32_t)f,.sample_count=1,
                .color_space=(f==MTLPixelFormatRGBA8Unorm_sRGB || f==MTLPixelFormatBGRA8Unorm_sRGB) ? VX_NATIVE_VR_COLOR_SRGB : VX_NATIVE_VR_COLOR_LINEAR,
                .u_max=1,.v_max=1};
            if (vx_native_vr_submit(h->frames,frame,i,pose.frame_id,pose.pose_id,&eye)) goto failed;
            submitted|=1u<<i;
        }
        for (unsigned i=0;i<2;i++) { if (vx_native_vr_complete(h->frames,frame,i)) goto failed; completed|=1u<<i; }
        if (vx_xros_mailbox_finish(h->mailbox,pair->sample.ticket)) goto failed;
        pthread_mutex_unlock(&h->lock); result=XR_SUCCESS; goto done;
failed:
        (void)vx_native_vr_cancel(h->frames,frame);
        for (unsigned i=0;i<2;i++) if ((submitted & (1u<<i)) && !(completed & (1u<<i))) (void)vx_native_vr_complete(h->frames,frame,i);
        pthread_mutex_unlock(&h->lock);
    }
done:
    pthread_mutex_lock(&h->lock); h->publishing=0; pthread_mutex_unlock(&h->lock);
    return result;
}
static void *factory(void *ctx, int *error) {
    vx_xros_xrizer_host *h=ctx; return h->api.client_core_factory("IVRClientCore_003",error);
}

vx_xros_xrizer_host *vx_xros_xrizer_create(vx_xros_xrizer_mode mode, void *device, void *queue,
                                           const vx_xros_xrizer_platform *platform) {
    if ((mode!=VX_XROS_XRIZER_PLATFORM && mode!=VX_XROS_XRIZER_INJECTED_TEST) || !device || !queue || !platform ||
        platform->version!=VX_XROS_XRIZER_API_VERSION || platform->size<sizeof(*platform) ||
        !platform->begin || !platform->end || !platform->request_exit || !platform->sample_input) return NULL;
    id<MTLDevice> d=(__bridge id<MTLDevice>)device; id<MTLCommandQueue> q=(__bridge id<MTLCommandQueue>)queue;
    if (q.device!=d) return NULL;
    pthread_mutex_lock(&singleton_lock);
    if (singleton) { pthread_mutex_unlock(&singleton_lock); return NULL; }
    vx_xros_xrizer_host *h=calloc(1,sizeof *h);
    if (!h) { pthread_mutex_unlock(&singleton_lock); return NULL; }
    if (pthread_mutex_init(&h->lock,NULL)) { free(h); pthread_mutex_unlock(&singleton_lock); return NULL; }
    h->mode=mode; h->platform=*platform; h->device=(void *)CFRetain(device); h->queue=(void *)CFRetain(queue);
    h->mailbox=vx_xros_mailbox_create(); h->frames=vx_native_vr_create(keep,drop);
    if (!h->mailbox || !h->frames || kl_apple_metal_host_create(device,queue,&h->metal)!=XR_SUCCESS ||
        kl_apple_metal_image_sync(&h->metal,&h->sync)!=XR_SUCCESS) {
        /* No provider/Rust callbacks have been installed; destroy only what
         * was allocated locally. All resources are still excluded from users. */
        if (h->metal.context) (void)kl_apple_metal_host_destroy(&h->metal);
        if (h->frames) (void)vx_native_vr_destroy(h->frames);
        if (h->mailbox) { vx_xros_mailbox_stop(h->mailbox); (void)vx_xros_mailbox_destroy(h->mailbox); }
        CFRelease(h->device); CFRelease(h->queue); pthread_mutex_destroy(&h->lock); free(h);
        pthread_mutex_unlock(&singleton_lock); return NULL;
    }
    singleton=h; pthread_mutex_unlock(&singleton_lock); return h;
}
int vx_xros_xrizer_record_destination(void *context, void *texture, void *command_buffer) {
    vx_xros_xrizer_host *h=context;
    return h && kl_apple_metal_record_texture_writes(&h->metal,texture,command_buffer)==XR_SUCCESS ? 0 : -1;
}
int vx_xros_xrizer_register(vx_xros_xrizer_host *h, const vx_xros_xrizer_static_api *api, const XrizerMetalHost *source) {
    if (!h || !api || api->version!=VX_XROS_XRIZER_API_VERSION || api->size<sizeof(*api) ||
        !api->configure_provider || !api->configure_metal || !api->client_core_factory || !api->install_factory ||
        !source || source->abi_version!=1 || source->struct_size<sizeof(*source) || source->device!=h->device ||
        source->command_queue!=h->queue || !source->acquire || !source->copy_complete || !source->release) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->attempted || h->retiring || h->retired) { pthread_mutex_unlock(&h->lock); return -1; }
    h->attempted=1; h->api=*api; pthread_mutex_unlock(&h->lock);
    KlNativeHost host={.version=1,.size=sizeof(host),.context=h,.hmd_available=available};
    KlNativeViewHost views={KL_NATIVE_VIEW_HOST_VERSION,sizeof(views),h,get_views};
    KlNativeViewGeometryHost geometry={KL_NATIVE_VIEW_GEOMETRY_VERSION,sizeof(geometry),h,get_geometry};
    KlNativeSessionHost session={KL_NATIVE_SESSION_HOST_VERSION,sizeof(session),h,poll_event,begin_session,end_session,request_exit};
    KlNativeFrameHost frame={KL_NATIVE_FRAME_HOST_VERSION,sizeof(frame),h,wait_frame,publish_pair,cancel_frame};
    KlNativeInputHost input={KL_NATIVE_INPUT_HOST_VERSION,sizeof(input),h,sample_input};
    KlNativeInputHost3 input3={KL_NATIVE_INPUT_HOST_VERSION_3,sizeof(input3),h,sample_input3};
    int controllers=h->platform.size>=sizeof(h->platform) && h->platform.sample_input3;
    if (kl_native_configure(&host)!=XR_SUCCESS || kl_native_configure_views(&views)!=XR_SUCCESS ||
        kl_native_configure_view_geometry(&geometry)!=XR_SUCCESS ||
        kl_native_configure_metal(&h->metal)!=XR_SUCCESS || kl_native_configure_image_sync(&h->sync)!=XR_SUCCESS ||
        kl_native_configure_session(&session)!=XR_SUCCESS || kl_native_configure_frame(&frame)!=XR_SUCCESS ||
        (controllers ? kl_native_configure_input3(&input3) : kl_native_configure_input(&input))!=XR_SUCCESS || api->configure_provider(kl_native_get_instance_proc_addr) ||
        api->configure_metal(source) || api->install_factory(factory,h)) return -1;
    pthread_mutex_lock(&h->lock); h->registered=1; pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_surface(vx_xros_xrizer_host *h, int ready, const KlNativeViewConfiguration *views) {
    if (!h || (ready!=0 && ready!=1) || (ready && !views)) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired) { pthread_mutex_unlock(&h->lock); return -1; }
    if (ready) h->views=*views;
    h->surface_ready=(unsigned)ready;
    if (!ready) vx_xros_mailbox_invalidate(h->mailbox);
    pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_geometry(vx_xros_xrizer_host *h, const KlNativeViewGeometry *geometry) {
    if (!h || (geometry && (geometry->version!=KL_NATIVE_VIEW_GEOMETRY_VERSION || geometry->struct_size<sizeof(*geometry)))) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired) { pthread_mutex_unlock(&h->lock); return -1; }
    if (geometry) h->geometry=*geometry;
    else memset(&h->geometry,0,sizeof h->geometry);
    h->geometry_available=geometry!=NULL;
    pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_event(vx_xros_xrizer_host *h, KlNativeSessionEvent event) {
    if (!h || event.type<KL_NATIVE_SESSION_READY || event.type>KL_NATIVE_SESSION_EXITING || event.time<=0) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired || h->event_count==EVENT_CAPACITY || event.time<h->last_event_time) { pthread_mutex_unlock(&h->lock); return -1; }
    h->events[(h->event_head+h->event_count)%EVENT_CAPACITY]=event; ++h->event_count; h->last_event_time=event.time;
    if (event.type==KL_NATIVE_SESSION_STOPPING || event.type==KL_NATIVE_SESSION_LOSS) vx_xros_mailbox_stop(h->mailbox);
    pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_offer(vx_xros_xrizer_host *h, const KlNativeFrameSample *sample) {
    if (!h) return -1;
    pthread_mutex_lock(&h->lock);
    int result=h->surface_ready && !h->retiring && !h->retired ? vx_xros_mailbox_offer(h->mailbox,sample) : -1;
    pthread_mutex_unlock(&h->lock); return result;
}
int vx_xros_xrizer_acquire(vx_xros_xrizer_host *h, vx_native_vr_frame *out) {
    if (!h || !out) return -1;
    pthread_mutex_lock(&h->lock);
    int result=(h->retiring || h->retired) ? -1 : vx_native_vr_acquire(h->frames,out);
    if (!result) ++h->readers;
    pthread_mutex_unlock(&h->lock); return result;
}
int vx_xros_xrizer_release(vx_xros_xrizer_host *h, uint64_t lease) {
    if (!h) return -1;
    pthread_mutex_lock(&h->lock);
    int result=!h->readers ? -1 : vx_native_vr_release(h->frames,lease);
    if (!result) --h->readers;
    pthread_mutex_unlock(&h->lock); return result;
}
int vx_xros_xrizer_retire(vx_xros_xrizer_host *h) {
    if (!h) return -1;
    pthread_mutex_lock(&h->lock);
    h->retiring=1;
    vx_xros_mailbox_stop(h->mailbox);
    int ok=!h->retired && !h->publishing && !h->readers && vx_xros_mailbox_drained(h->mailbox);
    if (ok) { vx_native_vr_reset(h->frames); h->surface_ready=0; h->retired=1; }
    pthread_mutex_unlock(&h->lock);
    return ok ? 0 : -1;
}
