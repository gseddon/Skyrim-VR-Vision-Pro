// The 8-bit dither variant of a pixel shader (vx_d3d11_dither_source): a hand-written shader in the
// translator's shape outputs 1.4/255 (between two codes) and 1/255 (exactly a code) into an RGBA8 target. The dithered
// variant must give a mix of codes 1 and 2 averaging 1.4 for the first and always 1 for the second. Needs a Metal GPU.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
extern NSString *vx_d3d11_dither_source(const char *msl);
static const char *const kMsl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VxIn { float4 v0 [[user(r0)]]; };\n"
    "struct VxOut {\n    float4 o0 [[color(0)]];\n};\n#define VX_RETURN return (VxOut{as_type<float4>(o0)})\n\n"
    "struct Vtx { float4 p [[position]]; };\n"
    "vertex Vtx vs_main(uint i [[vertex_id]]) { float2 p = float2((i == 1) ? 3 : -1, (i == 2) ? 3 : -1); return { float4(p, 0, 1) }; }\n"
    "fragment VxOut vx_main(constant float *k [[buffer(0)]]) {\n    float4 o0 = 0;\n    o0 = float4(k[0] / 255.0, k[0] / 255.0, k[0] / 255.0, 1);\n    VX_RETURN;\n}\n";
static void run(id<MTLDevice> dev, id<MTLCommandQueue> q, NSString *source, float code, double *mean, int *ones, int *twos, int *other) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:source options:nil error:&err];
    if (!lib) { fprintf(stderr, "compile: %s\n", err.localizedDescription.UTF8String); assert(0); }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs_main"]; pd.fragmentFunction = [lib newFunctionWithName:@"vx_main"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err]; assert(ps);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps]; [e setFragmentBytes:&code length:4 atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    uint8_t px[64 * 64 * 4]; [t getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
    double sum = 0; *ones = *twos = *other = 0;
    for (int i = 0; i < 64 * 64; i++) { sum += px[i * 4]; if (px[i * 4] == 1) (*ones)++; else if (px[i * 4] == 2) (*twos)++; else (*other)++; }
    *mean = sum / (64 * 64);
}
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); assert(dev);
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSString *dithered = vx_d3d11_dither_source(kMsl); assert(dithered);
    double mean; int a, b, c;
    run(dev, q, @(kMsl), 1.4f, &mean, &a, &b, &c);
    printf("plain    1.4: mean %.3f ones %d twos %d other %d\n", mean, a, b, c);
    assert(a == 64 * 64);                                            // flat: one code everywhere
    run(dev, q, dithered, 1.4f, &mean, &a, &b, &c);
    printf("dithered 1.4: mean %.3f ones %d twos %d other %d\n", mean, a, b, c);
    assert(c == 0 && a > 1000 && b > 1000 && mean > 1.3 && mean < 1.5);
    run(dev, q, dithered, 1.0f, &mean, &a, &b, &c);
    printf("dithered 1.0: mean %.3f ones %d twos %d other %d\n", mean, a, b, c);
    assert(a == 64 * 64);                                            // an exact code stays
    return 0;
} }
