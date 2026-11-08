// Native stereo presentation, shared by the visionOS compositor and offscreen tests.
#import <Metal/Metal.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "xros_vr.h"
void vx_log(const char *fmt, ...);
static void mul4(const float *a, const float *b, float *o) {
    for (int c=0; c<4; c++) for (int r=0; r<4; r++) {
        float v=0; for (int k=0; k<4; k++) v += a[k*4+r]*b[c*4+k];
        o[c*4+r]=v;
    }
}
// Native OpenVR eyes are already stereo. Rotate rays between the pose that produced each
// pair and the display pose; without scene depth translation cannot be reconstructed.
#include "native_vr.h"
#include "native_openvr.h"
static vx_native_vr_frame g_native_frame;
static vx_native_vr *g_native_queue;
static int g_native_held;
static uint64_t g_native_pose_serial;

int vx_xros_native_enabled(void) { return vx_native_openvr_enabled(); }
int vx_xros_native_set_render_size(uint32_t w, uint32_t h) { return vx_native_openvr_set_render_size(w, h); }
int vx_xros_native_begin(const float head[16], const float eyes[32], const float frustums[8], double time, int valid, const vx_native_openvr_controller controllers[2]) {
    vx_native_vr_pose p = {0};
    p.frame_id = p.pose_id = ++g_native_pose_serial;
    p.pose_time = time; p.tracking_valid = valid != 0;
    memcpy(p.origin_from_head, head, sizeof p.origin_from_head);
    memcpy(p.head_from_eye, eyes, sizeof p.head_from_eye);
    memcpy(p.frustum, frustums, sizeof p.frustum);
    vx_native_openvr_controller state[2] = {0};
    if (controllers) memcpy(state, controllers, sizeof state);
    if (vx_native_openvr_set_state(&p, state) != 0) return 0;
    g_native_held = 0;
    g_native_queue = vx_native_openvr_queue();
    if (!valid || !g_native_queue) return 0;
    if (!vx_xros_native_acquire_succeeded(vx_native_vr_acquire(g_native_queue, &g_native_frame))) return 0;
    g_native_held = 1;
    // Do not keep showing a previously submitted frame indefinitely after loading or tracking loss.
    double age = time - g_native_frame.pose.pose_time;
    return g_native_frame.pose.tracking_valid && isfinite(age) && age >= -0.1 && age <= 1.0;
}

// float4-aligned layout matches the Metal shader's parameter structure.
typedef struct { float rot[12], src[4], dst[4], bounds[4]; } native_params;
static NSString *const g_native_shader = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct P { float4 r[3]; float4 src; float4 dst; float4 bounds; };\n"
"struct V { float4 position [[position]]; float2 uv; };\n"
"vertex V nv(uint i [[vertex_id]]) { float2 p=float2((i==1)?3:-1,(i==2)?3:-1); return {float4(p,0,1),float2((p.x+1)*.5,(1-p.y)*.5)}; }\n"
"fragment float4 nf(V v [[stage_in]], texture2d<float> img [[texture(0)]], constant P &p [[buffer(0)]]) {\n"
" float2 t=float2(mix(-p.dst.x,p.dst.y,v.uv.x),mix(p.dst.z,-p.dst.w,v.uv.y));\n"
" float3 d=float3(t,-1); float3 s=float3(dot(p.r[0].xyz,d),dot(p.r[1].xyz,d),dot(p.r[2].xyz,d));\n"
" if (s.z>=-0.00001) return float4(0,0,0,1); float2 q=float2(s.x/-s.z,-s.y/-s.z);\n"
" float2 uv=float2((q.x-p.src.x)/(p.src.y-p.src.x),(q.y-p.src.z)/(p.src.w-p.src.z));\n"
" if (any(uv<0) || any(uv>1)) return float4(0,0,0,1);\n"
" constexpr sampler smp(coord::normalized,filter::linear,address::clamp_to_edge);\n"
" return img.sample(smp,mix(p.bounds.xy,p.bounds.zw,uv)); }\n";

int vx_xros_native_draw_eye(void *cbp, int eye, const float view[16], const float tan[4], void *outp, void *depthp) {
    if (!g_native_held || !g_native_frame.pose.tracking_valid || eye < 0 || eye > 1) return 0;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
    id<MTLTexture> depth = (__bridge id<MTLTexture>)depthp;
    vx_native_vr_eye *e = &g_native_frame.eye[eye];
    id<MTLTexture> tex = (__bridge id<MTLTexture>)e->resource;
    if (!cb || !out || !depth || !tex || tex.textureType != MTLTextureType2D || out.textureType != MTLTextureType2D ||
        depth.textureType != MTLTextureType2D || tex.sampleCount != 1 || tex.width != e->width || tex.height != e->height ||
        tex.pixelFormat != e->format || e->sample_count != 1 || (e->color_space != VX_NATIVE_VR_COLOR_LINEAR && e->color_space != VX_NATIVE_VR_COLOR_SRGB)) return 0;
    MTLPixelFormat fmt = tex.pixelFormat, wanted = fmt;
    if (fmt == MTLPixelFormatRGBA8Unorm || fmt == MTLPixelFormatRGBA8Unorm_sRGB)
        wanted = e->color_space == VX_NATIVE_VR_COLOR_SRGB ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
    else if (fmt == MTLPixelFormatBGRA8Unorm || fmt == MTLPixelFormatBGRA8Unorm_sRGB)
        wanted = e->color_space == VX_NATIVE_VR_COLOR_SRGB ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
    else if (e->color_space != VX_NATIVE_VR_COLOR_LINEAR) return 0;
    if (wanted != fmt) { tex = [tex newTextureViewWithPixelFormat:wanted]; if (!tex) return 0; }
    native_params p = {0};
    float source[16]; mul4(g_native_frame.pose.origin_from_head, g_native_frame.pose.head_from_eye[eye], source);
    // view is current eye-from-origin. Its transposed rotation is origin-from-current-eye.
    for (int r=0; r<3; r++) for (int c=0; c<3; c++)
        for (int k=0; k<3; k++) p.rot[r*4+c] += source[r*4+k] * view[k*4+c];
    memcpy(p.src, g_native_frame.pose.frustum[eye], sizeof p.src);
    memcpy(p.dst, tan, sizeof p.dst);
    p.bounds[0]=e->u_min; p.bounds[1]=e->v_min; p.bounds[2]=e->u_max; p.bounds[3]=e->v_max;
    if (!(p.src[0] < p.src[1] && p.src[2] < p.src[3])) return 0;
    static id<MTLLibrary> lib;
    static id<MTLRenderPipelineState> pipeline;
    static MTLPixelFormat colorFormat, depthFormat;
    if (!lib) { NSError *err = nil; lib = [cb.device newLibraryWithSource:g_native_shader options:nil error:&err]; if (!lib) vx_log("native VR shader: %s", err.localizedDescription.UTF8String); }
    if (!lib) return 0;
    if (!pipeline || colorFormat != out.pixelFormat || depthFormat != depth.pixelFormat) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"nv"]; pd.fragmentFunction = [lib newFunctionWithName:@"nf"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat; pd.depthAttachmentPixelFormat = depth.pixelFormat;
        NSError *err = nil; pipeline = [cb.device newRenderPipelineStateWithDescriptor:pd error:&err];
        colorFormat = out.pixelFormat; depthFormat = depth.pixelFormat;
        if (!pipeline) { vx_log("native VR pipeline: %s", err.localizedDescription.UTF8String); return 0; }
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 0; pass.depthAttachment.storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    if (!enc) return 0;
    [enc setRenderPipelineState:pipeline]; [enc setFragmentTexture:tex atIndex:0]; [enc setFragmentBytes:&p length:sizeof p atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding];
    return 1;
}
void vx_xros_native_end(void *cbp) {
    if (!g_native_held) return;
    vx_native_vr *q = g_native_queue; uint64_t lease = g_native_frame.lease;
    g_native_held = 0;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    if (!cb) { vx_native_vr_release(q, lease); return; }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; vx_native_vr_release(q, lease); }];
}
