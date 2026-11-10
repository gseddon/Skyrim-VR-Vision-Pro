// Offscreen native stereo presenter integration. Requires a Metal GPU; never a headset.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "native_vr.h"
#include "native_openvr.h"
#include "xros_vr.h"
static vx_native_vr *queue;
static vx_native_vr_pose published;
int vx_native_openvr_enabled(void) { return 1; }
vx_native_vr *vx_native_openvr_queue(void) { return queue; }
int vx_native_openvr_set_state(const vx_native_vr_pose *p, const vx_native_openvr_controller c[2]) { (void)c; published = *p; return 0; }
int vx_native_openvr_set_render_size(uint32_t w, uint32_t h) { return w && h ? 0 : -1; }
void vx_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); }
static void retain(void *p) { (void)CFBridgingRetain((__bridge id)p); }
static void release(void *p) { CFRelease(p); }
static void identity(float *m) { memset(m, 0, 16 * sizeof(float)); for (int i=0;i<4;i++) m[i*5]=1; }
static id<MTLTexture> texture(id<MTLDevice> dev, MTLPixelFormat fmt, MTLTextureUsage usage, MTLStorageMode storage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:16 height:16 mipmapped:NO];
    d.usage=usage; d.storageMode=storage; return [dev newTextureWithDescriptor:d];
}
static void pair(id<MTLTexture> l, id<MTLTexture> r, vx_native_vr_color_space cs, float maxu) {
    vx_native_vr_pose p={0}; identity(p.origin_from_head); identity(p.head_from_eye[0]); identity(p.head_from_eye[1]);
    p.frame_id=42; p.pose_id=17; p.pose_time=10; p.tracking_valid=1;
    for (int i=0;i<2;i++) { p.frustum[i][0]=-1; p.frustum[i][1]=1; p.frustum[i][2]=-1; p.frustum[i][3]=1; }
    vx_native_vr_handle h; assert(vx_native_vr_begin(queue, &p, &h)==0);
    vx_native_vr_eye e={ .width=16,.height=16,.format=MTLPixelFormatRGBA8Unorm,.sample_count=1,.color_space=cs,.u_max=maxu,.v_max=1 };
    e.resource=(__bridge void *)l; assert(vx_native_vr_submit(queue,h,0,42,17,&e)==0);
    e.resource=(__bridge void *)r; e.u_max=1; assert(vx_native_vr_submit(queue,h,1,42,17,&e)==0);
    assert(vx_native_vr_complete(queue,h,0)==0 && vx_native_vr_complete(queue,h,1)==0);
}
static uint8_t last_frame[16*16*4];
static void draw_to(id<MTLCommandQueue> cq, MTLPixelFormat outfmt, int eye, float angle, uint8_t *pixel) {
    float head[16], eyes[32], f[8]={-1,1,-1,1,-1,1,-1,1}, view[16], tan[4]={1,1,1,1};
    identity(head); identity(eyes); identity(eyes+16); identity(view);
    view[0]=cosf(angle); view[2]=-sinf(angle); view[8]=sinf(angle); view[10]=cosf(angle);
    assert(vx_xros_native_begin(head,eyes,f,10.1,1,NULL)==1);
    assert(published.tracking_valid && published.pose_time==10.1);
    id<MTLDevice> dev=cq.device;
    id<MTLTexture> color=texture(dev,outfmt,MTLTextureUsageRenderTarget,MTLStorageModeShared);
    id<MTLTexture> depth=texture(dev,MTLPixelFormatDepth32Float,MTLTextureUsageRenderTarget,MTLStorageModePrivate);
    id<MTLCommandBuffer> cb=[cq commandBuffer];
    assert(vx_xros_native_draw_eye((__bridge void *)cb,eye,view,tan,(__bridge void *)color,(__bridge void *)depth));
    vx_xros_native_end((__bridge void *)cb); [cb commit]; [cb waitUntilCompleted]; assert(cb.status==MTLCommandBufferStatusCompleted);
    uint8_t data[16*16*4]; [color getBytes:data bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
    memcpy(pixel, data+(8*16+8)*4, 4); memcpy(last_frame, data, sizeof data);
}
static void draw(id<MTLCommandQueue> cq, int eye, float angle, uint8_t *pixel) { draw_to(cq, MTLPixelFormatRGBA8Unorm, eye, angle, pixel); }
int main(void) { @autoreleasepool {
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); assert(dev);
    id<MTLCommandQueue> cq=[dev newCommandQueue]; assert(cq);
    queue=vx_native_vr_create(retain,release); assert(queue);
    id<MTLTexture> l=texture(dev,MTLPixelFormatRGBA8Unorm,MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView,MTLStorageModeShared);
    id<MTLTexture> r=texture(dev,MTLPixelFormatRGBA8Unorm,MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView,MTLStorageModeShared);
    uint8_t a[16*16*4],b[16*16*4];
    for(int y=0;y<16;y++) for(int x=0;x<16;x++) { int i=(y*16+x)*4; a[i]=x<8?128:0; a[i+1]=x<8?0:128; a[i+2]=0; a[i+3]=255; b[i]=b[i+1]=0; b[i+2]=128; b[i+3]=255; }
    [l replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:a bytesPerRow:64];
    [r replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:b bytesPerRow:64];
    uint8_t p[4];
    pair(l,r,VX_NATIVE_VR_COLOR_LINEAR,0.5f); draw(cq,0,0,p); assert(p[0]>120 && p[1]<8);
    draw(cq,1,0,p); assert(p[2]>120 && p[0]<8);
    pair(l,r,VX_NATIVE_VR_COLOR_LINEAR,1); draw(cq,0,(float)M_PI/6,p); assert(p[1]>120 && p[0]<8);
    pair(l,r,VX_NATIVE_VR_COLOR_SRGB,0.5f); draw(cq,0,0,p); assert(p[0]>48 && p[0]<65 && p[1]<8);
    /* Dark smoke on the Skyrim title screen: gamma-coded bytes 1 and 2 in a plain UNORM image, shown on the headset's sRGB drawable.
     * Labelled sRGB (what the xros host now does for 8-bit UNORM) the drawable holds the stored bytes; labelled linear they are encoded twice
     * (1 -> 13, 2 -> 22: the hard coloured bands the user saw). */
    uint8_t dark[16*16*4]; for (int i=0;i<16*16;i++) { dark[i*4]=1; dark[i*4+1]=2; dark[i*4+2]=2; dark[i*4+3]=255; }
    [l replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:dark bytesPerRow:64];
    [r replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:dark bytesPerRow:64];
    pair(l,r,VX_NATIVE_VR_COLOR_SRGB,1); draw_to(cq,MTLPixelFormatRGBA8Unorm_sRGB,0,0,p);
    fprintf(stderr,"dark bytes 1,2,2 via sRGB label on sRGB drawable: %u %u %u\n",p[0],p[1],p[2]);
    assert(p[0]==1 && p[1]==2 && p[2]==2);
    pair(l,r,VX_NATIVE_VR_COLOR_LINEAR,1); draw_to(cq,MTLPixelFormatRGBA8Unorm_sRGB,0,0,p);
    fprintf(stderr,"dark bytes 1,2,2 via linear label on sRGB drawable (double encode): %u %u %u\n",p[0],p[1],p[2]);
    assert(p[0]>=12 && p[1]>=20);
    /* Sharpness under a fractional shift (the shimmer investigation): a 4-texel-period wave (1-texel stripes at Nyquist vanish under any filter), the head turned so the image moves half a texel.
     * Bilinear loses about half the contrast; VXRT_REPROJ_FILTER=bicubic (Catmull-Rom) keeps more. */
    uint8_t stripes[16*16*4]; for (int y=0;y<16;y++) for (int x=0;x<16;x++) { int i=(y*16+x)*4; stripes[i]=stripes[i+1]=stripes[i+2]=(uint8_t)lrintf(127.5f+127.5f*sinf((float)M_PI*0.5f*(float)x)); stripes[i+3]=255; }
    [l replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:stripes bytesPerRow:64];
    [r replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:stripes bytesPerRow:64];
    const char *filter=getenv("VXRT_REPROJ_FILTER"); int bicubic=filter && !strcmp(filter,"bicubic");
    pair(l,r,VX_NATIVE_VR_COLOR_LINEAR,1);
    for (int step=0; step<2; step++) {
        float angle = step ? 0.0625f : 0.f;        // 8 texels per unit of tangent: 0.0625 rad is half a texel
        draw(cq,0,angle,p);
        int lo=255,hi=0; for (int x=6;x<10;x++) { int v=last_frame[(8*16+x)*4]; if (v<lo) lo=v; if (v>hi) hi=v; }
        fprintf(stderr,"stripes, shift %.1f texel, %s: contrast %d of 255\n",step?0.5:0.0,bicubic?"bicubic":"bilinear",hi-lo);
        if (!step) assert(hi-lo>200);
        else if (bicubic) assert(hi-lo>150); else assert(hi-lo<145);        /* measured: bilinear 129, Catmull-Rom 162 */
    }
    vx_native_vr_reset(queue); assert(vx_native_vr_destroy(queue)==0);
} return 0; }
