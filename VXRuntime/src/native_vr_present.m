// Native stereo presentation, shared by the visionOS compositor and offscreen tests.
#import <Metal/Metal.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "xros_vr.h"
#include "xrizer_xros_optics.h"
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
#ifdef VXRT_XRIZER_XROS_FIXTURE
#include "xrizer_xros_fixture.h"
static int g_fixture_held;
#endif
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
    return vx_xros_pose_is_current(time, g_native_frame.pose.pose_time, g_native_frame.pose.tracking_valid);
}

#ifdef VXRT_XRIZER_XROS_FIXTURE
/* What the compositor showed, per compositor frame (the compositor thread only). A pair is FRESH the first time its
 * provider frame id is presented and a REPEAT every later time (the game has not submitted a newer pair, the pose is
 * re-projected); a frame the game has not produced yet or whose pose is stale is counted apart, never as fresh. The
 * age is the compositor's presentation time minus the pose time the pair was rendered for (the xrWaitFrame prediction),
 * in the compositor/Mach seconds epoch. */
static struct { unsigned long long fresh, repeat, stale, none, eyes; uint64_t last_id; double age_sum, age_max, rep_age_max;
               unsigned long long i_fresh, i_repeat, i_stale, i_none; } g_imm;
int vx_xros_fixture_present_begin(double time) {
    g_native_held=0; g_fixture_held=0;
    if(vx_xros_fixture_acquire(&g_native_frame)) { ++g_imm.none; ++g_imm.i_none; return 0; }
    g_native_held=1;g_fixture_held=1;
    int current=vx_xros_pose_is_current(time, g_native_frame.pose.pose_time, g_native_frame.pose.tracking_valid);
    double age=time-g_native_frame.pose.pose_time;
    if(!current) { ++g_imm.stale; ++g_imm.i_stale; }
    else if(g_native_frame.pose.frame_id>g_imm.last_id) {
        g_imm.last_id=g_native_frame.pose.frame_id; ++g_imm.fresh; ++g_imm.i_fresh; g_imm.age_sum+=age;
        if(age>g_imm.age_max)g_imm.age_max=age;
    } else { ++g_imm.repeat; ++g_imm.i_repeat; if(age>g_imm.rep_age_max)g_imm.rep_age_max=age; }
    return current;
}
/* JSON fields for the host log: totals and this interval's counts (the interval restarts here). */
int vx_xros_immersive_stats(char *buf, uint32_t len) {
    int n=snprintf(buf,len,"\"imm_fresh\":%llu,\"imm_repeat\":%llu,\"imm_stale\":%llu,\"imm_none\":%llu,\"imm_eyes_drawn\":%llu,"
        "\"imm_interval_fresh\":%llu,\"imm_interval_repeat\":%llu,\"imm_interval_stale\":%llu,\"imm_interval_none\":%llu,"
        "\"imm_age_ms_mean_fresh\":%.2f,\"imm_age_ms_max_fresh\":%.2f,\"imm_age_ms_max_repeat\":%.2f,\"imm_last_frame\":%llu",
        g_imm.fresh,g_imm.repeat,g_imm.stale,g_imm.none,g_imm.eyes,g_imm.i_fresh,g_imm.i_repeat,g_imm.i_stale,g_imm.i_none,
        g_imm.fresh ? g_imm.age_sum/g_imm.fresh*1e3 : 0.0,g_imm.age_max*1e3,g_imm.rep_age_max*1e3,(unsigned long long)g_imm.last_id);
    g_imm.i_fresh=g_imm.i_repeat=g_imm.i_stale=g_imm.i_none=0;
    return n;
}
#endif

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
#ifdef VXRT_XRIZER_XROS_FIXTURE
    ++g_imm.eyes;
#endif
    return 1;
}
#ifdef VXRT_XRIZER_XROS_FIXTURE
// Simulator inspection of a mono drawable: each eye of the acquired provider pair
// fills its own half of view 0, texel for texel (nearest, no reprojection). The
// readback after it samples every 4x3 source texel centre in the drawable itself.
static NSString *const g_inspect_shader = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 position [[position]]; float2 uv; };\n"
"vertex V iv(uint i [[vertex_id]]) { float2 p=float2((i==1)?3:-1,(i==2)?3:-1); return {float4(p,0,1),float2((p.x+1)*.5,(1-p.y)*.5)}; }\n"
"fragment float4 inf(V v [[stage_in]], texture2d<float> img [[texture(0)]], constant float4 &b [[buffer(0)]]) {\n"
" constexpr sampler smp(coord::normalized,filter::nearest,address::clamp_to_edge);\n"
" return img.sample(smp,mix(b.xy,b.zw,v.uv)); }\n";
int vx_xros_fixture_draw_inspection(void *cbp, int view, void *outp, void *depthp) {
    if (!g_native_held || !g_fixture_held || view != 0 || !g_native_frame.pose.tracking_valid) return 0;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp, depth = (__bridge id<MTLTexture>)depthp;
    static int refused;
    MTLPixelFormat of = out.pixelFormat;
    int bgra = of == MTLPixelFormatBGRA8Unorm || of == MTLPixelFormatBGRA8Unorm_sRGB;
    if (!cb || !out || !depth || out.textureType != MTLTextureType2D || out.width < 8 || out.height < 3 ||
        (!bgra && of != MTLPixelFormatRGBA8Unorm && of != MTLPixelFormatRGBA8Unorm_sRGB)) {
        if (!refused++) vx_log("xrizer xros fixture: drawable inspection refused (format %lu, %lux%lu)", (unsigned long)of,
                               (unsigned long)out.width, (unsigned long)out.height);
        return 0;
    }
    id<MTLTexture> eyes[2];
    for (int i = 0; i < 2; i++) {
        vx_native_vr_eye *e = &g_native_frame.eye[i];
        id<MTLTexture> tex = (__bridge id<MTLTexture>)e->resource;
        if (!tex || tex.textureType != MTLTextureType2D || tex.sampleCount != 1 || e->sample_count != 1 || tex.width != e->width ||
            tex.height != e->height || tex.pixelFormat != e->format || tex.device != cb.device ||
            (e->color_space != VX_NATIVE_VR_COLOR_LINEAR && e->color_space != VX_NATIVE_VR_COLOR_SRGB)) return 0;
        MTLPixelFormat f = tex.pixelFormat, want = f;
        if (f == MTLPixelFormatRGBA8Unorm || f == MTLPixelFormatRGBA8Unorm_sRGB)
            want = e->color_space == VX_NATIVE_VR_COLOR_SRGB ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
        else if (f == MTLPixelFormatBGRA8Unorm || f == MTLPixelFormatBGRA8Unorm_sRGB)
            want = e->color_space == VX_NATIVE_VR_COLOR_SRGB ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
        else if (e->color_space != VX_NATIVE_VR_COLOR_LINEAR) return 0;
        eyes[i] = want == f ? tex : [tex newTextureViewWithPixelFormat:want];
        if (!eyes[i]) return 0;
    }
    static id<MTLRenderPipelineState> pipeline;
    static MTLPixelFormat pc, pd;
    if (!pipeline || pc != of || pd != depth.pixelFormat) {
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:g_inspect_shader options:nil error:&err];
        if (!lib) { vx_log("xrizer xros fixture: inspection shader: %s", err.localizedDescription.UTF8String); return 0; }
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"iv"]; d.fragmentFunction = [lib newFunctionWithName:@"inf"];
        d.colorAttachments[0].pixelFormat = of; d.depthAttachmentPixelFormat = depth.pixelFormat;
        pipeline = [cb.device newRenderPipelineStateWithDescriptor:d error:&err];
        pc = of; pd = depth.pixelFormat;
        if (!pipeline) { vx_log("xrizer xros fixture: inspection pipeline: %s", err.localizedDescription.UTF8String); return 0; }
    }
    id<MTLBuffer> data = [cb.device newBufferWithLength:96 options:MTLResourceStorageModeShared];
    if (!data) return 0;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 0; pass.depthAttachment.storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    if (!enc) return 0;
    NSUInteger half = out.width / 2, h = out.height;
    [enc setRenderPipelineState:pipeline];
    for (int i = 0; i < 2; i++) {
        vx_native_vr_eye *e = &g_native_frame.eye[i];
        float b[4] = {e->u_min, e->v_min, e->u_max, e->v_max};
        [enc setViewport:(MTLViewport){(double)(i * half), 0, (double)half, (double)h, 0, 1}];
        [enc setFragmentTexture:eyes[i] atIndex:0]; [enc setFragmentBytes:b length:sizeof b atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding];
    g_imm.eyes += 2;
    // Texel centres of each eye's source bounds, in drawable pixels. Only the
    // 4x3 fixture eyes are sampled; other sizes are presented but not audited.
    int audit = g_native_frame.eye[0].width == 4 && g_native_frame.eye[0].height == 3 &&
                g_native_frame.eye[1].width == 4 && g_native_frame.eye[1].height == 3;
    if (audit) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (!blit) return 1;
        for (int i = 0; i < 2; i++) for (int y = 0; y < 3; y++) for (int x = 0; x < 4; x++) {
            NSUInteger px = i * half + (NSUInteger)((x + 0.5) * half / 4), py = (NSUInteger)((y + 0.5) * h / 3);
            [blit copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(px, py, 0) sourceSize:MTLSizeMake(1, 1, 1)
                         toBuffer:data destinationOffset:((i * 3 + y) * 4 + x) * 4 destinationBytesPerRow:4 destinationBytesPerImage:4];
        }
        [blit endEncoding];
        uint64_t frame_id = g_native_frame.pose.frame_id, pose_id = g_native_frame.pose.pose_id;
        uint32_t format = (uint32_t)of;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            unsigned char rgba[96]; const unsigned char *src = data.contents;
            for (int k = 0; k < 24; k++) {
                rgba[k * 4 + 0] = src[k * 4 + (bgra ? 2 : 0)]; rgba[k * 4 + 1] = src[k * 4 + 1];
                rgba[k * 4 + 2] = src[k * 4 + (bgra ? 0 : 2)]; rgba[k * 4 + 3] = src[k * 4 + 3];
            }
            vx_xros_fixture_record_drawable(frame_id, pose_id, done.status == MTLCommandBufferStatusCompleted && !done.error, format, rgba);
        }];
    }
    return 1;
}
#endif
void vx_xros_native_end(void *cbp) {
    if (!g_native_held) return;
    vx_native_vr *q = g_native_queue; uint64_t lease = g_native_frame.lease;
    g_native_held = 0;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
#ifdef VXRT_XRIZER_XROS_FIXTURE
    if(g_fixture_held) {
        g_fixture_held=0;
        if(!cb) { vx_xros_fixture_release(lease); return; }
        uint64_t frame_id=g_native_frame.pose.frame_id, pose_id=g_native_frame.pose.pose_id;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            vx_log("xrizer xros fixture: drawable command completion frame=%llu pose=%llu status=%lu error=%s",
                (unsigned long long)frame_id,(unsigned long long)pose_id,(unsigned long)done.status,done.error ? "yes" : "no");
            vx_xros_fixture_release(lease);
        }];
        return;
    }
#endif
    if (!cb) { vx_native_vr_release(q, lease); return; }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; vx_native_vr_release(q, lease); }];
}
